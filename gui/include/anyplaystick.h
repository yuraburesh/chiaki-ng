// AnyPlay: плавні стіки з клавіатури й миші (без Qt, щоб формули перевіряв окремий тест).
//
// Три речі, яких бракувало клавіатурі проти геймпада:
//  1. «Точний режим» лівого стіка: тримаєш клавішу (Alt) і клавіші руху крутять стік по колу
//     плавно, за кутом, а не 8 напрямками; відпустив клавішу руху — стік лишається там, де був.
//  2. «Утримати» правий стік: мишею виставляєш напрям, стік не повертається в центр, поки режим увімкнено.
//  3. Злам машини (GTA VI) одним жестом: тримаєш V, обидва стіки виставляються назустріч (L▸ ◂R),
//     мишею крутиш обидва синхронно: правий за мишею, лівий дзеркально по горизонталі.
//
// Усі кути в градусах, 0 — угору, за годинниковою стрілкою (як дивишся на стік згори).
// Вісь y стіка в chiaki: y < 0 — угору.
#ifndef ANYPLAY_STICK_H
#define ANYPLAY_STICK_H

#include <cmath>
#include <cstdint>

constexpr double AnyPlayPi = 3.14159265358979323846;   // M_PI на Windows ненадійний

// Точний режим: швидкість повороту і зміни сили, поки тримаєш клавішу напрямку
constexpr double AnyPlayPreciseTurnDegPerSec = 270.0;  // три чверті кола за секунду: і швидко, і можна зупинитись на 10–15°
constexpr double AnyPlayPreciseMagPerSec = 2.5;        // від нуля до повного відхилення за 0,4 с
constexpr double AnyPlayPreciseMinMag = 0.0;

// «Утримати» правий стік: скільки пікселів миші на повне відхилення (при чутливості 1,0)
constexpr double AnyPlayHoldRadiusPx = 140.0;
// Злам машини: радіус кола миші, по якому крутяться стіки (менший — чутливіше)
constexpr double AnyPlayHotwireRadiusPx = 36.0;
// Злам машини: крок коліщатка або стрілок
constexpr double AnyPlayHotwireStepDeg = 12.0;

inline double AnyPlayWrapDeg(double a)
{
	a = std::fmod(a, 360.0);
	if(a < 0)
		a += 360.0;
	return a;
}

// Кут (0 угору, за годинниковою) і сила 0..1 → відхилення стіка
inline void AnyPlayPolarToStick(double angle_deg, double mag, float *x, float *y)
{
	if(mag < 0)
		mag = 0;
	if(mag > 1)
		mag = 1;
	const double a = angle_deg * AnyPlayPi / 180.0;
	*x = static_cast<float>(mag * std::sin(a));
	*y = static_cast<float>(-mag * std::cos(a));
}

// Відхилення стіка → кут 0..360 (0 угору, за годинниковою). Нуль-вектор дає 0.
inline double AnyPlayStickAngle(double x, double y)
{
	if(std::fabs(x) < 1e-9 && std::fabs(y) < 1e-9)
		return 0.0;
	return AnyPlayWrapDeg(std::atan2(x, -y) * 180.0 / AnyPlayPi);
}

// ── 1. Точний режим ──
struct AnyPlayPreciseStick
{
	double angle = 0.0;   // градуси
	double mag = 1.0;     // 0..1
	int turn = 0;         // -1 проти годинникової, +1 за, 0 стоїть (поки тримають «вліво»/«вправо»)
	int push = 0;         // +1 сила росте («вперед»), -1 спадає («назад»), 0 стоїть

	// Увімкнули: починаємо з того, куди стік дивиться зараз (клавіші руху вже натиснуті), інакше вгору на повну
	void Start(double lx, double ly)
	{
		turn = 0;
		push = 0;
		const double len = std::sqrt(lx * lx + ly * ly);
		if(len > 0.05)
		{
			angle = AnyPlayStickAngle(lx, ly);
			mag = len > 1.0 ? 1.0 : len;
		}
		else
		{
			angle = 0.0;
			mag = 1.0;
		}
	}

	// Минуло dt_ms: стік доїжджає; відпущені клавіші нічого не змінюють (положення тримається)
	void Advance(int64_t dt_ms)
	{
		if(dt_ms <= 0)
			return;
		const double dt = dt_ms / 1000.0;
		if(turn)
			angle = AnyPlayWrapDeg(angle + turn * AnyPlayPreciseTurnDegPerSec * dt);
		if(push)
		{
			mag += push * AnyPlayPreciseMagPerSec * dt;
			if(mag < AnyPlayPreciseMinMag)
				mag = AnyPlayPreciseMinMag;
			if(mag > 1.0)
				mag = 1.0;
		}
	}

	bool Moving() const { return turn != 0 || push != 0; }

	void Stick(float *x, float *y) const { AnyPlayPolarToStick(angle, mag, x, y); }
};

// ── 2. «Утримати» правий стік: точка, яку мишка тягне в колі радіуса radius_px ──
struct AnyPlayMousePoint
{
	double x = 0.0, y = 0.0;

	void Reset() { x = 0.0; y = 0.0; }

	// Рух миші на dx, dy пікселів; точка не виходить за коло
	void Move(double dx, double dy, double radius_px)
	{
		x += dx;
		y += dy;
		Clamp(radius_px);
	}

	void Clamp(double radius_px)
	{
		const double len = std::sqrt(x * x + y * y);
		if(len > radius_px && len > 0)
		{
			x *= radius_px / len;
			y *= radius_px / len;
		}
	}

	// Повернути точку навколо центру на deg градусів за годинниковою стрілкою (як дивишся на екран)
	void Rotate(double deg)
	{
		const double a = deg * AnyPlayPi / 180.0;
		const double nx = x * std::cos(a) - y * std::sin(a);
		const double ny = x * std::sin(a) + y * std::cos(a);
		x = nx;
		y = ny;
	}

	double Length() const { return std::sqrt(x * x + y * y); }
};

// Стік у режимі «утримати»: відхилення пропорційне відстані від центру (y миші вниз = стік униз, як у chiaki)
inline void AnyPlayHoldStick(const AnyPlayMousePoint &p, double radius_px, bool invert_y, float *x, float *y)
{
	const double k = radius_px > 0 ? 1.0 / radius_px : 0.0;
	double sx = p.x * k, sy = p.y * k;
	const double len = std::sqrt(sx * sx + sy * sy);
	if(len > 1.0)
	{
		sx /= len;
		sy /= len;
	}
	*x = static_cast<float>(sx);
	*y = static_cast<float>(invert_y ? -sy : sy);
}

// ── 3. Злам машини ──
// Початок: правий стік дивиться вліво (◂R), лівий дзеркально — вправо (L▸): стіки «назустріч»
inline void AnyPlayHotwireStart(AnyPlayMousePoint *p, double radius_px)
{
	p->x = -radius_px;
	p->y = 0.0;
}

// Обидва стіки з точки миші: правий — у напрямку точки на повну силу, лівий — дзеркально по горизонталі.
// Якщо точка в центрі (ще не рухали), стіки лишаються назустріч.
inline void AnyPlayHotwireSticks(const AnyPlayMousePoint &p, float *lx, float *ly, float *rx, float *ry)
{
	const double len = p.Length();
	double dx = -1.0, dy = 0.0;
	if(len > 1e-6)
	{
		dx = p.x / len;
		dy = p.y / len;
	}
	*rx = static_cast<float>(dx);
	*ry = static_cast<float>(dy);
	*lx = static_cast<float>(-dx);
	*ly = static_cast<float>(dy);
}

#endif // ANYPLAY_STICK_H
