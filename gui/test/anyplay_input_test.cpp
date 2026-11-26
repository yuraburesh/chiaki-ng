// AnyPlay: тест чистої логіки стіків і визначення транспорту (без Qt).
// Запуск: g++ -std=c++17 -Wall -Wextra -I gui/include gui/test/anyplay_input_test.cpp -o /tmp/anyplay_input_test && /tmp/anyplay_input_test
// З ключем -v друкує, що вирішила автоматика на справжньому журналі 119 (рядок за рядком).
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

// input4: злам машини GTA VI — обидва стіки до упору назустріч, миша веде спільну точку дотику, без обертання по колу
static void test_hotwire()
{
	AnyPlayHotwire h;
	float lx, ly, rx, ry;
	h.Sticks(&lx, &ly, &rx, &ry);
	// стартове положення: лівий вправо, правий вліво, обидва на повну
	CHECK(NEAR(lx, 1) && NEAR(ly, 0));
	CHECK(NEAR(rx, -1) && NEAR(ry, 0));
	// миша вгору на 120 px (0,25° на піксель): точка на 30° вгору, обидва стіки вгору дзеркально
	h.Mouse(-120);
	CHECK(NEAR_DEG(h.angle, 30));
	h.Sticks(&lx, &ly, &rx, &ry);
	CHECK(NEAR(lx, 0.866) && NEAR(ly, -0.5));
	CHECK(NEAR(rx, -0.866) && NEAR(ry, -0.5));
	CHECK(NEAR(std::sqrt(lx * lx + ly * ly), 1) && NEAR(std::sqrt(rx * rx + ry * ry), 1));   // завжди до упору
	// чутливість 2: удвічі швидше
	h.Mouse(-20, 2.0);
	CHECK(NEAR_DEG(h.angle, 40));
	// далі за верх не йде: точка не перескакує на зовнішній бік (не коло)
	h.Mouse(-5000);
	CHECK(NEAR_DEG(h.angle, AnyPlayHotwireMaxDeg));
	h.Sticks(&lx, &ly, &rx, &ry);
	CHECK(NEAR(lx, 0) && NEAR(ly, -1) && NEAR(rx, 0) && NEAR(ry, -1));
	h.Mouse(10000);
	CHECK(NEAR_DEG(h.angle, -AnyPlayHotwireMaxDeg));
	// коліщатко чи ↑ ↓: дрібний крок 2°
	h.Reset();
	h.Step(AnyPlayHotwireStepDeg);
	h.Step(AnyPlayHotwireStepDeg);
	CHECK(NEAR_DEG(h.angle, 4));
	// рух миші вліво-вправо нічого не міняє: шукають місце на дузі, а не крутять
	const double before = h.angle;
	h.Mouse(0);
	CHECK(NEAR_DEG(h.angle, before));
	// ← →: лише правий стік зсувається (якщо в машини точки не дзеркальні); лівий там само
	h.Shift(AnyPlayHotwireOffsetStepDeg * 2);
	h.Sticks(&lx, &ly, &rx, &ry);
	float l0x, l0y, r0x, r0y;
	AnyPlayHotwire plain;
	plain.angle = 4;
	plain.Sticks(&l0x, &l0y, &r0x, &r0y);
	CHECK(NEAR(lx, l0x) && NEAR(ly, l0y));
	CHECK(NEAR_DEG(AnyPlayStickAngle(rx, ry), AnyPlayStickAngle(r0x, r0y) + 6));   // правий на 6° вище по своїй дузі
	h.Shift(1000);
	CHECK(NEAR_DEG(h.offset, AnyPlayHotwireMaxOffsetDeg));
	h.Reset();
	CHECK(h.angle == 0 && h.offset == 0);
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
//       'B' □, 'G' рухається a (1 тримає W A S D), 'N' дія гравця (клавіші, злам), 'W' змінив зброю
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
				case 'W': d.Weapon(e.t); break;
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
		if(d.moving)
			d.SetMoving(true, now);   // у програмі рух перевіряється кожен такт
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
	CHECK(d.Tick(26000) == 0 && !d.in_vehicle);   // input4: рівно 25 с — вікно «посадки» ще відкрите
	CHECK(d.Tick(26100) == 0 && !d.in_vehicle);
	CHECK(LogHas(d, "без підтвердження"));
	CHECK(d.f_at < 0);

	// 2. F біля машини: через 1,5 с (анімація) опір на педалях → транспорт за 0,1 с
	d.Interact(40000);
	Feed(d, RES, RES, 41500);
	CHECK(d.Tick(41550) == 0);
	CHECK(d.Tick(41600) == +1);
	CHECK(d.in_vehicle && LogHas(d, "сів у транспорт: △"));
	CHECK(d.Tick(41700) == 0);   // не повторює

	// 3. У машині F (вийти): ефекти зникли через 1,2 с → пішки через 0,15 с
	d.Interact(50000);
	Feed(d, OFF, OFF, 51200);
	CHECK(d.Tick(51300) == 0);
	CHECK(d.Tick(51350) == -1);
	CHECK(!d.in_vehicle && LogHas(d, "вийшов: △"));

	// 4. Без F (місія почалась у машині, викинув водія й сів, вікно минуло): стійкий опір на газі 0,8 с → транспорт.
	//    input4: ефекти зникли — стоїш на місці, режим лишається; рушив (W A S D) і ефектів нема 6 с → пішки
	AnyPlayVehicleDetector e;
	e.Reset(gta5, false, 0);
	Feed(e, RES, RES, 0);
	CHECK(e.Tick(700) == 0);
	CHECK(e.Tick(800) == +1);
	CHECK(LogHas(e, "без △") && e.in_vehicle);
	Feed(e, OFF, OFF, 10000);
	CHECK(e.Tick(13000) == 0);      // 3 с, як було в 119, — тепер ні
	CHECK(e.Tick(30000) == 0 && e.in_vehicle);   // стоїш (катсцена, телефон): не виходимо
	e.SetMoving(true, 30000);
	CHECK(e.Tick(30000) == -1);
	CHECK(LogHas(e, "рухаєшся"));
	// рушив, коли ефектів нема лише 2 с: чекаємо до 6 с
	AnyPlayVehicleDetector e2;
	e2.Reset(gta5, false, 0);
	Feed(e2, RES, RES, 0);
	CHECK(e2.Tick(800) == +1);
	Feed(e2, OFF, OFF, 10000);
	e2.SetMoving(true, 12000);
	CHECK(e2.Tick(15900) == 0);
	CHECK(e2.Tick(16000) == -1);
	// відпустив клавіші за 0,5 с до 6 с: ще «рухається» (до 1 с після)
	AnyPlayVehicleDetector e3;
	e3.Reset(gta5, false, 0);
	Feed(e3, RES, RES, 0);
	CHECK(e3.Tick(800) == +1);
	Feed(e3, OFF, OFF, 10000);
	e3.SetMoving(true, 14000);
	e3.SetMoving(false, 15500);
	CHECK(e3.Tick(16000) == -1);

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
	h.SetAiming(false, 10000);   // input4: відпустив, а ефект лишився — він від зброї, доки не зникне
	CHECK(h.Tick(11500) == 0);
	CHECK(h.Tick(20000) == 0 && !h.in_vehicle);
	Feed(h, OFF, OFF, 20000);    // зник і з'явився вже без прицілу (без △ — 1,5 с)
	Feed(h, RES, VIB, 21000);
	CHECK(h.Tick(22400) == 0);
	CHECK(h.Tick(22500) == +1);
	// у GTA V те саме — не транспорт
	AnyPlayVehicleDetector h5;
	h5.Reset(gta5, false, 0);
	Feed(h5, RES, VIB, 0);
	h5.Interact(0);
	CHECK(h5.Tick(10000) == 0);

	// 8. Вібрація двигуна поруч: без △ швидше (1 с); GTA VI, на газі вібрація (не опір, тож не «стійкий опір»)
	AnyPlayVehicleDetector r;
	r.Reset(gta6, false, 0);
	Feed(r, RES, VIB, 0);
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
		// input4: і без відмички ефект на газі через 11 с — ще «посадка» (25 с, журнал 119: 6–13 с)
		const Ev late[] = { {1000, 'F', 0, 0}, {12000, 'T', OFF, VIB} };
		CHECK(Play(gta6, false, late, 2, 20000, &sw));
		CHECK(sw == 1);
		// а через 27 с, коли нічого не робив, — вікно минуло; вібрація (не опір) без △ — пішки лишаються
		const Ev later[] = { {1000, 'F', 0, 0}, {28000, 'T', OFF, VIB} };
		CHECK(!Play(gta6, false, later, 2, 40000, &sw));
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
		// програв боротьбу (витягли) і пішов (W): після останнього □ ще 2,5 с тримаємо, далі «Пішки»
		int k2 = k - 2;
		ev[k2++] = {17000, 'G', 1, 0};
		int64_t out = -1;
		CHECK(!Play(gta6, false, ev, k2, 30000, &sw, &at, &out));
		CHECK(sw == 2);
		CHECK(out >= 16200 + 2500 && out <= 16200 + 2600 && at <= 16200 + 2600);   // 2,5 с після останнього □ (6 с без ефектів уже минули)
		// той самий вечір, але □ не тиснули: гра прибрала ефекти, ти стоїш — «Транспорт» лишається (input4: не 3 с)
		const Ev calm[] = { {500, 'F', 0, 0}, {2000, 'T', RES, RES}, {10000, 'T', OFF, OFF} };
		CHECK(Play(gta6, false, calm, 3, 30000, &sw, &at, &out));
		CHECK(sw == 1);
		// ... а пішов (W з 12 с) — «Пішки» рівно через 6 с без ефектів
		const Ev walk[] = { {500, 'F', 0, 0}, {2000, 'T', RES, RES}, {10000, 'T', OFF, OFF}, {12000, 'G', 1, 0} };
		CHECK(!Play(gta6, false, walk, 4, 30000, &sw, &at, &out));
		CHECK(sw == 2 && out == 16000);
	}
	{
		// Викинуло з машини, а гравець газує (W): input4 — «Пішки» через 6 с без ефектів (було 1,5 с: хибно
		// спрацьовувало б на провалах ефектів до 2 с, що видно в журналі 119)
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
		CHECK(q.Tick(11500) == 0);      // провал ефектів 1,5–4 с з газом — не вихід
		CHECK(q.Tick(14000) == 0);
		CHECK(q.Tick(15900) == 0);
		CHECK(q.Tick(16000) == -1 && LogHas(q, "рухаєшся"));
	}
}

// ── input4: справжній журнал Юрія (GTA VI, Mac, збірка 119, 26.11.2026 10:39–10:50) як тест ──
// Рядки [anyplay-mode] і [anyplay-triggers] перенесені один до одного (час у мілісекундах від 10:39:00,000):
// △ — 'F', курки — 'T' (0x21 опір, 0x05 немає), «вручну foot → vehicle» — 'U', □ (боротьба) — 'B'.
// Чого в журналі нема (тримав W A S D чи ні), додаємо окремо як припущення ('G' — «рухається»).
static int64_t J(int mm, int ss, int ms) { return ((int64_t)(mm - 39) * 60 + ss) * 1000 + ms; }

static const Ev journal119[] = {
	{J(39, 7, 786), 'T', 0x05, 0x05},
	{J(40, 30, 330), 'F', 0, 0},                                      // △: можливо, сідає (10 с минули без ефектів)
	{J(40, 41, 209), 'F', 0, 0},
	{J(41, 18, 733), 'F', 0, 0},
	{J(41, 39, 380), 'U', 1, 0},                                      // гравець сам: U → транспорт
	{J(41, 40, 495), 'T', 0x21, 0x05}, {J(41, 40, 627), 'T', 0x21, 0x21},
	{J(41, 42, 469), 'T', 0x05, 0x21}, {J(41, 43, 895), 'T', 0x21, 0x21},
	{J(41, 59, 93), 'T', 0x05, 0x21}, {J(41, 59, 354), 'F', 0, 0}, {J(41, 59, 468), 'T', 0x05, 0x05},   // вийшов
	{J(42, 3, 719), 'F', 0, 0}, {J(42, 12, 609), 'T', 0x21, 0x21},  // сів через 8,9 с після △
	{J(42, 16, 680), 'F', 0, 0}, {J(42, 16, 818), 'T', 0x05, 0x05}, // вийшов
	{J(42, 21, 471), 'F', 0, 0}, {J(42, 24, 668), 'T', 0x21, 0x21}, // сів через 3,2 с
	{J(42, 26, 136), 'T', 0x05, 0x05}, {J(42, 27, 777), 'T', 0x21, 0x05}, {J(42, 27, 947), 'T', 0x21, 0x21},
	{J(42, 28, 656), 'T', 0x05, 0x05},                                // 119: через 3 с «вийшов без △» (можливо, хибно)
	{J(43, 7, 58), 'F', 0, 0},                                        // △ (10 с минули без ефектів)
	{J(43, 20, 75), 'U', 1, 0},                                       // гравець сам: U → транспорт
	{J(43, 21, 409), 'T', 0x21, 0x05}, {J(43, 21, 581), 'T', 0x21, 0x21},
	{J(43, 25, 212), 'T', 0x05, 0x21}, {J(43, 25, 285), 'T', 0x21, 0x21}, {J(43, 25, 982), 'T', 0x05, 0x21},
	{J(43, 29, 199), 'T', 0x21, 0x21},
	{J(43, 39, 528), 'T', 0x05, 0x21}, {J(43, 40, 379), 'F', 0, 0}, {J(43, 40, 519), 'T', 0x05, 0x05},  // вийшов
	{J(43, 46, 22), 'F', 0, 0}, {J(43, 52, 476), 'T', 0x05, 0x21},  // сів через 6,5 с, спершу лише R2
	{J(43, 56, 291), 'T', 0x21, 0x21},
	{J(44, 16, 545), 'F', 0, 0}, {J(44, 16, 622), 'T', 0x05, 0x21}, {J(44, 16, 662), 'T', 0x05, 0x05},  // вийшов
	{J(44, 20, 265), 'F', 0, 0}, {J(44, 26, 243), 'T', 0x05, 0x21}, // сів через 6 с
	{J(44, 26, 526), 'T', 0x05, 0x05}, {J(44, 26, 668), 'T', 0x21, 0x05}, {J(44, 26, 882), 'T', 0x21, 0x21},
	{J(44, 30, 624), 'T', 0x05, 0x21}, {J(44, 31, 201), 'T', 0x05, 0x05}, {J(44, 31, 302), 'T', 0x21, 0x05},
	{J(44, 31, 515), 'T', 0x21, 0x21},
	{J(44, 36, 452), 'T', 0x05, 0x21}, {J(44, 36, 905), 'F', 0, 0}, {J(44, 37, 39), 'T', 0x05, 0x05},   // вийшов
	{J(44, 40, 603), 'F', 0, 0}, {J(44, 47, 876), 'T', 0x21, 0x21}, // сів через 7,3 с
	{J(44, 58, 609), 'T', 0x05, 0x05}, {J(44, 58, 900), 'B', 0, 0}, {J(44, 59, 284), 'B', 0, 0},       // боротьба
	{J(45, 1, 41), 'T', 0x21, 0x21},
	{J(45, 6, 905), 'T', 0x05, 0x05}, {J(45, 6, 950), 'B', 0, 0}, {J(45, 7, 196), 'B', 0, 0},
	{J(45, 8, 959), 'T', 0x21, 0x21},
	{J(45, 50, 835), 'T', 0x05, 0x05},                                // 119: через 3 с «вийшов без △»
};

struct Expect { int64_t t; bool vehicle; const char *what; };

// Проганяє події (такт 100 мс, курки одразу) і звіряє режим у потрібні миті; друкує, що вирішила автоматика
static void Replay(const char *title, const AnyPlayVehicleRules &rules, const Ev *ev, int n, const Expect *ex, int nx, int64_t until, bool print = false)
{
	AnyPlayVehicleDetector d;
	d.Reset(rules, false, 0);
	int i = 0, x = 0, bad = 0;
	if(print)
		std::printf("── %s ──\n", title);
	auto say = [&](int64_t t) {
		const std::string line = d.TakeLog();
		if(print && !line.empty())
			std::printf("  10:%02lld:%02lld,%03lld  %s  %s\n", (long long)(39 + t / 60000), (long long)(t / 1000 % 60), (long long)(t % 1000),
				d.in_vehicle ? "[транспорт]" : "[пішки]    ", line.c_str());
	};
	for(int64_t now = 0; now <= until; now += 100)
	{
		for(; i < n && ev[i].t <= now; i++)
		{
			const Ev &e = ev[i];
			switch(e.kind)
			{
				case 'T': Feed(d, e.a, e.b, e.t); d.Tick(e.t); break;
				case 'F': d.Interact(e.t); break;
				case 'U': d.Manual(e.a != 0, e.t); break;
				case 'B': d.Box(e.t); break;
				case 'G': d.SetMoving(e.a != 0, e.t); break;
				case 'N': d.Activity(e.t); break;
				case 'A': d.SetAiming(e.a != 0, e.t); break;
				case 'W': d.Weapon(e.t); break;
			}
			say(e.t);
		}
		if(d.moving)
			d.SetMoving(true, now);   // у програмі рух перевіряється кожен такт
		d.Tick(now);
		say(now);
		for(; x < nx && ex[x].t <= now; x++)
		{
			checks++;
			if(d.in_vehicle != ex[x].vehicle)
			{
				failures++;
				bad++;
				std::printf("ПОМИЛКА %s: о %lld мс чекали «%s» (%s)\n", title, (long long)ex[x].t, ex[x].vehicle ? "транспорт" : "пішки", ex[x].what);
			}
		}
	}
	if(print)
		std::printf("  %s: %d з %d звірок\n", title, nx - bad, nx);
}

static bool verbose = false;

static void test_journal119()
{
	const AnyPlayVehicleRules gta6 = AnyPlayVehicleRulesGta6();
	const int n = sizeof(journal119) / sizeof(journal119[0]);
	// 1. Як було: гравець двічі тиснув U сам. Тепер: короткі провали в машині не виходять, «вийшов без △» за 3 с нема,
	//    поки стоїш (у журналі не видно, чи тиснув W A S D); △ у «Транспорті», коли ефектів давно нема, — посадка
	const Expect as_is[] = {
		{J(40, 45, 0), false, "△ без ефектів: пішки"},
		{J(41, 45, 0), true, "U, ефекти з'явились"},
		{J(41, 59, 300), true, "△ натиснуто, R2 ще є"},
		{J(41, 59, 700), false, "вийшов за 0,15 с після зникнення"},
		{J(42, 12, 800), true, "сів через 8,9 с після △ (25 с вікно)"},
		{J(42, 17, 100), false, "вийшов"},
		{J(42, 24, 900), true, "сів через 3,2 с"},
		{J(42, 27, 0), true, "провал 1,6 с у машині — не вихід"},
		{J(42, 35, 0), true, "6 с без ефектів, але не рухаєшся — не вихід (у 119: «вийшов без △» о 10:42:31)"},
		{J(43, 7, 300), false, "△ без ефектів 38 с: ти пішки, △ — посадка"},
		{J(43, 22, 0), true, "U, ефекти"},
		{J(43, 26, 0), true, "провали L2 0,1–3 с — тримаємо"},
		{J(43, 40, 700), false, "вийшов"},
		{J(43, 52, 700), true, "сів через 6,5 с, лише R2"},
		{J(44, 16, 900), false, "вийшов"},
		{J(44, 26, 400), true, "сів через 6 с"},
		{J(44, 26, 600), true, "провал 0,3 с одразу після посадки"},
		{J(44, 31, 250), true, "провал 0,1 с"},
		{J(44, 37, 300), false, "вийшов"},
		{J(44, 48, 100), true, "сів через 7,3 с"},
		{J(45, 0, 500), true, "боротьба, ефектів нема 2,4 с"},
		{J(45, 8, 0), true, "боротьба знову"},
		{J(45, 56, 0), true, "ефекти зникли 5 с тому і стоїш: не вихід (у 119: «вийшов без △» о 10:45:53)"},
		{J(50, 0, 0), true, "кінець запису: стоїш, режим не скидається"},
	};
	Replay("журнал 119, як грав Юрій", gta6, journal119, n, as_is, sizeof(as_is) / sizeof(as_is[0]), J(50, 20, 0), verbose);

	// 2. Той самий вечір без U: автоматика сама вмикає «Транспорт» там, де в 119 Юрій тиснув U
	Ev noU[sizeof(journal119) / sizeof(journal119[0])];
	int k = 0;
	for(int i = 0; i < n; i++)
		if(journal119[i].kind != 'U')
			noU[k++] = journal119[i];
	const Expect auto_only[] = {
		{J(41, 40, 600), false, "лише L2, R2 ще нема"},
		{J(41, 40, 800), true, "R2 через 21,9 с після △ (вікно 25 с) — сам, без U"},
		{J(41, 59, 700), false, "вийшов"},
		{J(43, 7, 300), false, "△, ефектів давно нема: пішки і чекаємо"},
		{J(43, 21, 800), true, "R2 через 14,5 с після △ — сам, без U"},
		{J(43, 40, 700), false, "вийшов"},
		{J(44, 48, 100), true, "сів"},
		{J(45, 56, 0), true, "стоїш"},
	};
	Replay("журнал 119 без U", gta6, noU, k, auto_only, sizeof(auto_only) / sizeof(auto_only[0]), J(50, 20, 0), verbose);

	// 3. Припущення: після 10:42:28 (витягли з машини) і після 10:45:50 гравець пішов (тримав W)
	Ev walk[sizeof(journal119) / sizeof(journal119[0]) + 4];
	int w = 0;
	for(int i = 0; i < n; i++)
	{
		walk[w++] = journal119[i];
		if(journal119[i].t == J(42, 28, 656))
			walk[w++] = {J(42, 30, 0), 'G', 1, 0}, walk[w++] = {J(43, 6, 0), 'G', 0, 0};
		if(journal119[i].t == J(45, 50, 835))
			walk[w++] = {J(45, 52, 0), 'G', 1, 0};
	}
	const Expect walked[] = {
		{J(42, 34, 500), true, "пішов, але 6 с ще не минуло"},
		{J(42, 34, 800), false, "6 с без ефектів і рухаєшся: пішки (а не 3 с)"},
		{J(43, 7, 300), false, "△ пішки: посадка"},
		{J(43, 22, 0), true, "U"},
		{J(45, 56, 700), true, "6 с ще нема"},
		{J(45, 57, 0), false, "6 с і рухаєшся"},
	};
	Replay("журнал 119, якщо після виходу йшов", gta6, walk, w, walked, sizeof(walked) / sizeof(walked[0]), J(50, 20, 0), verbose);
}

// input4: посадка без △ і ризики пішки (зброя, приціл, предмети), «двічі △», довга посадка
static void test_input4()
{
	const AnyPlayVehicleRules gta6 = AnyPlayVehicleRulesGta6();
	int sw = 0;
	int64_t at = -1, out = -1;
	{
		// Викинув водія (△), боротьба □ (дія — вікно живе), сів, мотор завівся через 30 с: вікно минуло (25 с,
		// остання дія на 14 с + 8 с) — але стійкий опір на газі, не цілишся, 0,8 с → «Транспорт» сам
		Ev ev[40];
		int k = 0;
		ev[k++] = {0, 'F', 0, 0};
		for(int64_t t = 1000; t <= 14000; t += 500)
			ev[k++] = {t, 'N', 0, 0};
		ev[k++] = {30000, 'T', OFF, RES};
		CHECK(Play(gta6, false, ev, k, 40000, &sw, &at));
		CHECK(sw == 1 && at >= 30800 && at <= 30900);
		// той самий випадок, але ефект через 20 с — ще у вікні: за 0,1 с
		ev[k - 1] = {20000, 'T', OFF, RES};
		CHECK(Play(gta6, false, ev, k, 40000, &sw, &at));
		CHECK(sw == 1 && at >= 20000 && at <= 20200);
		// злам 40 с поспіль (V тримаєш, відпускаєш, знову): вікно живе до 60 с
		Ev hot[100];
		int h = 0;
		hot[h++] = {0, 'F', 0, 0};
		for(int64_t t = 1000; t <= 50000; t += 1000)
			hot[h++] = {t, 'N', 0, 0};
		hot[h++] = {50500, 'T', OFF, VIB};   // вібрація на R2 (не опір): лише через вікно
		CHECK(Play(gta6, false, hot, h, 60000, &sw, &at));
		CHECK(sw == 1 && at >= 50500 && at <= 50700);
		hot[h - 1] = {61000, 'T', OFF, VIB};   // понад 60 с — вікно закрилось
		CHECK(!Play(gta6, false, hot, h, 70000, &sw));
	}
	{
		// Зброя пішки: приціл (ПКМ) з опором на L2 і R2 — не машина, і після того, як відпустив, ефект «від зброї»
		const Ev ev[] = { {1000, 'A', 1, 0}, {1200, 'T', RES, RES}, {4000, 'A', 0, 0}, {20000, 'T', OFF, OFF} };
		CHECK(!Play(gta6, false, ev, sizeof(ev) / sizeof(ev[0]), 25000, &sw));
		CHECK(sw == 0);
		// опір на R2 з'явився, поки тримав ПКМ, відпустив — і далі той самий: не транспорт, доки не зникне
		const Ev keep[] = { {1000, 'A', 1, 0}, {1200, 'T', OFF, RES}, {3000, 'A', 0, 0} };
		CHECK(!Play(gta6, false, keep, 3, 30000, &sw));
		// відпустив приціл, і ЛИШЕ ПОТІМ (за 0,5 с) з'явився опір на R2: від зброї (1,5 с) — не рахуємо
		const Ev late[] = { {1000, 'A', 1, 0}, {3000, 'A', 0, 0}, {3500, 'T', OFF, RES} };
		CHECK(!Play(gta6, false, late, 3, 30000, &sw));
		// черга з автомата: на R2 «зброя» чи вібрація — ніколи без △
		const Ev gun[] = { {1000, 'T', RES, GUN}, {4900, 'A', 1, 0}, {5000, 'T', RES, VIB}, {6000, 'A', 0, 0}, {9000, 'T', OFF, GUN} };
		CHECK(!Play(gta6, false, gun, 5, 30000, &sw));
		// L2 «зброя», R2 опір (лук, кидок?) — не машина
		const Ev bow[] = { {1000, 'T', GUN, RES} };
		CHECK(!Play(gta6, false, bow, 1, 30000, &sw));
		// змінив зброю (Tab, колесо) і за 1 с опір на R2: від зброї, доки не зникне
		const Ev wheel[] = { {1000, 'W', 0, 0}, {2000, 'T', OFF, RES} };
		CHECK(!Play(gta6, false, wheel, 2, 30000, &sw));
		// а опір, що з'явився через 4 с після зміни зброї, — педаль (сів без △)
		const Ev later[] = { {1000, 'W', 0, 0}, {5000, 'T', OFF, RES} };
		CHECK(Play(gta6, false, later, 2, 30000, &sw, &at));
		CHECK(at >= 5800 && at <= 5900);
	}
	{
		// «Двічі △» (B або F F): вийшов, мотор працює; друге △ не відкриває «посадки»
		AnyPlayVehicleDetector d;
		d.Reset(gta6, false, 0);
		d.Interact(0);
		Feed(d, RES, RES, 2000);
		CHECK(d.Tick(2100) == +1);
		d.Interact(10000);
		Feed(d, OFF, OFF, 10100);
		CHECK(d.Tick(10200) == 0);
		CHECK(d.Tick(10300) == -1);
		d.TakeLog();
		d.Interact(10350);           // друге натискання вже пішки
		CHECK(LogHas(d, "двічі △") && d.f_at < 0);
		Feed(d, OFF, VIB, 15000);    // поруч хтось проїхав (вібрація) — без вікна пішки лишаються
		CHECK(d.Tick(16000) == 0 && !d.in_vehicle);
		// обидва натискання ще в «Транспорті» (ефекти зникли пізніше) — звичайний вихід
		AnyPlayVehicleDetector e;
		e.Reset(gta6, false, 0);
		e.Interact(0);
		Feed(e, RES, RES, 1000);
		CHECK(e.Tick(1100) == +1);
		e.Interact(5000);
		e.Interact(5200);
		Feed(e, OFF, OFF, 5400);
		CHECK(e.Tick(5600) == -1);
		// через 2 с знову △ біля машини — це вже нова посадка
		e.Interact(7600);
		CHECK(e.f_at == 7600);
	}
	{
		// Провали ефектів у машині до 4 с з газом — не вихід; 6 с і газуєш — вихід
		const Ev ev[] = { {0, 'F', 0, 0}, {1000, 'T', RES, RES}, {3000, 'G', 1, 0}, {5000, 'T', OFF, OFF}, {8900, 'T', RES, RES},
			{15000, 'T', OFF, OFF} };
		CHECK(!Play(gta6, false, ev, sizeof(ev) / sizeof(ev[0]), 30000, &sw, &at, &out));
		CHECK(sw == 2 && out == 21000);
		// без газу (стоїш) після провалу 10 с — «Транспорт»
		const Ev idle[] = { {0, 'F', 0, 0}, {1000, 'T', RES, RES}, {5000, 'T', OFF, OFF} };
		CHECK(Play(gta6, false, idle, 3, 30000, &sw));
	}
	{
		// Пауза (меню гри): рухаєшся по меню стрілками, ефектів нема хвилину — не вихід
		AnyPlayVehicleDetector m;
		m.Reset(gta6, false, 0);
		m.Interact(0);
		Feed(m, RES, RES, 500);
		CHECK(m.Tick(600) == +1);
		m.SetMenu(true, 1000);
		Feed(m, OFF, OFF, 1100);
		m.SetMoving(true, 30000);
		CHECK(m.Tick(61000) == 0 && m.in_vehicle);
	}
	{
		// Вручну «Пішки» (U), а опір на R2 ще є (гравець вважає, що вийшов): без △ не повертаємо транспорт, доки ефект той самий
		AnyPlayVehicleDetector u;
		u.Reset(gta6, false, 0);
		Feed(u, RES, RES, 0);
		CHECK(u.Tick(800) == +1);
		u.Manual(false, 2000);
		CHECK(u.Tick(30000) == 0 && !u.in_vehicle);
	}
}

int main(int argc, char **argv)
{
	verbose = argc > 1 && std::string(argv[1]) == "-v";
	test_polar();
	test_precise();
	test_hold();
	test_hotwire();
	test_vehicle();
	test_journal119();
	test_input4();
	if(failures)
	{
		std::printf("%d з %d перевірок не пройшли\n", failures, checks);
		return 1;
	}
	std::printf("УСЕ ДОБРЕ: %d перевірок\n", checks);
	return 0;
}
