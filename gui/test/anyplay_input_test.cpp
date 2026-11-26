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

// Послідовність подій, як у журналі клієнта: час, що сталося. Tick — кожні 100 мс, як у програмі (118).
// kind: 'T' курки a/b, 'F' △, 'R' вібрація a/b, 'A' приціл a, 'M' меню a, 'U' вручну a (1 транспорт),
//       'B' □, 'G' газ a (1 тисне), 'N' крутить стіки (відмичка, злам)
struct Ev { int64_t t; char kind; uint8_t a, b; };

// Проганяє події й повертає режим у кінці (true — транспорт), рахуючи перемикання; *first — коли перше перемикання, *last — останнє
static bool Play(const AnyPlayVehicleRules &rules, bool start_vehicle, const Ev *ev, int n, int64_t until, int *switches, int64_t *first = nullptr, int64_t *last = nullptr)
{
	AnyPlayVehicleDetector d;
	d.Reset(rules, start_vehicle, 0);
	int i = 0;
	*switches = 0;
	if(first)
		*first = -1;
	for(int64_t now = 0; now <= until; now += 100)
	{
		for(; i < n && ev[i].t <= now; i++)
		{
			const Ev &e = ev[i];
			int r = 0;
			switch(e.kind)
			{
				// у програмі зміна курків одразу запускає перевірку (не чекає такту)
				case 'T': Feed(d, e.a, e.b, e.t); r = d.Tick(e.t); break;
				case 'F': d.Interact(e.t); break;
				case 'R': d.Rumble(e.a, e.b, e.t); break;
				case 'A': d.SetAiming(e.a != 0, e.t); break;
				case 'M': d.SetMenu(e.a != 0, e.t); break;
				case 'U': d.Manual(e.a != 0, e.t); break;
				case 'B': d.Box(e.t); break;
				case 'G': d.SetGas(e.a != 0, e.t); break;
				case 'N': d.Minigame(e.t); break;
			}
			if(r)
			{
				(*switches)++;
				if(first && *first < 0)
					*first = e.t;
				if(last)
					*last = e.t;
			}
		}
		if(d.Tick(now))
		{
			(*switches)++;
			if(first && *first < 0)
				*first = now;
			if(last)
				*last = now;
		}
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
	CHECK(d.Tick(11000) == 0 && !d.in_vehicle);   // рівно 10 с: вікно «посадки» ще відкрите
	CHECK(d.Tick(11100) == 0 && !d.in_vehicle);
	CHECK(LogHas(d, "без підтвердження"));
	CHECK(d.f_at < 0);

	// 2. F біля машини: через 1,5 с (анімація) опір на педалях → транспорт за 0,1 с
	d.Interact(20000);
	Feed(d, RES, RES, 21500);
	CHECK(d.Tick(21550) == 0);
	CHECK(d.Tick(21600) == +1);
	CHECK(d.in_vehicle && LogHas(d, "сів у транспорт: △"));
	CHECK(d.Tick(21700) == 0);   // не повторює

	// 3. У машині F (вийти): ефекти зникли через 1,2 с → пішки через 0,15 с
	d.Interact(30000);
	Feed(d, OFF, OFF, 31200);
	CHECK(d.Tick(31300) == 0);
	CHECK(d.Tick(31350) == -1);
	CHECK(!d.in_vehicle && LogHas(d, "вийшов: △"));

	// 4. Без F (місія почалась у машині): обидва курки 1,5 с; ефекти зникли (викинуло) — 3 с → пішки, не раніше
	AnyPlayVehicleDetector e;
	e.Reset(gta5, false, 0);
	Feed(e, RES, RES, 0);
	CHECK(e.Tick(1400) == 0);
	CHECK(e.Tick(1500) == +1);
	CHECK(LogHas(e, "без △"));
	Feed(e, OFF, OFF, 10000);
	CHECK(e.Tick(12900) == 0);
	CHECK(e.Tick(13000) == -1);
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
	// черга з автомата (вібрація на R2) у GTA V теж не транспорт: «сів» лише опір
	Feed(g, RES, VIB, 30000);
	CHECK(g.Tick(60000) == 0 && !g.in_vehicle);

	// 7. GTA VI: опір + вібрація означає «сів», але поки тримаєш приціл чи постріл — ні
	AnyPlayVehicleDetector h;
	h.Reset(gta6, false, 0);
	Feed(h, RES, VIB, 0);
	h.SetAiming(true, 0);
	CHECK(h.Tick(10000) == 0 && !h.in_vehicle);
	CHECK(LogHas(h, "тримаєш приціл"));
	h.SetAiming(false, 10000);   // відпустив, а ефект лишився: рахуємо від цієї миті (без △ — 1,5 с)
	CHECK(h.Tick(11400) == 0);
	CHECK(h.Tick(11500) == +1);
	// у GTA V те саме — не транспорт
	AnyPlayVehicleDetector h5;
	h5.Reset(gta5, false, 0);
	Feed(h5, RES, VIB, 0);
	h5.Interact(0);
	CHECK(h5.Tick(10000) == 0);

	// 8. Вібрація двигуна поруч: без △ швидше (1 с)
	AnyPlayVehicleDetector r;
	r.Reset(gta5, false, 0);
	Feed(r, RES, RES, 0);
	r.Rumble(40, 0, 300);
	CHECK(r.Tick(900) == 0);
	CHECK(r.Tick(1000) == +1);

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
	CHECK(m.Tick(1500) == +1);
	m.Manual(false, 3000);
	CHECK(m.Tick(5000) == 0);       // 5 с тиші після ручного
	CHECK(m.Tick(30000) == 0 && !m.in_vehicle);
	m.Interact(30500);              // △ біля тієї самої машини: ефект не новий — пішки лишаються
	CHECK(m.Tick(31000) == 0 && !m.in_vehicle);
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
	CHECK(n.Tick(80000) == 0 && !n.in_vehicle);

	// 12. Авіація (вручну F3): детектор вважає її транспортом і виходить після △ без ефектів
	AnyPlayVehicleDetector a;
	a.Reset(gta5, true, 0);
	Feed(a, RES, RES, 100);
	a.Interact(5000);
	Feed(a, OFF, OFF, 6000);
	CHECK(a.Tick(6400) == -1);

	// 13. Вигадані «записи» журналу: типові вечори в GTA V
	int sw = 0;
	int64_t at = -1;
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

	// ── 118: сценарії з відгуку Юрія ──
	{
		// «Сів — одразу їдеш»: F, підбіг і анімація 2,3 с, гра дає опір лише на газі (L2 ще без ефекту) —
		// «Транспорт» за ≤ 0,2 с від ефекту (у 117: обидва курки, 0,3 с і такт 0,2 с, а то й +2,5 с без △)
		const Ev ev[] = { {1000, 'F', 0, 0}, {3300, 'T', OFF, RES}, {4500, 'T', RES, RES} };
		CHECK(Play(gta6, false, ev, sizeof(ev) / sizeof(ev[0]), 10000, &sw, &at));
		CHECK(sw == 1 && at >= 3300 && at <= 3500);
	}
	{
		// Довга посадка: F, відмичка (крутить правий стік 8 с), ефект на газі через 11 с після F — вікно подовжилось
		Ev ev[40];
		int k = 0;
		ev[k++] = {1000, 'F', 0, 0};
		for(int64_t t = 1500; t <= 9500; t += 500)
			ev[k++] = {t, 'N', 0, 0};
		ev[k++] = {12000, 'T', OFF, VIB};   // двигун завівся: вібрація на газі
		CHECK(Play(gta6, false, ev, k, 20000, &sw, &at));
		CHECK(sw == 1 && at >= 12000 && at <= 12200);
		// без відмички (нічого не крутив) ефект лише на газі через 11 с — уже не «посадка», пішки лишаються
		const Ev late[] = { {1000, 'F', 0, 0}, {12000, 'T', OFF, VIB} };
		CHECK(!Play(gta6, false, late, 2, 20000, &sw));
		CHECK(sw == 0);
	}
	{
		// «Вийшов — одразу пішки»: F у машині, ефекти зникли — «Пішки» за ≤ 0,25 с
		const Ev ev[] = { {500, 'F', 0, 0}, {2000, 'T', RES, RES}, {10000, 'F', 0, 0}, {11200, 'T', OFF, OFF} };
		CHECK(!Play(gta6, false, ev, sizeof(ev) / sizeof(ev[0]), 15000, &sw));
		CHECK(sw == 2);
	}
	{
		// Підняв зброю на F (GTA VI): на L2 опір прицілу, на R2 «зброя» — це не машина
		// ... і ще раз F, тоді черга з автомата (ЛКМ = R2 «вібрація»): поки тримаєш постріл, ефект не рахується
		const Ev ev[] = { {1000, 'F', 0, 0}, {1400, 'T', RES, GUN}, {9000, 'F', 0, 0}, {9250, 'A', 1, 0}, {9300, 'T', RES, VIB},
			{9800, 'T', RES, GUN}, {9850, 'A', 0, 0} };
		CHECK(!Play(gta6, false, ev, sizeof(ev) / sizeof(ev[0]), 30000, &sw));
		CHECK(sw == 0);
		// підняв предмет без ефектів, а потім ішов далі — пішки весь час
		const Ev item[] = { {1000, 'F', 0, 0}, {1200, 'F', 0, 0}, {5000, 'F', 0, 0} };
		CHECK(!Play(gta6, false, item, 3, 30000, &sw));
		CHECK(sw == 0);
	}
	{
		// Боротьба в машині: НПС витягує, гра прибрала ефекти, □ тиснуть кожні 0,3 с 6 с поспіль — «Транспорт» тримається;
		// відбився, ефекти повернулись — далі газуєш у «Транспорті»
		Ev ev[60];
		int k = 0;
		ev[k++] = {500, 'F', 0, 0};
		ev[k++] = {2000, 'T', RES, RES};
		ev[k++] = {10000, 'T', OFF, OFF};
		for(int64_t t = 10200; t <= 16200; t += 300)
			ev[k++] = {t, 'B', 0, 0};
		ev[k++] = {16500, 'T', RES, RES};
		ev[k++] = {17000, 'G', 1, 0};
		CHECK(Play(gta6, false, ev, k, 30000, &sw));
		CHECK(sw == 1);
		// програв боротьбу (витягли): після останнього □ ще 2,5 с тримаємо, далі «Пішки»
		int k2 = k - 2;
		int64_t out = -1;
		CHECK(!Play(gta6, false, ev, k2, 30000, &sw, &at, &out));
		CHECK(sw == 2);
		CHECK(out >= 16200 + 2500 && out <= 16200 + 2600 && at <= 16200 + 2600);   // 2,5 с після останнього □, хоча 3 с без ефектів минули давно
		// той самий вечір, але □ не тиснули (просто стоїш, гра прибрала ефекти): «Пішки» за 3 с, як і раніше
		const Ev calm[] = { {500, 'F', 0, 0}, {2000, 'T', RES, RES}, {10000, 'T', OFF, OFF} };
		CHECK(!Play(gta6, false, calm, 3, 20000, &sw, &at, &out));
		CHECK(sw == 2 && out == 13000);
	}
	{
		// Викинуло з машини, а гравець газує (W): опору нема 1,5 с — «Пішки» швидше, ніж 3 с
		const Ev ev[] = { {500, 'F', 0, 0}, {2000, 'T', RES, RES}, {8000, 'G', 1, 0}, {10000, 'T', OFF, OFF} };
		CHECK(!Play(gta6, false, ev, sizeof(ev) / sizeof(ev[0]), 20000, &sw, &at));
		CHECK(sw == 2);
		AnyPlayVehicleDetector q;
		q.Reset(gta6, false, 0);
		q.Interact(500);
		Feed(q, RES, RES, 2000);
		CHECK(q.Tick(2100) == +1);
		q.SetGas(true, 8000);
		Feed(q, OFF, OFF, 10000);
		CHECK(q.Tick(11400) == 0);
		CHECK(q.Tick(11500) == -1 && LogHas(q, "газ"));
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
