// AnyPlay: стік, що крутиться по колу, поки тримаєш клавішу (злам машини в GTA VI: обидва стіки треба крутити).
// Окремий заголовок без Qt, щоб формулу можна було перевірити окремим тестом.
#ifndef ANYPLAY_SPIN_H
#define ANYPLAY_SPIN_H

#include <cmath>
#include <cstdint>

// Один оберт за стільки мілісекунд: швидко, але гра встигає зарахувати рух (≈1,25 оберту на секунду)
constexpr int64_t AnyPlaySpinPeriodMs = 800;

// Положення стіка через elapsed_ms від натискання. dir: +1 — за годинниковою стрілкою, -1 — проти.
// Починає згори (x = 0, y = -1; y < 0 — вгору, як у стіків chiaki) і йде по колу повного відхилення.
inline void AnyPlaySpinStick(int64_t elapsed_ms, int dir, float *x, float *y)
{
	constexpr double Pi = 3.14159265358979323846;   // M_PI на Windows ненадійний
	if(elapsed_ms < 0)
		elapsed_ms = 0;
	const double turns = static_cast<double>(elapsed_ms % AnyPlaySpinPeriodMs) / static_cast<double>(AnyPlaySpinPeriodMs);
	const double a = 2.0 * Pi * turns * (dir < 0 ? -1.0 : 1.0);
	*x = static_cast<float>(std::sin(a));
	*y = static_cast<float>(-std::cos(a));
}

#endif // ANYPLAY_SPIN_H
