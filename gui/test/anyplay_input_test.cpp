// AnyPlay: тест чистої логіки стіків і визначення транспорту (без Qt).
// Запуск: g++ -std=c++17 -Wall -Wextra -I gui/include gui/test/anyplay_input_test.cpp -o /tmp/anyplay_input_test && /tmp/anyplay_input_test
#include "anyplaystick.h"
#include "anyplayvehicle.h"
#include "anyplayspin.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>

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

// ефекти курків для тестів: опір (педалі, приціл), зброя, вібрація, немає
constexpr uint8_t RES = 0x21, GUN = 0x25, VIB = 0x26, OFF = 0x00;

static void Feed(AnyPlayVehicleDetector &d, uint8_t l, uint8_t r, int64_t now)
{
	d.Triggers(AnyPlayTriggerClass(l), AnyPlayTriggerClass(r), l, r, now);
}

static bool LogHas(AnyPlayVehicleDetector &d, const char *text)
{
	const std::string log = d.TakeLog();
	return log.find(text) != std::string::npos;
}

// Послідовність подій, як у журналі клієнта: час, що сталося. Tick — кожні 200 мс, як у програмі.
struct Ev { int64_t t; char kind; uint8_t a, b; };   // kind: 'T' курки a/b, 'F' △, 'R' вібрація a/b, 'A' приціл a, 'M' меню a, 'U' вручну a (1 транспорт)

// Проганяє події й повертає режим у кінці (true — транспорт), рахуючи перемикання
static bool Play(const AnyPlayVehicleRules &rules, bool start_vehicle, const Ev *ev, int n, int64_t until, int *switches)
{
	AnyPlayVehicleDetector d;
	d.Reset(rules, start_vehicle, 0);
	int i = 0;
	*switches = 0;
	for(int64_t now = 0; now <= until; now += 200)
	{
		for(; i < n && ev[i].t <= now; i++)
		{
			const Ev &e = ev[i];
			switch(e.kind)
			{
				case 'T': Feed(d, e.a, e.b, e.t); break;
				case 'F': d.Interact(e.t); break;
				case 'R': d.Rumble(e.a, e.b, e.t); break;
				case 'A': d.SetAiming(e.a != 0, e.t); break;
				case 'M': d.SetMenu(e.a != 0, e.t); break;
				case 'U': d.Manual(e.a != 0, e.t); break;
			}
		}
		if(d.Tick(now))
			(*switches)++;
	}
	return d.in_vehicle;
}

static void test_vehicle()
{
	const AnyPlayVehicleRules gta5 = AnyPlayVehicleRulesGta5();
	const AnyPlayVehicleRules gta6 = AnyPlayVehicleRulesGta6();

	// класи ефектів
	CHECK(AnyPlayTriggerClass(0x00) == AnyPlayTrigOff && AnyPlayTriggerClass(0x05) == AnyPlayTrigOff);
	CHECK(AnyPlayTriggerClass(0x21) == AnyPlayTrigResist && AnyPlayTriggerClass(0x01) == AnyPlayTrigResist);
	CHECK(AnyPlayTriggerClass(0x25) == AnyPlayTrigWeapon && AnyPlayTriggerClass(0x02) == AnyPlayTrigWeapon);
	CHECK(AnyPlayTriggerClass(0x26) == AnyPlayTrigVibrate && AnyPlayTriggerClass(0x06) == AnyPlayTrigVibrate);
	CHECK(AnyPlayTriggerClass(0x21, true) == AnyPlayTrigOff);   // тип той самий, параметри нульові — ефекту нема
	const uint8_t zero[10] = {0}, some[10] = {0, 0x03, 0, 0, 0, 0, 0, 0, 0, 0};
	CHECK(AnyPlayTriggerDataEmpty(zero) && !AnyPlayTriggerDataEmpty(some));
	CHECK(std::string(AnyPlayVehicleRulesFor("gta6").game) == "gta6" && std::string(AnyPlayVehicleRulesFor("gta5").game) == "gta5");

	// 1. Пішки, F біля предмета (△ = підняти): курки не змінились → режим не міняється, у журналі причина
	AnyPlayVehicleDetector d;
	d.Reset(gta5, false, 0);
	d.Interact(1000);
	CHECK(LogHas(d, "чекаю підтвердження"));
	CHECK(d.Tick(3000) == 0);
	CHECK(d.Tick(5000) == 0 && !d.in_vehicle);   // рівно 4 с: вікно ще відкрите
	CHECK(d.Tick(5200) == 0 && !d.in_vehicle);
	CHECK(LogHas(d, "без підтвердження"));
	CHECK(d.f_at < 0);

	// 2. F біля машини: через 1,5 с (анімація) опір на обох педалях → транспорт за 0,3 с
	d.Interact(10000);
	Feed(d, RES, RES, 11500);
	CHECK(d.Tick(11600) == 0);
	CHECK(d.Tick(11800) == +1);
	CHECK(d.in_vehicle && LogHas(d, "сів у транспорт: △"));
	CHECK(d.Tick(12000) == 0);   // не повторює

	// 3. У машині F (вийти): ефекти зникли через 1,2 с → пішки через 0,3 с
	d.Interact(20000);
	Feed(d, OFF, OFF, 21200);
	CHECK(d.Tick(21400) == 0);
	CHECK(d.Tick(21500) == -1);
	CHECK(!d.in_vehicle && LogHas(d, "вийшов: △"));

	// 4. У машині без F ефекти зникли (викинуло, загинув): 2,5 с → пішки, не раніше
	AnyPlayVehicleDetector e;
	e.Reset(gta5, false, 0);
	Feed(e, RES, RES, 0);
	CHECK(e.Tick(2400) == 0);
	CHECK(e.Tick(2500) == +1);   // місія почалась у машині: без △ за 2,5 с
	CHECK(LogHas(e, "без △"));
	Feed(e, OFF, OFF, 10000);
	CHECK(e.Tick(12400) == 0);
	CHECK(e.Tick(12500) == -1);
	CHECK(LogHas(e, "без ефектів транспорту"));

	// 5. Пауза в машині: ефекти зникли, хвилину в меню — режим лишається; повернувся, ефекти назад — так само транспорт
	AnyPlayVehicleDetector p;
	p.Reset(gta5, false, 0);
	Feed(p, RES, RES, 0);
	p.Interact(0);
	CHECK(p.Tick(400) == +1);
	p.SetMenu(true, 1000);
	Feed(p, OFF, OFF, 1100);
	CHECK(p.Tick(61000) == 0 && p.in_vehicle);
	p.SetMenu(false, 61000);       // натиснув W: відлік «без ефектів» заново
	CHECK(p.Tick(61200) == 0);
	Feed(p, RES, RES, 61300);
	CHECK(p.Tick(70000) == 0 && p.in_vehicle);

	// 6. Пішки зі зброєю (GTA V): приціл з легким опором, на спуску «зброя» — ніколи не транспорт, навіть після F
	AnyPlayVehicleDetector g;
	g.Reset(gta5, false, 0);
	Feed(g, RES, GUN, 0);
	g.Interact(500);
	CHECK(g.Tick(30000) == 0 && !g.in_vehicle);
	// черга з автомата (вібрація на R2) у GTA V теж не транспорт: «сів» лише опір на обох
	Feed(g, RES, VIB, 30000);
	CHECK(g.Tick(60000) == 0 && !g.in_vehicle);

	// 7. GTA VI: опір + вібрація означає «сів», але поки тримаєш приціл чи постріл — ні
	AnyPlayVehicleDetector h;
	h.Reset(gta6, false, 0);
	Feed(h, RES, VIB, 0);
	h.SetAiming(true, 0);
	CHECK(h.Tick(10000) == 0 && !h.in_vehicle);
	CHECK(LogHas(h, "тримаєш приціл"));
	h.SetAiming(false, 10000);   // відпустив, а ефект лишився: рахуємо від цієї миті
	CHECK(h.Tick(12400) == 0);
	CHECK(h.Tick(12600) == +1);
	// у GTA V те саме — не транспорт
	AnyPlayVehicleDetector h5;
	h5.Reset(gta5, false, 0);
	Feed(h5, RES, VIB, 0);
	h5.Interact(0);
	CHECK(h5.Tick(10000) == 0);

	// 8. Вібрація двигуна поруч: без △ швидше (1,5 с)
	AnyPlayVehicleDetector r;
	r.Reset(gta5, false, 0);
	Feed(r, RES, RES, 0);
	r.Rumble(40, 0, 300);
	CHECK(r.Tick(1400) == 0);
	CHECK(r.Tick(1500) == +1);

	// 9. Вручну «транспорт» у човні без ефектів: за часом не виходимо; △ (вийти) — пішки
	AnyPlayVehicleDetector b;
	b.Reset(gta5, false, 0);
	Feed(b, RES, GUN, 0);          // ефекти в грі є (зброя)
	Feed(b, OFF, OFF, 1000);
	b.Manual(true, 2000);
	CHECK(b.Tick(60000) == 0 && b.in_vehicle);
	b.Interact(60000);
	CHECK(b.Tick(60400) == -1 && !b.in_vehicle);

	// 10. Вручну «пішки», хоча ефект ще є (програма помилилась чи гравець): не повертаємо транспорт, доки ефект той самий
	AnyPlayVehicleDetector m;
	m.Reset(gta5, false, 0);
	Feed(m, RES, RES, 0);
	CHECK(m.Tick(2600) == +1);
	m.Manual(false, 3000);
	CHECK(m.Tick(5000) == 0);       // 5 с тиші після ручного
	CHECK(m.Tick(30000) == 0 && !m.in_vehicle);
	Feed(m, OFF, OFF, 31000);       // ефект зник і знову з'явився (сів у іншу машину)
	Feed(m, RES, RES, 40000);
	m.Interact(40000);
	CHECK(m.Tick(40400) == +1);

	// 11. Адаптивні курки в грі вимкнені: після хвилини гри перший △ каже в журнал, що автоматика сліпа
	AnyPlayVehicleDetector n;
	n.Reset(gta5, false, 0);
	n.Interact(10000);
	CHECK(!n.warned_no_effects);
	CHECK(n.Tick(15000) == 0);
	n.TakeLog();
	n.Interact(61000);
	CHECK(n.warned_no_effects && LogHas(n, "не надсилає"));
	CHECK(n.Tick(70000) == 0 && !n.in_vehicle);

	// 12. Авіація (вручну F3): детектор вважає її транспортом і виходить після △ без ефектів
	AnyPlayVehicleDetector a;
	a.Reset(gta5, true, 0);
	Feed(a, RES, RES, 100);
	a.Interact(5000);
	Feed(a, OFF, OFF, 6000);
	CHECK(a.Tick(6400) == -1);

	// 13. Вигадані «записи» журналу: типові вечори в GTA V
	int sw = 0;
	{
		// підняв предмет (F) тричі, відчинив двері, постріляв — режим жодного разу не змінився
		const Ev ev[] = {
			{1000, 'F', 0, 0}, {6000, 'F', 0, 0}, {8000, 'T', RES, GUN}, {8100, 'A', 1, 0}, {9000, 'A', 0, 0},
			{12000, 'T', OFF, OFF}, {15000, 'F', 0, 0}, {20000, 'F', 0, 0},
		};
		CHECK(!Play(gta5, false, ev, sizeof(ev) / sizeof(ev[0]), 30000, &sw));
		CHECK(sw == 0);
	}
	{
		// сів (F, анімація 2 с), їздив з гальмуванням і вібрацією, вийшов (F), підняв предмет (F)
		const Ev ev[] = {
			{1000, 'F', 0, 0}, {3000, 'T', RES, RES}, {3200, 'R', 30, 0}, {10000, 'T', RES, VIB}, {12000, 'T', RES, RES},
			{20000, 'F', 0, 0}, {20800, 'T', OFF, OFF}, {25000, 'F', 0, 0},
		};
		CHECK(!Play(gta5, false, ev, sizeof(ev) / sizeof(ev[0]), 30000, &sw));
		CHECK(sw == 2);   // сів і вийшов, F біля предмета нічого не зробила
	}
	{
		// GTA VI: сів, на швидкості вібрація на обох, пауза на 40 с, повернувся в машину
		const Ev ev[] = {
			{500, 'F', 0, 0}, {2500, 'T', RES, RES}, {8000, 'T', VIB, VIB}, {9000, 'M', 1, 0}, {9100, 'T', OFF, OFF},
			{49000, 'M', 0, 0}, {49300, 'T', RES, RES},
		};
		CHECK(Play(gta6, false, ev, sizeof(ev) / sizeof(ev[0]), 60000, &sw));
		CHECK(sw == 1);
	}
	{
		// машина без ефектів у грі (вимкнені адаптивні курки): сів — автоматика не бачить, гравець тисне U;
		// 25 с їзди без ефектів режим не чіпаємо; F (вийти) — пішки
		const Ev ev[] = { {1000, 'F', 0, 0}, {5000, 'U', 1, 0}, {30000, 'F', 0, 0} };
		CHECK(!Play(gta5, false, ev, sizeof(ev) / sizeof(ev[0]), 40000, &sw));
		CHECK(sw == 1);
	}
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
