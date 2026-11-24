// AnyPlay: тест чистої логіки стіків і визначення транспорту (без Qt).
// Запуск: g++ -std=c++17 -Wall -Wextra -I gui/include gui/test/anyplay_input_test.cpp -o /tmp/anyplay_input_test && /tmp/anyplay_input_test
#include "anyplaystick.h"
#include "anyplayvehicle.h"
#include "anyplayspin.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

static int failures = 0;
static int checks = 0;

#define CHECK(cond) do { checks++; if(!(cond)) { failures++; std::printf("ПОМИЛКА %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while(0)
#define NEAR(a, b) (std::fabs((a) - (b)) < 0.02)
#define NEAR_DEG(a, b) (std::fabs((a) - (b)) < 0.5)   // мілісекунди цілі, тож кут з похибкою до чверті градуса

static void test_polar()
{
	float x, y;
	AnyPlayPolarToStick(0, 1, &x, &y);   CHECK(NEAR(x, 0) && NEAR(y, -1));    // угору
	AnyPlayPolarToStick(90, 1, &x, &y);  CHECK(NEAR(x, 1) && NEAR(y, 0));     // вправо
	AnyPlayPolarToStick(180, 1, &x, &y); CHECK(NEAR(x, 0) && NEAR(y, 1));     // вниз
	AnyPlayPolarToStick(270, 1, &x, &y); CHECK(NEAR(x, -1) && NEAR(y, 0));    // вліво
	AnyPlayPolarToStick(90, 0.5, &x, &y); CHECK(NEAR(x, 0.5) && NEAR(y, 0));  // півсили
	AnyPlayPolarToStick(45, 3, &x, &y);  CHECK(NEAR(x, 0.707) && NEAR(y, -0.707)); // сила обрізається до 1
	CHECK(NEAR(AnyPlayStickAngle(0, -1), 0));
	CHECK(NEAR(AnyPlayStickAngle(1, 0), 90));
	CHECK(NEAR(AnyPlayStickAngle(0, 1), 180));
	CHECK(NEAR(AnyPlayStickAngle(-1, 0), 270));
	CHECK(NEAR(AnyPlayStickAngle(0, 0), 0));
	CHECK(NEAR(AnyPlayWrapDeg(-30), 330) && NEAR(AnyPlayWrapDeg(390), 30));
	// обертання за старою формулою (злам машини з 110): починає згори і йде за годинниковою
	AnyPlaySpinStick(0, 1, &x, &y); CHECK(NEAR(x, 0) && NEAR(y, -1));
	AnyPlaySpinStick(AnyPlaySpinPeriodMs / 4, 1, &x, &y); CHECK(NEAR(x, 1) && NEAR(y, 0));
}

static void test_precise()
{
	AnyPlayPreciseStick p;
	float x, y;
	// увімкнули, коли ніщо не натиснуте: стік угору на повну
	p.Start(0, 0);
	CHECK(NEAR(p.angle, 0) && NEAR(p.mag, 1));
	// тримають «вправо»: за третину секунди стік повернувся на 90°
	p.turn = +1;
	p.Advance(1000.0 * 90.0 / AnyPlayPreciseTurnDegPerSec);
	CHECK(NEAR_DEG(p.angle, 90));
	p.Stick(&x, &y); CHECK(NEAR(x, 1) && NEAR(y, 0));
	// відпустили: положення тримається
	p.turn = 0;
	p.Advance(5000);
	CHECK(NEAR_DEG(p.angle, 90) && NEAR(p.mag, 1));
	CHECK(!p.Moving());
	// «назад» зменшує силу, не нижче нуля
	p.push = -1;
	p.Advance(200);
	CHECK(NEAR(p.mag, 1.0 - AnyPlayPreciseMagPerSec * 0.2));
	p.Advance(5000);
	CHECK(NEAR(p.mag, 0));
	// «вперед» повертає силу, не вище одиниці
	p.push = +1;
	p.Advance(5000);
	CHECK(NEAR(p.mag, 1));
	// проти годинникової через нуль
	p.push = 0; p.turn = -1;
	p.Advance(1000.0 * 120.0 / AnyPlayPreciseTurnDegPerSec);
	CHECK(NEAR_DEG(p.angle, 330));
	// увімкнули, коли стік уже дивиться вліво на півсили: починаємо звідти
	p.Start(-0.5, 0);
	CHECK(NEAR(p.angle, 270) && NEAR(p.mag, 0.5));
	// у точному режимі кут безперервний: 16 мс дає ~4°, а не стрибок на 45°
	p.Start(0, 0); p.turn = 1; p.Advance(16);
	CHECK(p.angle > 3 && p.angle < 6);
}

static void test_hold()
{
	AnyPlayMousePoint m;
	float x, y;
	m.Move(70, 0, 140);
	AnyPlayHoldStick(m, 140, false, &x, &y);
	CHECK(NEAR(x, 0.5) && NEAR(y, 0));
	// далі за коло не йде: повне відхилення
	m.Move(300, 0, 140);
	AnyPlayHoldStick(m, 140, false, &x, &y);
	CHECK(NEAR(x, 1) && NEAR(y, 0));
	// назад до центру і трохи вниз: стік униз (y > 0), з інверсією — угору
	m.Move(-140, 70, 140);
	AnyPlayHoldStick(m, 140, false, &x, &y);
	CHECK(NEAR(x, 0) && NEAR(y, 0.5));
	AnyPlayHoldStick(m, 140, true, &x, &y);
	CHECK(NEAR(y, -0.5));
	// миша не рухається: стік стоїть (не повертається в центр)
	AnyPlayHoldStick(m, 140, false, &x, &y);
	CHECK(NEAR(y, 0.5));
}

static void test_hotwire()
{
	AnyPlayMousePoint m;
	float lx, ly, rx, ry;
	AnyPlayHotwireStart(&m, AnyPlayHotwireRadiusPx);
	AnyPlayHotwireSticks(m, &lx, &ly, &rx, &ry);
	// назустріч: правий вліво, лівий вправо, обидва на повну
	CHECK(NEAR(rx, -1) && NEAR(ry, 0));
	CHECK(NEAR(lx, 1) && NEAR(ly, 0));
	// миша вгору на радіус: точка (-R, -R) обрізається до кола → обидва стіки по діагоналі вгору, дзеркально
	m.Move(0, -AnyPlayHotwireRadiusPx, AnyPlayHotwireRadiusPx);
	AnyPlayHotwireSticks(m, &lx, &ly, &rx, &ry);
	CHECK(NEAR(rx, -0.707) && NEAR(ry, -0.707));
	CHECK(NEAR(lx, 0.707) && NEAR(ly, -0.707));
	CHECK(NEAR(m.Length(), AnyPlayHotwireRadiusPx));
	// коліщатко: крок на 45° за годинниковою → правий угору, лівий угору
	m.Rotate(45);
	AnyPlayHotwireSticks(m, &lx, &ly, &rx, &ry);
	CHECK(NEAR(rx, 0) && NEAR(ry, -1));
	CHECK(NEAR(lx, 0) && NEAR(ly, -1));
	// повне коло мишею: 8 кроків по 45° повертають у початок
	for(int i = 0; i < 8; i++)
		m.Rotate(45);
	AnyPlayHotwireSticks(m, &lx, &ly, &rx, &ry);
	CHECK(NEAR(rx, 0) && NEAR(ry, -1));
	// у центрі (ще не рухали) стіки назустріч
	m.Reset();
	AnyPlayHotwireSticks(m, &lx, &ly, &rx, &ry);
	CHECK(NEAR(rx, -1) && NEAR(lx, 1));
}

static void test_vehicle()
{
	AnyPlayVehicleDetector d;
	d.Reset(false, 0);
	// обидва курки з ефектом: через 1,5 с — транспорт, не раніше
	d.Triggers(0x21, 0x26, 100);
	CHECK(d.Tick(1500) == 0);
	CHECK(d.Tick(1599) == 0);
	CHECK(d.Tick(1600) == +1);
	CHECK(d.in_vehicle);
	CHECK(d.Tick(3000) == 0);   // не повторює
	// обидва без ефекту: через 2 с — пішки
	d.Triggers(0x00, 0x05, 5000);
	CHECK(d.Tick(6999) == 0);
	CHECK(d.Tick(7000) == -1);
	CHECK(!d.in_vehicle);
	// лише R2 (зброя): ніколи не транспорт
	d.Triggers(0x00, 0x26, 8000);
	CHECK(d.Tick(20000) == 0);
	// мигнуло: обидва увімкнулись, зникли, знову увімкнулись — відлік спочатку
	d.Triggers(0x21, 0x26, 20000);
	d.Triggers(0x00, 0x26, 21000);
	d.Triggers(0x21, 0x26, 21200);
	CHECK(d.Tick(22600) == 0);
	CHECK(d.Tick(22700) == +1);

	// вібрація двигуна поруч: швидше (1 с)
	AnyPlayVehicleDetector e;
	e.Reset(false, 0);
	e.Triggers(0x21, 0x21, 0);
	e.Rumble(true, 300);
	CHECK(e.Tick(900) == 0);
	CHECK(e.Tick(1000) == +1);

	// гра ніколи не давала ефектів (адаптивні курки вимкнені): після F лишаємось у транспорті назавжди
	AnyPlayVehicleDetector f;
	f.Reset(false, 0);
	f.Manual(true, 100);
	CHECK(f.in_vehicle);
	CHECK(f.Tick(60000) == 0);
	CHECK(f.in_vehicle);

	// F далеко від машини, але ефекти в грі є: через 8 с тиші автоматика повертає «пішки»
	AnyPlayVehicleDetector g;
	g.Reset(false, 0);
	g.Triggers(0x21, 0x26, 0);
	CHECK(g.Tick(1500) == +1);
	g.Triggers(0x00, 0x00, 2000);
	CHECK(g.Tick(4000) == -1);       // вийшов
	g.Manual(true, 4100);            // натиснув F, машини поруч нема
	CHECK(g.Tick(12000) == 0);       // ще мовчимо (8 с після F)
	CHECK(g.Tick(12200) == -1);      // курки без ефекту ≥ 2 с після F → пішки
	// натиснув F біля машини: курки отримали ефект через 3 с (анімація), автоматика не сперечається
	g.Manual(true, 13000);
	g.Triggers(0x21, 0x26, 16000);
	CHECK(g.Tick(20000) == 0);       // уже в транспорті — нічого не міняє
	CHECK(g.in_vehicle);
	// вийшов клавішею F: ефекти зникли, автоматика погоджується мовчки
	g.Manual(false, 21000);
	g.Triggers(0x00, 0x00, 21100);
	CHECK(g.Tick(40000) == 0);
	CHECK(!g.in_vehicle);
	// F «пішки» помилково, хоч сидиш у машині (ефекти лишились): після паузи автоматика повертає транспорт
	g.Triggers(0x21, 0x26, 41000);
	g.Manual(false, 41100);
	CHECK(g.Tick(48000) == 0);
	CHECK(g.Tick(49200) == +1);

	// типи ефектів
	CHECK(!AnyPlayTriggerEffectOn(0x00) && !AnyPlayTriggerEffectOn(0x05));
	CHECK(AnyPlayTriggerEffectOn(0x01) && AnyPlayTriggerEffectOn(0x21) && AnyPlayTriggerEffectOn(0x26));
}

int main()
{
	test_polar();
	test_precise();
	test_hold();
	test_hotwire();
	test_vehicle();
	if(failures)
	{
		std::printf("%d з %d перевірок не пройшли\n", failures, checks);
		return 1;
	}
	std::printf("УСЕ ДОБРЕ: %d перевірок\n", checks);
	return 0;
}
