// AnyPlay: герой справді сів у транспорт чи вийшов? Визначаємо за ефектами курків DualSense, які шле приставка,
// за натисканням △ (F з клавіатури) і вібрацією. Без Qt, щоб логіку перевіряв окремий тест.
//
// 115: F (△) НЕ перемикає режим сам. У GTA △ — це і «сісти в машину», і «підняти предмет», і «відчинити двері»,
// тож натискання лише «можлива подія»: після △ чекаємо підтвердження курками, без підтвердження нічого не міняємо.
// Ручне перемикання — окрема клавіша (U, див. розкладки), F1–F3 і вкладки на екрані клавіш.
//
// 118 (Юрій: «сів — ще 5 с чекаєш, поки кнопки почнуть працювати як у транспорті»). Звідки бралось 5+ с у 117:
//   1) «сів» вимагав ефект на ОБОХ курках, а вікно після △ було лише 4 с; у GTA VI між △ і місцем за кермом буває
//      підбіг до машини, відмичка (крутити правий стік), анімація, тож ефекти часто приходили пізніше 4 с і вмикався
//      повільний шлях «без △» (+2,5 с);
//   2) після перемикання рушій відпускав усі клавіші, а повтор клавіш ми ігноруємо: затиснута W не ставала газом,
//      доки її не відпустиш і не натиснеш знову (це виправлено в anyplayinput.cpp: утримувані W A S D переходять у новий режим);
//   3) перевірка раз на 200 мс плюс 300 мс «стабільності».
// Тепер: після △ вікно «посадки» 10 с, і воно подовжується, поки крутиш стіки (відмичка, злам машини); перший НОВИЙ
// ефект транспорту на газі R2 (опір чи вібрація, не той, що був у мить △; без «зброї» на курках) за 0,1 с вмикає «Транспорт».
// Без △ (місія почалась у машині) — обидва курки 1,5 с. «Пішки»: після △ ефекти зникли на 0,15 с.
// Боротьба в машині (НПС витягує, часто тиснеш □): поки □ тиснуть часто і ще 2,5 с після — «за часом» не виходимо.
// «За часом» (викинуло, загинув) — 3 с без ефектів транспорту, а якщо тиснеш газ і опору нема — 1,5 с.
//
// input4 — за справжнім журналом Юрія (GTA VI, Mac, збірка 119, 26.11): у машині гра ставить опір 0x21 на R2 і/або L2,
// але після △ він з'являється через 3–13 с (підбіг, витягнути водія, злам), а коли злам не вдавався — через хвилину;
// 10 с вікна часто не вистачало, і гравець перемикав U. У машині ефекти зникають на 0,1–2 с (боротьба, ривок) і
// повертаються, тож «3 с без ефектів» двічі дали хибне «вийшов». Юрій: «викинув НПС з машини, сів — режим не завжди
// перемикався». Тепер:
//   - після △ чекаємо до 25 с; поки гравець щось робить (клавіші, злам V), вікно живе ще 8 с після дії, але не довше 60 с;
//   - без △: стійкий ОПІР (саме 0x21/0x01, не «зброя» й не вібрація) на газі R2 0,8 с, коли гравець не цілиться
//     (не тримає ПКМ чи ЛКМ і відпустив їх щонайменше 1,5 с тому) і не міняв зброю 3 с — це машина;
//   - вихід: △ і ефекти зникли (0,15 с), або ефектів нема 6 с І гравець рухається (тисне W A S D); короткі провали до
//     4 с і стояння на місці «за часом» не виходять;
//   - △ одразу після виходу (двічі △ — вийти, лишивши мотор) не відкриває нової «посадки»;
//   - △ у «Транспорті», коли ефектів уже давно нема (насправді ти пішки), — це посадка в іншу машину: «Пішки» і чекаємо.
//
// Як гра задає ефекти курків (DualSense, байт режиму в пакеті Remote Play = тип у CHIAKI_EVENT_TRIGGER_EFFECTS):
//   0x00, 0x05             — без ефекту (вимкнено / скинуто), або всі 10 байтів параметрів нульові;
//   0x01, 0x21             — опір (Feedback: суцільний опір від певної точки ходу) — педалі газу й гальма, приціл;
//   0x02, 0x25, 0x22       — «зброя» (Weapon / Bow: тугий хід і клацання спуску) — постріл;
//   0x06, 0x26, 0x23, 0x27 — вібрація курка (Vibration / Galloping / Machine) — черга, двигун, пошкоджене авто;
//   решта — «інше».
// GTA V на PS5 (Sony: «адаптивні курки дають відчуття ваги й контролю зброї і транспорту»): у машині опір на газі (R2)
// і гальмі (L2), поки сидиш; пішки зі зброєю L2 (приціл) може мати легкий опір, а R2 — ефект «зброя»; без зброї обидва
// без ефекту. Тому «сів» для GTA V = опір (саме Feedback). Для GTA VI — опір або вібрація, а від помилки зі зброєю
// захищає «тримаєш приціл/постріл — не рахуємо» і «ефект, що вже був у мить △, — не новий».
// Усі рішення пишуться в журнал [anyplay-mode] з причиною і типами курків — пороги підлаштовуємо за журналами (К13).
#ifndef ANYPLAY_VEHICLE_H
#define ANYPLAY_VEHICLE_H

#include <cstdint>
#include <cstdio>
#include <string>

enum AnyPlayTrig : uint8_t
{
	AnyPlayTrigOff = 0,
	AnyPlayTrigResist,    // опір (педалі, приціл)
	AnyPlayTrigWeapon,    // спуск зброї
	AnyPlayTrigVibrate,   // вібрація курка
	AnyPlayTrigOther,
};

constexpr unsigned AnyPlayTrigBit(AnyPlayTrig c) { return 1u << c; }

// 0x00 і 0x05 — «без ефекту»; також нульові параметри (гра «вимкнула» ефект, не змінюючи режим)
inline bool AnyPlayTriggerEffectOn(uint8_t type)
{
	return type != 0x00 && type != 0x05;
}

inline bool AnyPlayTriggerDataEmpty(const uint8_t *data)
{
	if(!data)
		return false;
	for(int i = 0; i < 10; i++)
		if(data[i])
			return false;
	return true;
}

inline AnyPlayTrig AnyPlayTriggerClass(uint8_t type, bool data_empty = false)
{
	if(!AnyPlayTriggerEffectOn(type) || data_empty)
		return AnyPlayTrigOff;
	switch(type)
	{
		case 0x01: case 0x21:
			return AnyPlayTrigResist;
		case 0x02: case 0x25: case 0x22:
			return AnyPlayTrigWeapon;
		case 0x06: case 0x26: case 0x23: case 0x27:
			return AnyPlayTrigVibrate;
		default:
			return AnyPlayTrigOther;
	}
}

inline const char *AnyPlayTrigName(AnyPlayTrig c)
{
	switch(c)
	{
		case AnyPlayTrigOff: return "немає";
		case AnyPlayTrigResist: return "опір";
		case AnyPlayTrigWeapon: return "зброя";
		case AnyPlayTrigVibrate: return "вібрація";
		default: return "інше";
	}
}

// Правила окремо для кожної гри (розкладки)
struct AnyPlayVehicleRules
{
	const char *game = "gta5";
	unsigned enter_left = AnyPlayTrigBit(AnyPlayTrigResist);   // який ефект на L2 (гальмо) означає «сів»
	unsigned enter_right = AnyPlayTrigBit(AnyPlayTrigResist);  // ... і на R2 (газ); після △ досить одного нового
	unsigned keep = AnyPlayTrigBit(AnyPlayTrigResist) | AnyPlayTrigBit(AnyPlayTrigVibrate); // хоч один курок з таким — ще в транспорті
	int64_t f_window_ms = 25000;         // після △ («посадка») чекаємо підтвердження курками щонайменше стільки
	int64_t f_extend_ms = 8000;          // ... а поки гравець щось робить (клавіші, злам), ще стільки після останньої дії
	int64_t f_window_max_ms = 60000;     // ... але не довше
	int64_t exit_window_ms = 10000;      // після △ у транспорті: ефекти зникли за стільки — вийшов
	int64_t enter_one_ms = 100;          // після △: новий ефект транспорту на R2 (газ) тримається стільки → транспорт
	int64_t enter_after_f_ms = 100;      // після △: «сів»-ефект на обох курках тримається стільки → транспорт
	int64_t enter_alone_ms = 1500;       // без △ (місія почалась у машині, катсцена): обидва курки стільки
	int64_t enter_alone_rumble_ms = 1000;// ... а якщо поруч вібрація (двигун) — швидше
	int64_t enter_gas_ms = 800;          // без △: стійкий опір на газі R2, коли не цілишся, стільки → транспорт
	int64_t aim_grace_ms = 1500;         // відпустив приціл чи постріл: стільки ефекти ще вважаємо зброєю
	int64_t weapon_grace_ms = 3000;      // міняв зброю (колесо, кобура): стільки опір на R2 може бути від неї
	int64_t exit_after_f_ms = 150;       // після △: ефектів транспорту нема стільки → пішки
	int64_t exit_alone_ms = 6000;        // без △ (викинуло, загинув): стільки без ефектів І гравець рухається → пішки
	int64_t move_recent_ms = 1000;       // «рухається»: тримає W A S D (газ, гальмо, кермо) або відпустив не раніше стількох
	int64_t gone_before_f_ms = 2000;     // △ у транспорті, а ефектів нема вже стільки — це посадка в іншу машину
	int64_t double_f_ms = 800;           // △ стільки після виходу — друге натискання «двічі △», не посадка
	int64_t struggle_tap_ms = 700;       // два □ з таким проміжком — «боротьба» (НПС витягує з машини)
	int64_t struggle_hold_ms = 2500;     // ... і ще стільки після останнього □ «за часом» не виходимо
	int64_t manual_grace_ms = 5000;      // після ручного перемикання (U, F1–F3, вкладка) автоматика мовчить
	int64_t rumble_recent_ms = 1500;     // вібрація вважається «щойно» стільки
	int64_t no_effects_warn_ms = 60000;  // стільки гри без жодного ефекту курків — підказати, що автоматика не працюватиме
};

// GTA V на PS5: «сів» = опір на обох педалях; зброя пішки (R2 «зброя») ніколи не вмикає транспорт
inline AnyPlayVehicleRules AnyPlayVehicleRulesGta5()
{
	return AnyPlayVehicleRules();
}

// GTA VI: журнал 119 — у машині опір 0x21 на R2 і/або L2; вібрацію лишаємо (двигун на високих обертах, пошкоджене авто)
inline AnyPlayVehicleRules AnyPlayVehicleRulesGta6()
{
	AnyPlayVehicleRules r;
	r.game = "gta6";
	r.enter_left = AnyPlayTrigBit(AnyPlayTrigResist) | AnyPlayTrigBit(AnyPlayTrigVibrate);
	r.enter_right = AnyPlayTrigBit(AnyPlayTrigResist) | AnyPlayTrigBit(AnyPlayTrigVibrate);
	return r;
}

inline AnyPlayVehicleRules AnyPlayVehicleRulesFor(const std::string &layout)
{
	return layout == "gta6" ? AnyPlayVehicleRulesGta6() : AnyPlayVehicleRulesGta5();
}

struct AnyPlayVehicleDetector
{
	AnyPlayVehicleRules rules;
	bool in_vehicle = false;       // що ми зараз вважаємо (режим клавіш); «Авіація» теж true
	AnyPlayTrig left = AnyPlayTrigOff, right = AnyPlayTrigOff;
	uint8_t type_left = 0, type_right = 0;
	bool aiming = false;           // пішки тримають приціл або постріл з клавіатури: ефекти зброї, не транспорт
	bool menu = false;             // відкрита пауза чи мапа гри: вихід «за часом» вимкнено
	bool seen_any = false;         // гра хоч раз давала будь-який ефект (адаптивні курки увімкнені)
	bool confirmed = false;        // у транспорті: ефект транспорту хоч раз був (інакше «за часом» не виходимо)
	bool block_enter = false;      // гравець сам обрав «пішки», а ефект ще той самий: чекаємо, поки зникне
	bool warned_no_effects = false;
	bool aim_noted = false;        // у журналі вже сказано «ефект є, але тримаєш приціл»
	bool moving = false;           // у транспорті тримають W A S D (газ, гальмо, кермо)
	int64_t start_at = 0;
	int64_t enter_since = -1;      // відколи на ОБОХ курках «сів»-ефект (-1: нема)
	int64_t one_since = -1;        // відколи новий (після △) ефект транспорту на R2 (-1: нема)
	int64_t gas_since = -1;        // відколи на R2 стійкий опір без «зброї» на L2, поки не цілишся (-1: нема)
	bool gas_weapon = false;       // цей опір на R2 з'явився, коли цілився чи міняв зброю: це зброя, доки не зникне
	bool enter_weapon = false;     // те саме для ефекту на обох курках (без △)
	int64_t keep_lost_since = -1;  // відколи нема жодного ефекту транспорту (-1: є)
	int64_t f_at = -1;             // коли натиснули △ (-1: нема відкритого вікна)
	int64_t act_at = -1;           // остання дія гравця після △ (клавіші, злам): пішки вікно «посадки» живе довше
	AnyPlayTrig f_right = AnyPlayTrigOff;   // ефект на R2 в мить △: він не «новий»
	int64_t manual_until = 0;      // до цієї миті автоматика мовчить
	int64_t last_rumble = -1;      // коли востаннє була вібрація (-1: ніколи)
	int64_t last_box = -1;         // коли востаннє тиснули □ (-1: ніколи)
	int64_t struggle_until = -1;   // до цієї миті «боротьба в машині»: за часом не виходимо
	int64_t aim_end = -1;          // коли відпустили приціл чи постріл (-1: ще не цілились)
	int64_t last_weapon = -1;      // коли міняли зброю (колесо, кобура, цифри) (-1: ніколи)
	int64_t last_move = -1;        // коли востаннє тримали W A S D у транспорті (-1: ніколи)
	int64_t exit_at = -1;          // коли автоматика востаннє вивела «пішки» (-1: ні)
	uint8_t rumble_l = 0, rumble_r = 0;
	std::string log;               // причина останнього рішення чи події для журналу; викликач забирає і чистить

	bool EnterSig() const
	{
		return (rules.enter_left & AnyPlayTrigBit(left)) && (rules.enter_right & AnyPlayTrigBit(right));
	}
	bool KeepSig() const
	{
		return (rules.keep & AnyPlayTrigBit(left)) || (rules.keep & AnyPlayTrigBit(right));
	}
	// Після △ на R2 (газ) з'явився ефект транспорту, якого не було в мить △. Лише R2: на L2 опір буває й пішки
	// (приціл, коли підняв зброю), а R2 зі зброєю — «зброя», не опір. Якщо хоч на одному курку «зброя» — це не машина.
	bool OneSig() const
	{
		if(left == AnyPlayTrigWeapon || right == AnyPlayTrigWeapon)
			return false;
		return (rules.enter_right & AnyPlayTrigBit(right)) && right != f_right;
	}
	// input4, без △: на газі R2 саме ОПІР (педаль), не «зброя» і не вібрація (черга з автомата); на L2 не «зброя»
	bool GasSig() const
	{
		return right == AnyPlayTrigResist && left != AnyPlayTrigWeapon && left != AnyPlayTrigOther;
	}
	// Кінець вікна після △: у транспорті — exit_window_ms; пішки — 25 с, а поки гравець діє, ще 8 с після дії (до 60 с)
	int64_t FWindowEnd() const
	{
		if(f_at < 0)
			return -1;
		if(in_vehicle)
			return f_at + rules.exit_window_ms;
		int64_t end = f_at + rules.f_window_ms;
		if(act_at >= f_at && act_at + rules.f_extend_ms > end)
			end = act_at + rules.f_extend_ms;
		if(end > f_at + rules.f_window_max_ms)
			end = f_at + rules.f_window_max_ms;
		return end;
	}
	bool FWindow(int64_t now) const
	{
		return f_at >= 0 && now <= FWindowEnd();
	}
	bool Struggling(int64_t now) const
	{
		return struggle_until >= 0 && now < struggle_until;
	}
	bool MovingNow(int64_t now) const
	{
		return moving || (last_move >= 0 && now - last_move <= rules.move_recent_ms);
	}
	// Ефекти на курках зараз можуть бути від зброї: тримаєш приціл чи постріл, щойно відпустив, щойно міняв зброю
	bool WeaponRecent(int64_t now) const
	{
		return aiming || (aim_end >= 0 && now - aim_end < rules.aim_grace_ms)
			|| (last_weapon >= 0 && now - last_weapon < rules.weapon_grace_ms);
	}
	std::string TrigText() const
	{
		char buf[96];
		std::snprintf(buf, sizeof(buf), "L=%02x %s, R=%02x %s", type_left, AnyPlayTrigName(left), type_right, AnyPlayTrigName(right));
		return buf;
	}
	static std::string Sec(int64_t ms)
	{
		char buf[32];
		std::snprintf(buf, sizeof(buf), "%lld,%lld с", (long long)(ms / 1000), (long long)((ms % 1000) / 100));
		return buf;
	}
	void Note(const std::string &line)
	{
		if(!log.empty())
			log += "; ";
		log += line;
	}

	// Початок гри або нова розкладка: приставка ще нічого не казала
	void Reset(const AnyPlayVehicleRules &r, bool vehicle, int64_t now)
	{
		const bool keep_seen = seen_any;   // розкладку міняють посеред гри: курки вже працювали
		const bool keep_warned = warned_no_effects;
		*this = AnyPlayVehicleDetector();
		rules = r;
		in_vehicle = vehicle;
		seen_any = keep_seen;
		warned_no_effects = keep_warned;
		start_at = now;
		keep_lost_since = now;
	}

	// Гравець перемкнув сам (U, F1–F3, вкладка): приймаємо і кілька секунд не сперечаємось
	void Manual(bool vehicle, int64_t now)
	{
		in_vehicle = vehicle;
		manual_until = now + rules.manual_grace_ms;
		f_at = -1;
		act_at = -1;
		one_since = -1;
		aim_noted = false;
		exit_at = -1;
		if(vehicle)
		{
			// без ефектів транспорту (човен, гра без адаптивних курків) «за часом» не виходимо, доки ефект не з'явиться
			confirmed = KeepSig();
			keep_lost_since = KeepSig() ? -1 : now;
			block_enter = false;
		}
		else
		{
			// гравець каже «пішки», хоча ефект ще є: нове «сів» лише після того, як ефект зникне
			block_enter = EnterSig() || KeepSig();
			enter_since = EnterSig() ? now : -1;
			gas_since = -1;
			gas_weapon = false;
		}
	}

	// Відкрити вікно «посадки» після △ (пішки)
	void OpenEnter(int64_t now)
	{
		f_at = now;
		act_at = now;
		f_right = right;   // ефекти, що вже є в мить △ (наприклад, приціл зі зброєю), «новими» не вважаємо
		one_since = -1;
	}

	// Натиснули △ (F чи будь-яка клавіша, що дає △): можливо, сідає в машину або виходить
	void Interact(int64_t now)
	{
		if(!in_vehicle && exit_at >= 0 && now - exit_at <= rules.double_f_ms)
		{
			// друге натискання «двічі △» (вийти, лишивши мотор): ти вже вийшов, це не посадка
			Note("△ ще раз одразу після виходу (двічі △: мотор лишився працювати): не посадка");
			return;
		}
		const bool reopen = FWindow(now);
		if(!reopen)
		{
			OpenEnter(now);
			Note(std::string("△: ") + (in_vehicle ? "можливо, виходить" : "можливо, сідає")
				+ ", чекаю підтвердження курками до " + Sec(in_vehicle ? rules.exit_window_ms : rules.f_window_ms)
				+ (in_vehicle ? std::string() : std::string(" (поки щось робиш, довше)")) + " (" + TrigText() + ")");
		}
		else
		{
			f_at = now;
			act_at = now;
		}
		if(!seen_any && !warned_no_effects && now - start_at >= rules.no_effects_warn_ms)
		{
			warned_no_effects = true;
			Note("гра не надсилає ефектів курків: автоматика не бачить транспорту, перемикай вручну");
		}
	}

	// Гравець щось робить після △ (тисне клавіші гри, ламає машину): «посадка» ще триває
	void Activity(int64_t now)
	{
		if(f_at >= 0 && !in_vehicle && FWindow(now))
			act_at = now;
	}
	void Minigame(int64_t now) { Activity(now); }

	// Міняв зброю (колесо, кобура, цифри): опір на R2 якийсь час може бути від неї
	void Weapon(int64_t now)
	{
		last_weapon = now;
		if(gas_since >= 0)
			gas_weapon = true;
		if(enter_since >= 0)
			enter_weapon = true;
	}

	// □ у транспорті: два швидкі поспіль — боротьба (НПС витягує з машини), «за часом» не виходимо
	void Box(int64_t now)
	{
		if(in_vehicle && last_box >= 0 && now - last_box <= rules.struggle_tap_ms)
		{
			if(!Struggling(now))
				Note("часто тиснеш □ у транспорті: боротьба, режим «транспорт» тримаю");
			struggle_until = now + rules.struggle_hold_ms;
		}
		else if(Struggling(now))
			struggle_until = now + rules.struggle_hold_ms;
		last_box = now;
	}

	// У транспорті тримають W A S D (газ, гальмо, кермо): без ефектів 6 с і рухаєшся — ти вже пішки
	void SetMoving(bool on, int64_t now)
	{
		if(on || moving)
			last_move = now;   // тримає або щойно відпустив
		moving = on;
	}
	void SetGas(bool on, int64_t now) { SetMoving(on, now); }

	// Приставка надіслала ефекти курків
	void Triggers(AnyPlayTrig l, AnyPlayTrig r, uint8_t tl, uint8_t tr, int64_t now)
	{
		left = l;
		right = r;
		type_left = tl;
		type_right = tr;
		if(l != AnyPlayTrigOff || r != AnyPlayTrigOff)
			seen_any = true;
		if(EnterSig())
		{
			if(enter_since < 0)
			{
				enter_since = now;
				enter_weapon = WeaponRecent(now);
			}
		}
		else
		{
			enter_since = -1;
			enter_weapon = false;
			aim_noted = false;
		}
		if(OneSig())
		{
			if(one_since < 0)
				one_since = now;
		}
		else
			one_since = -1;
		if(GasSig())
		{
			if(gas_since < 0)
			{
				gas_since = now;
				gas_weapon = WeaponRecent(now);
			}
		}
		else
		{
			gas_since = -1;
			gas_weapon = false;
		}
		if(KeepSig())
		{
			keep_lost_since = -1;
			if(in_vehicle)
				confirmed = true;
		}
		else
		{
			if(keep_lost_since < 0)
				keep_lost_since = now;
			block_enter = false;   // ефект зник: наступний — уже нова машина
		}
	}

	void Rumble(uint8_t l, uint8_t r, int64_t now)
	{
		rumble_l = l;
		rumble_r = r;
		if(l || r)
			last_rumble = now;
	}

	// Пішки тримають приціл/постріл (L2/R2 з клавіатури): ефекти зараз від зброї
	void SetAiming(bool on, int64_t now)
	{
		if(aiming && !on)
			aim_end = now;
		aiming = on;
		if(on && (enter_since >= 0 || one_since >= 0 || gas_since >= 0))
		{
			// рахуємо заново після того, як відпустить; без △ ефект, що є під час прицілу, — від зброї, доки не зникне
			if(enter_since >= 0)
			{
				enter_since = now;
				enter_weapon = true;
			}
			if(one_since >= 0)
				one_since = now;
			if(gas_since >= 0)
			{
				gas_since = now;
				gas_weapon = true;   // опір на R2 під час прицілу — від зброї, доки не зникне
			}
			if(!in_vehicle && !aim_noted)
			{
				aim_noted = true;
				Note("ефект на курках, але тримаєш приціл чи постріл: це зброя, не транспорт (" + TrigText() + ")");
			}
		}
	}

	// Пауза, мапа, кнопка PS: гра могла прибрати ефекти, бо меню; вихід «за часом» не рахуємо
	void SetMenu(bool on, int64_t now)
	{
		if(on == menu)
			return;
		menu = on;
		// повернулись у гру: ефекти можуть з'явитися не одразу, тож відлік «без ефектів» починаємо заново
		if(!on && keep_lost_since >= 0)
			keep_lost_since = now;
		Note(on ? "меню гри відкрите: вихід за часом вимкнено" : "меню гри закрите");
	}

	// Перевірка (кілька разів на секунду і щойно змінились курки). +1 — перемкнути на транспорт, -1 — на пішки, 0 — нічого
	int Tick(int64_t now)
	{
		const bool fwin = FWindow(now);
		if(now < manual_until)
		{
			f_at = -1;
			return 0;
		}
		if(!in_vehicle)
		{
			if(aiming)
			{
				if(enter_since >= 0)
				{
					enter_since = now;
					enter_weapon = true;
				}
				if(one_since >= 0)
					one_since = now;
				if(gas_since >= 0)
				{
					gas_since = now;
					gas_weapon = true;
				}
			}
			// приціл щойно відпустили: ефекти ще від зброї (рахуємо від кінця «зброї»)
			const bool weapon = WeaponRecent(now);
			if(!block_enter && !weapon)
			{
				// після △: новий ефект транспорту на газі
				if(fwin && one_since >= 0 && now - one_since >= rules.enter_one_ms)
				{
					Note("сів у транспорт: △ і новий ефект на газі (R2) " + Sec(now - one_since) + " (" + TrigText() + ")");
					return Switch(true, now);
				}
				if(enter_since >= 0)
				{
					const int64_t dur = now - enter_since;
					if(fwin && dur >= rules.enter_after_f_ms)
					{
						Note("сів у транспорт: △ і ефект на обох курках " + Sec(dur) + " (" + TrigText() + ")");
						return Switch(true, now);
					}
					const bool rumble_recent = last_rumble >= 0 && now - last_rumble <= rules.rumble_recent_ms;
					const int64_t need = rumble_recent ? rules.enter_alone_rumble_ms : rules.enter_alone_ms;
					if(dur >= need && !enter_weapon)
					{
						char buf[64];
						std::snprintf(buf, sizeof(buf), ", вібрація %u/%u", rumble_l, rumble_r);
						Note("сів у транспорт без △: ефект на обох курках " + Sec(dur) + " (" + TrigText() + (rumble_recent ? std::string(buf) : std::string()) + ")");
						return Switch(true, now);
					}
				}
				// input4: без △ (викинув водія і сів, вікно вже минуло) — стійкий опір педалі газу, коли не цілишся
				if(gas_since >= 0 && !gas_weapon)
				{
					// від кінця прицілу чи зміни зброї рахуємо заново
					int64_t since = gas_since;
					if(aim_end >= 0 && aim_end + rules.aim_grace_ms > since)
						since = aim_end + rules.aim_grace_ms;
					if(last_weapon >= 0 && last_weapon + rules.weapon_grace_ms > since)
						since = last_weapon + rules.weapon_grace_ms;
					if(now - since >= rules.enter_gas_ms)
					{
						Note("сів у транспорт без △: стійкий опір на газі (R2) " + Sec(now - gas_since) + ", не цілишся (" + TrigText() + ")");
						return Switch(true, now);
					}
				}
			}
		}
		else if(keep_lost_since >= 0)
		{
			const int64_t dur = now - keep_lost_since;
			// △ натиснули незадовго до того, як ефекти зникли (вікно ще відкрите), або вже після
			if(fwin && dur >= rules.exit_after_f_ms)
			{
				const int64_t pressed = f_at;
				const bool long_gone = keep_lost_since <= pressed - rules.gone_before_f_ms;
				if(long_gone)
				{
					// ефектів не було ще до △: ти вже пішки, а △ — посадка в іншу машину
					Note("△, а ефектів транспорту нема вже " + Sec(pressed - keep_lost_since) + " до натискання: ти пішки, △ — посадка, чекаю курки (" + TrigText() + ")");
					const int r = Switch(false, now);
					exit_at = -1;
					OpenEnter(pressed);
					return r;
				}
				Note("вийшов: △ і ефекти транспорту зникли " + Sec(dur) + " (" + TrigText() + ")");
				return Switch(false, now);
			}
			const bool quiet = confirmed && !menu && !Struggling(now);
			if(quiet && dur >= rules.exit_alone_ms && MovingNow(now))
			{
				Note("вийшов без △: " + Sec(dur) + " без ефектів транспорту, а ти рухаєшся (" + TrigText() + ")");
				return Switch(false, now);
			}
		}
		if(f_at >= 0 && !fwin)
		{
			Note(std::string("△ без підтвердження курками за ") + Sec(now - f_at) + ": режим «"
				+ (in_vehicle ? "транспорт" : "пішки") + "» лишається (" + TrigText() + ")");
			f_at = -1;
			act_at = -1;
			one_since = -1;
		}
		return 0;
	}

	// Забрати текст для журналу (порожній — нічого не сталося)
	std::string TakeLog()
	{
		std::string out;
		out.swap(log);
		return out;
	}

private:
	int Switch(bool vehicle, int64_t now)
	{
		in_vehicle = vehicle;
		f_at = -1;
		act_at = -1;
		one_since = -1;
		aim_noted = false;
		struggle_until = -1;
		last_box = -1;
		moving = false;
		last_move = -1;
		if(vehicle)
		{
			confirmed = true;
			keep_lost_since = -1;   // «сів»-ефект завжди й ефект транспорту
			exit_at = -1;
		}
		else
		{
			block_enter = false;
			gas_since = -1;     // опір, що лишився з машини, не «новий»: чекаємо, поки зникне і з'явиться знову
			enter_since = -1;
			exit_at = now;
		}
		return vehicle ? +1 : -1;
	}
};

#endif // ANYPLAY_VEHICLE_H
