// AnyPlay: герой справді сів у транспорт чи вийшов? Визначаємо за ефектами курків і вібрацією від приставки
// (без Qt, щоб логіку перевіряв окремий тест).
//
// Гіпотеза (журнали [anyplay-triggers] / [anyplay-rumble] збірки 110+; справжнього журналу GTA VI ще немає):
//  - у транспорті гра ставить ефект (опір) на ОБИДВА курки: R2 газ і L2 гальмо, і тримає його, поки сидиш;
//  - пішки зі зброєю ефект лише на R2 (спуск), L2 без ефекту; без зброї обидва без ефекту.
// Тож «у транспорті» = обидва курки з ефектом стабільно ≥ 1,5 с (з вібрацією двигуна поруч — швидше),
// «пішки» = обидва без ефекту ≥ 2 с. Вихід «пішки» рахуємо лише якщо гра взагалі хоч раз давала ефекти на обидва
// курки: якщо адаптивні курки в грі вимкнені, автоматика мовчить і працює лише F.
// F лишається ручним перемикачем: після нього автоматика кілька секунд не сперечається (герой ще йде до машини).
#ifndef ANYPLAY_VEHICLE_H
#define ANYPLAY_VEHICLE_H

#include <cstdint>

constexpr int64_t AnyPlayVehicleEnterMs = 1500;        // обидва курки з ефектом стільки → транспорт
constexpr int64_t AnyPlayVehicleEnterRumbleMs = 1000;  // ... а якщо при цьому була вібрація (двигун) — швидше
constexpr int64_t AnyPlayVehicleExitMs = 2000;         // обидва курки без ефекту стільки → пішки
constexpr int64_t AnyPlayVehicleManualGraceMs = 8000;  // після F автоматика мовчить (герой іде до машини, анімація посадки)
constexpr int64_t AnyPlayVehicleRumbleRecentMs = 1500; // вібрація вважається «щойно» стільки

// 0x00 і 0x05 — «без ефекту» (DualSense: off / reset); решта — опір, спуск, вібрація курка тощо
inline bool AnyPlayTriggerEffectOn(uint8_t type)
{
	return type != 0x00 && type != 0x05;
}

struct AnyPlayVehicleDetector
{
	bool in_vehicle = false;       // що ми зараз вважаємо (режим клавіш)
	bool left_on = false, right_on = false;
	bool seen_both = false;        // гра хоч раз давала ефект на обидва курки (адаптивні курки увімкнені)
	int64_t both_on_since = -1;    // відколи обидва з ефектом (-1: не обидва)
	int64_t both_off_since = -1;   // відколи обидва без ефекту
	int64_t manual_until = 0;      // до цієї миті автоматика мовчить
	int64_t last_rumble = -1;      // коли востаннє була вібрація (-1: ніколи)

	// Початок гри: приставка ще нічого не казала, вважаємо, що курки без ефекту від цієї миті
	void Reset(bool vehicle, int64_t now)
	{
		in_vehicle = vehicle;
		left_on = right_on = false;
		seen_both = false;
		both_on_since = -1;
		both_off_since = now;
		manual_until = 0;
		last_rumble = -1;
	}

	// Гравець натиснув F (чи F1/F2): приймаємо його вибір і не сперечаємось кілька секунд
	void Manual(bool vehicle, int64_t now)
	{
		in_vehicle = vehicle;
		manual_until = now + AnyPlayVehicleManualGraceMs;
		// відлік «стабільно» починається заново, інакше старий стан спрацював би одразу після паузи
		if(both_on_since >= 0)
			both_on_since = now;
		if(both_off_since >= 0)
			both_off_since = now;
	}

	// Приставка надіслала типи ефектів курків
	void Triggers(uint8_t type_left, uint8_t type_right, int64_t now)
	{
		left_on = AnyPlayTriggerEffectOn(type_left);
		right_on = AnyPlayTriggerEffectOn(type_right);
		const bool both_on = left_on && right_on;
		const bool both_off = !left_on && !right_on;
		if(both_on)
		{
			seen_both = true;
			if(both_on_since < 0)
				both_on_since = now;
		}
		else
			both_on_since = -1;
		if(both_off)
		{
			if(both_off_since < 0)
				both_off_since = now;
		}
		else
			both_off_since = -1;
	}

	void Rumble(bool on, int64_t now)
	{
		if(on)
			last_rumble = now;
	}

	// Перевірка (кілька разів на секунду). +1 — перемкнути на транспорт, -1 — на пішки, 0 — нічого
	int Tick(int64_t now)
	{
		if(now < manual_until)
			return 0;
		if(!in_vehicle && both_on_since >= 0)
		{
			const bool rumble_recent = last_rumble >= 0 && now - last_rumble <= AnyPlayVehicleRumbleRecentMs;
			const int64_t need = rumble_recent ? AnyPlayVehicleEnterRumbleMs : AnyPlayVehicleEnterMs;
			if(now - both_on_since >= need)
			{
				in_vehicle = true;
				return +1;
			}
		}
		if(in_vehicle && seen_both && both_off_since >= 0 && now - both_off_since >= AnyPlayVehicleExitMs)
		{
			in_vehicle = false;
			return -1;
		}
		return 0;
	}
};

#endif // ANYPLAY_VEHICLE_H
