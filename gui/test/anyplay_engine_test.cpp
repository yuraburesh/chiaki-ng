// AnyPlay 118: тест рушія клавіш (AnyPlayInput) з розкладкою GTA VI — те, що бачить приставка, коли гравець
// сідає в машину, виходить, ламає її, відбивається від НПС і піднімає предмет. Справжній час (таймери Qt), ~25 с.
//
// Збірка (Qt 6 Core і Gui; заглушка settings.h з gui/test/stub; розкладки як ресурси):
//   Q=/usr/include/x86_64-linux-gnu/qt6; B=/tmp/anyplay-engine; mkdir -p $B
//   printf '<RCC><qresource prefix="/anyplay"><file alias="anyplay-controls.json">%s/gui/res/anyplay-controls.json</file><file alias="anyplay-controls-gta6.json">%s/gui/res/anyplay-controls-gta6.json</file><file alias="anyplay-controls-universal.json">%s/gui/res/anyplay-controls-universal.json</file></qresource></RCC>' $PWD $PWD $PWD > $B/t.qrc
//   /usr/lib/qt6/libexec/rcc $B/t.qrc -o $B/qrc.cpp && /usr/lib/qt6/libexec/moc gui/include/anyplayinput.h -o $B/moc.cpp
//   g++ -std=c++20 -fPIC -I gui/test/stub -I gui/include -I lib/include -I $Q -I $Q/QtCore -I $Q/QtGui
//     gui/test/anyplay_engine_test.cpp gui/src/anyplayinput.cpp $B/moc.cpp $B/qrc.cpp -lQt6Gui -lQt6Core -o $B/t && $B/t
#include "anyplayinput.h"

#include <QCoreApplication>
#include <QElapsedTimer>
#include <QSettings>
#include <QStandardPaths>
#include <QThread>
#include <cstdio>
#include <cstdlib>

static int failures = 0;
static int checks = 0;
#define CHECK(cond) do { checks++; if(!(cond)) { failures++; std::printf("ПОМИЛКА %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while(0)

// Чекаємо справжній час, поки працюють таймери рушія
static void Wait(int ms)
{
	QElapsedTimer t;
	t.start();
	while(t.elapsed() < ms)
	{
		QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
		QThread::msleep(2);
	}
}

struct Pad
{
	ChiakiControllerState s;
	explicit Pad(const AnyPlayInput &in) : s{} { in.ApplyTo(&s); }
	bool R2() const { return s.r2_state > 0; }
	bool L2() const { return s.l2_state > 0; }
	bool Btn(uint32_t b) const { return (s.buttons & b) != 0; }
	bool LeftUp() const { return s.left_y < -30000; }
	bool LeftIdle() const { return s.left_x == 0 && s.left_y == 0; }
	bool RightIdle() const { return s.right_x == 0 && s.right_y == 0; }
};

static void Key(AnyPlayInput &in, const char *name, bool down) { in.HandleInput(QString::fromLatin1(name), down); }
static void Tap(AnyPlayInput &in, const char *name, int ms = 90) { Key(in, name, true); Wait(ms); Key(in, name, false); }

int main(int argc, char **argv)
{
	QStandardPaths::setTestModeEnabled(true);
	QCoreApplication app(argc, argv);
	QCoreApplication::setOrganizationName(QStringLiteral("AnyPlayEngineTest"));
	QCoreApplication::setApplicationName(QStringLiteral("anyplay-engine-test"));
	QSettings().clear();
	AnyPlayInput::SetLayout(QStringLiteral("gta6"));
	CHECK(AnyPlayInput::Layout() == QLatin1String("gta6"));
	CHECK(AnyPlayInput::AutoVehicle());

	AnyPlayInput in;
	QStringList log;
	QObject::connect(&in, &AnyPlayInput::VehicleLog, [&log](const QString &l) { log.append(l); std::printf("  [журнал] %s\n", l.toUtf8().constData()); });
	in.Load();
	Wait(50);
	CHECK(in.CurrentProfileId() == QLatin1String("foot"));

	// ── 1. Сів з затиснутою W: щойно гра дала опір на газі, W — це вже газ, без повторного натискання ──
	std::printf("1. сів з затиснутою W\n");
	Key(in, "W", true);
	CHECK(Pad(in).LeftUp() && !Pad(in).R2());
	QElapsedTimer t;
	Tap(in, "F");
	Wait(1500);                          // підбіг і анімація
	t.start();
	in.NoteTriggers(0x00, 0x21);         // опір на газі (L2 ще без ефекту)
	while(in.CurrentProfileId() != QLatin1String("vehicle") && t.elapsed() < 2000)
		Wait(5);
	std::printf("   «Транспорт» через %lld мс після ефекту\n", (long long)t.elapsed());
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));
	CHECK(t.elapsed() <= 250);
	CHECK(Pad(in).R2() && Pad(in).LeftIdle());   // W тепер газ

	// ── 2. Вийшов з затиснутою W: F, ефекти зникли — «Пішки» одразу, W знову рух ──
	std::printf("2. вийшов з затиснутою W\n");
	Tap(in, "F");
	Wait(400);
	t.start();
	in.NoteTriggers(0x00, 0x00);
	while(in.CurrentProfileId() != QLatin1String("foot") && t.elapsed() < 2000)
		Wait(5);
	std::printf("   «Пішки» через %lld мс після того, як ефекти зникли\n", (long long)t.elapsed());
	CHECK(in.CurrentProfileId() == QLatin1String("foot"));
	CHECK(t.elapsed() <= 300);
	CHECK(Pad(in).LeftUp() && !Pad(in).R2());
	Key(in, "W", false);
	Wait(20);
	CHECK(Pad(in).LeftIdle());

	// ── 3. Підняв предмет на F і йде далі: режим «пішки», W лише рух, газу (R2 = кинути) нема ──
	std::printf("3. підняв предмет на F\n");
	Wait(1000);
	Tap(in, "F");
	Key(in, "W", true);
	Wait(1500);
	CHECK(in.CurrentProfileId() == QLatin1String("foot"));
	CHECK(Pad(in).LeftUp() && !Pad(in).R2() && !Pad(in).L2());
	// підняв зброю: на L2 опір прицілу, на R2 «зброя» — не машина
	Tap(in, "F");
	Wait(200);
	in.NoteTriggers(0x21, 0x25);
	Wait(1500);
	CHECK(in.CurrentProfileId() == QLatin1String("foot"));
	Key(in, "W", false);
	in.NoteTriggers(0x00, 0x00);
	Wait(11000 - 1500);                  // вікно «посадки» після останнього F закрилось

	// ── 4. Злам машини: K крутить правий стік; машина завелась (опір на газі) — стік у центр, хоч K ще затиснута ──
	std::printf("4. злам машини (K), машина завелась\n");
	Tap(in, "F");
	Key(in, "K", true);
	Wait(300);
	CHECK(!Pad(in).RightIdle());         // крутиться
	CHECK(in.MinigameActive());
	Wait(1500);
	in.NoteTriggers(0x00, 0x21);
	Wait(250);
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));
	CHECK(!in.MinigameActive());
	CHECK(Pad(in).RightIdle());          // зупинився, хоча K ще тримають
	Wait(200);
	CHECK(Pad(in).RightIdle());
	Key(in, "K", false);
	// у «Транспорті»: V (злам, обидва стіки назустріч), машина вже в «Транспорті» — газ зупиняє злам
	Key(in, "V", true);
	Wait(100);
	CHECK(in.MinigameActive() && !Pad(in).RightIdle());
	Key(in, "W", true);
	Wait(50);
	CHECK(!in.MinigameActive());
	CHECK(Pad(in).RightIdle() && Pad(in).R2());
	Key(in, "V", false);
	Key(in, "W", false);
	// K знову в «Транспорті»: крутиться, бо натиснули заново; відпустили — у центр
	Key(in, "K", true);
	Wait(100);
	CHECK(!Pad(in).RightIdle());
	Key(in, "K", false);
	Wait(30);
	CHECK(Pad(in).RightIdle());

	// ── 5. Боротьба: НПС витягує, ефекти зникли, □ (R) часто 5 с — «Транспорт» тримається; витягли — «Пішки» ──
	std::printf("5. боротьба в машині\n");
	in.NoteTriggers(0x00, 0x00);
	for(int i = 0; i < 17; i++)
		Tap(in, "R", 60), Wait(240);
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));
	Wait(2000);
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));   // ще 2,5 с після останнього □
	Wait(800);
	CHECK(in.CurrentProfileId() == QLatin1String("foot"));

	// ── 6. Зміна режиму вручну (U) скидає «утримати стік» (O) і точний рух ──
	std::printf("6. U скидає спец-стани\n");
	Tap(in, "O");
	CHECK(in.CapturesMouse());
	in.MouseDelta(80, 0);
	Wait(30);
	CHECK(!Pad(in).RightIdle());
	Tap(in, "U");
	Wait(30);
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));
	CHECK(!in.CapturesMouse() && Pad(in).RightIdle());
	Tap(in, "U");
	Wait(30);
	CHECK(in.CurrentProfileId() == QLatin1String("foot"));

	// ── 7. Нова розкладка: d-pad з літер як на геймпаді (коротко і тримай), H — коротко L1 ──
	std::printf("7. розкладка GTA VI\n");
	Key(in, "T", true);
	CHECK(Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_DPAD_UP));
	Wait(700);
	CHECK(Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_DPAD_UP));   // тримай — WAiNK
	Key(in, "T", false);
	Key(in, "H", true);
	Wait(200);
	CHECK(!Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_L1));       // сховати зброю: коротко, навіть якщо тримаєш
	Key(in, "H", false);
	Key(in, "Q", true);
	CHECK(Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_R1));        // укриття
	Key(in, "Q", false);
	Key(in, "Z", true);
	CHECK(Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN)); // мінікарта
	Key(in, "Z", false);
	Key(in, "G", true);
	CHECK(Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT));// підірвати
	Key(in, "G", false);

	QSettings().clear();
	if(failures)
	{
		std::printf("%d з %d перевірок не пройшли\n", failures, checks);
		return 1;
	}
	std::printf("УСЕ ДОБРЕ: %d перевірок\n", checks);
	return 0;
}
