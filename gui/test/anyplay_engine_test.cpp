// AnyPlay 118: тест рушія клавіш (AnyPlayInput) з розкладкою GTA VI — те, що бачить приставка, коли гравець
// сідає в машину, виходить, ламає її, відбивається від НПС і піднімає предмет. Справжній час (таймери Qt), ~35 с.
// input4: злам V (стіки назустріч, точка дотику мишею), B — △ двічі, сів без △, вихід лише «6 с і рухаєшся».
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
#include <QVariantMap>

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
	Wait(500);

	// ── 4. input4: злам машини V — обидва стіки до упору назустріч, миша веде точку дотику; без обертання по колу ──
	std::printf("4. злам машини (V), машина завелась\n");
	QVariantMap mg;
	int mg_changes = 0;
	QObject::connect(&in, &AnyPlayInput::MinigameChanged, [&]() { mg = in.MinigameState(); mg_changes++; });
	Tap(in, "F");
	Key(in, "V", true);
	Wait(50);
	CHECK(in.MinigameActive() && in.CapturesMouse());
	CHECK(mg.value("active").toBool() && mg.value("angle").toInt() == 0 && mg.value("tip").toBool());
	{
		const Pad p(in);
		CHECK(p.s.left_x > 32000 && p.s.left_y == 0);      // лівий до упору вправо
		CHECK(p.s.right_x < -32000 && p.s.right_y == 0);   // правий до упору вліво
	}
	in.MouseDelta(40, -120);              // миша вгору (і трохи вбік — не важить): точка на 30° вгору
	Wait(30);
	CHECK(mg.value("angle").toInt() == 30);
	{
		const Pad p(in);
		CHECK(std::abs(p.s.left_x - 28377) < 400 && std::abs(p.s.left_y + 16383) < 400);    // cos 30°, sin 30° угору
		CHECK(std::abs(p.s.right_x + 28377) < 400 && std::abs(p.s.right_y + 16383) < 400); // дзеркально
	}
	// ціле коло мишею не крутить: точка впирається у верх і стоїть
	for(int i = 0; i < 40; i++)
		in.MouseDelta(0, -100);
	Wait(30);
	CHECK(mg.value("angle").toInt() == 90);
	{
		const Pad p(in);
		CHECK(std::abs(p.s.left_x) < 400 && p.s.left_y < -32000 && std::abs(p.s.right_x) < 400 && p.s.right_y < -32000);
	}
	in.MouseDelta(0, 240);                // назад униз на 60°
	CHECK(mg.value("angle").toInt() == 30);
	// коліщатко і ↑: дрібно на 2°; ← → лише правий стік; стрілки не йдуть у гру хрестовиною
	CHECK(in.Tap(QStringLiteral("WheelUp")));
	CHECK(mg.value("angle").toInt() == 32);
	Key(in, "Up", true);
	CHECK(!Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_DPAD_UP));
	Key(in, "Up", false);
	CHECK(mg.value("angle").toInt() == 34);
	Key(in, "Right", true);
	CHECK(!Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT));
	Key(in, "Right", false);
	CHECK(mg.value("offset").toInt() == 3);
	Key(in, "Left", true); Key(in, "Left", false);
	CHECK(mg.value("offset").toInt() == 0);
	// відпустив V — стіки в центр; натиснув знову за 15 с — точка там, де була (34°)
	Key(in, "V", false);
	Wait(30);
	CHECK(!in.MinigameActive() && Pad(in).RightIdle() && Pad(in).LeftIdle() && !mg.value("active").toBool());
	Key(in, "V", true);
	Wait(30);
	CHECK(mg.value("angle").toInt() == 34 && !mg.value("tip").toBool());
	// мотор завівся: гра дала опір на газі — «Транспорт», злам зупинено, стіки в центр, хоч V ще тримаєш
	in.NoteTriggers(0x00, 0x21);
	Wait(250);
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));
	CHECK(!in.MinigameActive() && !mg.value("active").toBool());
	CHECK(Pad(in).RightIdle() && Pad(in).LeftIdle());
	Key(in, "V", false);
	// у «Транспорті»: V (якщо машина ще не завелась), а натиснув W — злам зупинено, W — газ
	Key(in, "V", true);
	Wait(50);
	CHECK(in.MinigameActive() && !Pad(in).RightIdle());
	Key(in, "W", true);
	Wait(50);
	CHECK(!in.MinigameActive());
	CHECK(Pad(in).RightIdle() && Pad(in).R2());
	Key(in, "V", false);
	Key(in, "W", false);
	// K у «Транспорті» тепер нахил назад (вілі), а не обертання; 9 і 0 вільні
	Key(in, "K", true);
	Wait(30);
	CHECK(Pad(in).RightIdle() && Pad(in).s.left_y > 32000);
	Key(in, "K", false);
	CHECK(!in.HandleInput(QStringLiteral("9"), true));
	in.HandleInput(QStringLiteral("9"), false);

	// ── 4б. input4: «вийти, лишивши мотор» — B дає △ двічі з проміжком, як на геймпаді ──
	std::printf("4б. B: △ двічі\n");
	{
		QList<qint64> edges;
		bool was = false;
		QElapsedTimer bt;
		bt.start();
		Key(in, "B", true);
		while(bt.elapsed() < 450)
		{
			const bool on = Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_PYRAMID);
			if(on != was)
				edges.append(bt.elapsed()), was = on;
			Wait(3);
		}
		Key(in, "B", false);
		std::printf("   △ натиснуто/відпущено: %s мс\n", [&]() { QStringList l; for(qint64 e : edges) l.append(QString::number(e)); return l.join(QStringLiteral(", ")).toStdString(); }().c_str());
		CHECK(edges.size() == 4);
		if(edges.size() == 4)
		{
			CHECK(edges[1] - edges[0] >= 60 && edges[1] - edges[0] <= 120);   // перше натискання ~80 мс
			CHECK(edges[2] - edges[1] >= 90 && edges[2] - edges[1] <= 170);   // проміжок ~120 мс
			CHECK(edges[2] - edges[0] <= 300);                                 // друге — у межах подвійного натискання
		}
		// гра прибрала ефекти: «Пішки», а друге △ не відкрило нової «посадки»
		log.clear();
		in.NoteTriggers(0x00, 0x00);
		Wait(300);
		CHECK(in.CurrentProfileId() == QLatin1String("foot"));
		Tap(in, "F", 60);                    // гравець сам ще раз F одразу після виходу (двічі F)
		Wait(50);
		CHECK(log.join(QStringLiteral(" ")).contains(QStringLiteral("двічі △")));
	}

	// ── 4в. input4: сів без △ (вікно минуло): стійкий опір на газі 0,8 с, не цілишся — «Транспорт» ──
	std::printf("4в. сів без △\n");
	Wait(1000);
	t.start();
	in.NoteTriggers(0x21, 0x21);
	while(in.CurrentProfileId() != QLatin1String("vehicle") && t.elapsed() < 3000)
		Wait(5);
	std::printf("   «Транспорт» через %lld мс\n", (long long)t.elapsed());
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));
	CHECK(t.elapsed() >= 750 && t.elapsed() <= 1000);
	// провал ефектів 3 с, поки газуєш, — не вихід
	Key(in, "W", true);
	in.NoteTriggers(0x00, 0x00);
	Wait(3000);
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));
	in.NoteTriggers(0x21, 0x21);
	Wait(300);
	Key(in, "W", false);

	// ── 5. Боротьба: НПС витягує, ефекти зникли, □ (R) часто 5 с — «Транспорт» тримається; витягли і пішов — «Пішки» ──
	std::printf("5. боротьба в машині\n");
	in.NoteTriggers(0x00, 0x00);
	for(int i = 0; i < 17; i++)
		Tap(in, "R", 60), Wait(240);
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));
	Key(in, "W", true);                     // витягли, пішов (W у «Транспорті» — газ, курки мовчать)
	Wait(800);
	CHECK(in.CurrentProfileId() == QLatin1String("vehicle"));   // 6 с без ефектів ще не минуло
	Wait(2000);
	CHECK(in.CurrentProfileId() == QLatin1String("foot"));     // 6 с і рухаєшся, боротьба скінчилась
	CHECK(Pad(in).LeftUp() && !Pad(in).R2());                   // W знову крок
	Key(in, "W", false);

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
	// K L пішки — відмичка на дверях (правий стік по колу, лише поки тримаєш)
	Key(in, "K", true);
	Wait(120);
	CHECK(!Pad(in).RightIdle() && Pad(in).LeftIdle());
	Key(in, "K", false);
	Wait(30);
	CHECK(Pad(in).RightIdle());
	// у «Транспорті» N — радіо вимкнути: ← двічі
	Tap(in, "U");
	Wait(30);
	{
		int presses = 0;
		bool was = false;
		Key(in, "N", true);
		for(int i = 0; i < 120; i++)
		{
			const bool on = Pad(in).Btn(CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT);
			if(on && !was)
				presses++;
			was = on;
			Wait(3);
		}
		Key(in, "N", false);
		CHECK(presses == 2);
	}

	QSettings().clear();
	if(failures)
	{
		std::printf("%d з %d перевірок не пройшли\n", failures, checks);
		return 1;
	}
	std::printf("УСЕ ДОБРЕ: %d перевірок\n", checks);
	return 0;
}
