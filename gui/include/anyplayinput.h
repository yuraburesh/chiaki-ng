// AnyPlay: клавіатура й миша замість DualSense з розкладками під гру (пішки / транспорт / авіація).
// Як на приставці: кнопка геймпада натиснута рівно стільки, скільки тримаєш клавішу.
// Коліщатко миші дає коротке натискання; комбінації (макроси) і перебір зброї по колу лишились.
#ifndef ANYPLAY_INPUT_H
#define ANYPLAY_INPUT_H

#include <chiaki/controller.h>
#include "anyplaystick.h"
#include "anyplayvehicle.h"

#include <QObject>
#include <QHash>
#include <QSet>
#include <QList>
#include <QString>
#include <QTimer>
#include <QElapsedTimer>
#include <atomic>
#include <QJsonObject>
#include <QVariantList>
#include <QVariantMap>

class QKeyEvent;

struct APStep
{
	uint32_t buttons = 0; // кнопки chiaki, плюс CHIAKI_CONTROLLER_ANALOG_BUTTON_L2/R2 для курків
	float lx = 0, ly = 0, rx = 0, ry = 0; // відхилення стіків -1..1 (y < 0 — вгору)
	int ms = 0; // тривалість кроку комбінації
};

struct APBinding
{
	// Hold — тримається, поки тримаєш клавішу; Tap/Turbo лишились лише для сумісності формату.
	// Precise — точний режим лівого стіка (тримай), StickHold — «утримати» правий стік (перемикач),
	// Hotwire — злам машини GTA VI (тримай: стіки зведені назустріч, миша веде точку дотику). Див. anyplaystick.h
	// Spin — стік по колу, поки тримаєш (input4: лише відмичка Slim Jim на K/L; для заводу двигуна — Hotwire)
	enum class Kind { Hold, Tap, Turbo, Macro, Cycle, Spin, Precise, StickHold, Hotwire, None };
	QString id;
	QString name;  // показується на екрані клавіш
	QString key;   // назва клавіші, див. AnyPlayInput::KeyName
	Kind kind = Kind::Hold;
	APStep out;
	QList<APStep> steps; // Macro
	int dir = 1;         // Cycle: +1 наступна зброя, -1 попередня
	uint32_t when = 0;   // працює лише поки натиснута ця кнопка (наприклад L2 — у прицілі)
	// інша дія, поки натиснута aim_when (колесо в GTA VI: без прицілу — колесо зброї по колу, у прицілі — △)
	uint32_t aim_when = 0;
	APStep aim_out;
	// Клавіша зброї (slot1…): поки тримаєш — колесо відкрите на цьому секторі, відпустив — зброя обрана.
	// Коротке натискання тримає колесо щонайменше hold_min мс, щоб гра встигла прийняти вибір.
	bool hold_open = false;
	APStep hold_out;
	int hold_min = 0;
	qint64 pressed_at = 0;   // коли натиснули (лише для утримуваних дій)
	// Spin: поки тримаєш, стік крутиться по колу (злам машини в GTA VI). +1 — за годинниковою, -1 — проти, 0 — не чіпає
	int spin_l = 0, spin_r = 0;
	QString profile;     // режим, у який перемкнутись: id або "toggle" (пішки <-> транспорт)
	QString owner;       // режим, якому належить дія
};

struct APProfile
{
	QString id;
	QString name;
	QList<APBinding> bindings;
};

class AnyPlayInput : public QObject
{
	Q_OBJECT

	public:
		explicit AnyPlayInput(QObject *parent = nullptr);
		~AnyPlayInput() override;

		// Читає вбудовану розкладку і зміни клієнта з налаштувань. Поточний режим лишається, якщо він є в розкладці.
		void Load();

		// Клавіша або кнопка миші натиснута / відпущена. true — якщо вона щось робить у грі.
		bool HandleInput(const QString &name, bool pressed);
		// Коротке натискання (поділка коліщатка). true — якщо призначено.
		bool Tap(const QString &name);
		void ReleaseAll();

		// 118: що зараз фізично затиснуто (клавіші й кнопки миші) — для тесту і журналу
		QStringList HeldKeys() const { return QStringList(held.begin(), held.end()); }
		// Злам машини (V) чи відмичка (K/L) зараз ведуть стіки
		bool MinigameActive() const;
		// input4: стан зламу машини для підказки на екрані (AnyPlayHud):
		// {active, angle (градуси, + угору), offset (правий стік окремо), rumble (0..100, вібрація від гри), tip (уперше)}
		QVariantMap MinigameState() const;

		// Записує в state кнопки, курки й стіки, які зараз іде на приставку
		void ApplyTo(ChiakiControllerState *state) const;

		QString CurrentProfileId() const { return current_profile; }
		QString CurrentProfileName() const;
		// Назва режиму або коротка підказка про перемикання — показується на екрані на мить
		QString StatusText() const { return hint.isEmpty() ? CurrentProfileName() : hint; }
		// Перемкнути режим вручну (вкладки на екрані клавіш)
		void SetCurrentProfile(const QString &id);
		// Екран клавіш поза грою: приставки немає, тож режим транспорту вмикається одразу
		void SetPreview(bool preview);
		// Що зараз натиснуто: {buttons: [назви кнопок], lx, ly, rx, ry, profile}
		QVariantMap PreviewState() const;
		// Справжній геймпад для екрана клавіш: {buttons: [назви кнопок, L2/R2 з половини ходу], lx, ly, rx, ry}
		// з мертвою зоною 0.14 і округленням до сотих (щоб не смикати екран від шуму стіків)
		static QVariantMap PadState(const ChiakiControllerState &state);

		// Сигнали від приставки для автоматичного «Транспорт» / «Пішки» і для занурення (викликати в потоці об'єкта)
		// 118: NoteTriggers одразу перевіряє автоматику (не чекаючи такту), щоб «сів — одразу їдеш»
		void NoteRumble(uint8_t left, uint8_t right);
		// empty_*: усі 10 байтів параметрів ефекту нульові (гра прибрала ефект, не змінивши тип)
		void NoteTriggers(uint8_t type_left, uint8_t type_right, bool empty_left = false, bool empty_right = false);

		// «Автоматично визначати транспорт»: режим перемикається сам за ефектами курків, △ і вібрацією
		// (anyplayvehicle.h, правила окремо для GTA V і GTA VI). 115: F (△) режим не перемикає, лише «можлива подія»;
		// вручну — клавіша з "profile": "toggle" (U), F1–F3, вкладки. Типово увімкнено.
		static bool AutoVehicle();
		static void SetAutoVehicle(bool enabled);

		// Миша під час гри: поки активні «утримати правий стік» або злам машини, рух миші іде сюди,
		// а не в звичайну камеру. CapturesMouse можна читати лише в потоці об'єкта.
		bool CapturesMouse() const { return hotwire_active || stick_hold; }
		void MouseDelta(double dx, double dy);
		// Множник чутливості миші для камери зараз: «повільніша миша в прицілі» (поки натиснуто L2 пішки)
		float MouseScale() const;
		// Зараз грають геймпадом: занурення для клавіатури (тремор, віддача від пострілу) мовчить
		void SetGamepadMode(bool gamepad) { gamepad_mode = gamepad; }

		// Налаштування керування (QSettings anyplay/<name>) з типовими значеннями, для екрана клавіш і сесії:
		// auto_vehicle, haptic_strong, kick_screen, tremor, aim_slow, menu_create, menu_sticks
		static QVariant Option(const QString &name);
		static void SetOption(const QString &name, const QVariant &value);
		static QVariantMap Options();

		// Миша -> правий стік (камера): чутливість 0.3–3.0 і інверсія вертикалі. Читаються з будь-якого потоку.
		// Окремо для «пішки» і для транспорту (транспорт і авіація — mode "vehicle" чи "air"; решта — пішки).
		// Поки для транспорту нічого не задано, діє та сама, що пішки.
		static float MouseSensitivity(const QString &mode = QString());
		static void SetMouseSensitivity(float value, const QString &mode = QString());
		static bool IsVehicleMode(const QString &mode) { return mode == QLatin1String("vehicle") || mode == QLatin1String("air"); }
		static bool InvertY();
		static void SetInvertY(bool invert);
		// Показувати вибір гри («У що граєш?») перед грою
		static bool AskGame();
		static void SetAskGame(bool ask);
		// Екран клавіш поза грою показує натискання справжнього геймпада: поки він відкритий,
		// кнопки геймпада не перетворюються на клавіші навігації (інакше ○ була б Esc, L3 — F1 тощо)
		static bool PadPreview();
		static void SetPadPreview(bool on);

		// Назви клавіш
		static QString KeyName(const QKeyEvent *event);
		static QString KeyNameFromQml(int key, int modifiers, const QString &text, int scan_code = 0);
		static QString MouseButtonName(Qt::MouseButton button);
		static QString DisplayName(const QString &key);
		// Клавіша ` (ліворуч від 1, під Esc; § на європейських MacBook) відкриває меню AnyPlay:
		// її не можна призначити дії в грі. Розпізнається за фізичним місцем, на будь-якій мові клавіатури.
		static bool IsMenuKey(const QKeyEvent *event);
		static QString MenuKeyName() { return QStringLiteral("`"); }
		// Запам'ятовує фізичну клавішу останнього натискання, щоб екран клавіш у QML
		// розпізнавав літери й ` за місцем, а не за мовою клавіатури
		static void InstallKeyWatcher();

		// Розкладки під гру (GTA VI / GTA V / інша гра): у кожної свої режими і свої зміни клавіш
		static QVariantList Layouts();
		static QString Layout();
		static void SetLayout(const QString &id);
		// Екран клавіш
		static QVariantList ProfilesForEditor();
		// Поточна розкладка цілком: {layout, start, profiles: ProfilesForEditor()}
		static QVariantMap EditorData();
		static void SetKeyOverride(const QString &profile, const QString &id, const QString &key);
		static void ResetKeyOverrides();
		// Призначити клавішу дії. Та сама клавіша в іншої дії того ж режиму (або спільних клавіш) знімається з неї.
		// {ok, reason: "menu" | "same" | "missing" | "", cleared: [{profile, id, name}]}
		static QVariantMap Rebind(const QString &profile, const QString &id, const QString &key);
		// Малюнок геймпада: шари, світіння, точки для ліній, сітка зайнятості (з :/anyplay-pad/pad.json)
		static QVariantMap PadData();
		// Розкладку або клавіші змінили: усі рушії (і той, що зараз у грі) перечитують їх одразу
		static void NotifyConfigChanged();
		// Режим рушія, що зараз у грі (не екран клавіш): "foot" | "vehicle" | "air"; "" — гри немає.
		// Для телеметрії: адмін бачить, у якому режимі клавіш грає клієнт. Викликати в потоці інтерфейсу.
		static QString LiveMode();

	signals:
		void Changed();
		void ProfileChanged(const QString &name);
		// Постріл або удар з клавіатури: віддача на екрані (сила 0..1), якщо увімкнено kick_screen
		void Kick(float strength);
		// Автоматика або гравець перемкнули режим, або причина, чому не перемкнули; текст для журналу [anyplay-mode]
		void VehicleLog(const QString &line);
		// input4: злам машини почався, закінчився або точка зрушила (MinigameState)
		void MinigameChanged();

	private:
		struct Tapped { int id; APStep step; };

		static QJsonObject DefaultConfig(const QString &layout);
		static QList<APProfile> ParseProfiles(const QJsonObject &config, const QString &layout, bool apply_overrides);
		static void PruneOverrides(const QString &layout, const QJsonObject &config);
		const APBinding *Find(const QString &name) const;
		bool Allowed(const APBinding &b) const;
		bool AimNow(const APBinding &b) const;
		void Run(const APBinding &b, bool tap);
		void Cycle(const APBinding &b);
		void NoteSlot(const APBinding &b);
		bool WheelStep(const APBinding &b);   // колесо зброї відкрите: коліщатко миші переводить вибір на сусідній сектор
		void AfterRelease();
		// 118: зміна режиму (автоматика, U, F1–F3, вкладка): усі спец-стани (обертання, злам машини, «утримати» стік,
		// точний рух, колесо, комбінації) скидаються, а затиснуті W A S D / газ / гальмо одразу діють у новому режимі
		void ResetForMode();
		bool Carryable(const APBinding &b, const QString &name) const;
		// Зупинити злам машини й обертання стіків, хоч клавіші ще затиснуті (машина завелась, газуєш): стіки в центр
		void StopMinigame(const QString &why);
		QList<const APBinding *> Slots(const QString &owner) const;
		APStep Output() const;
		void SwitchProfile(const QString &target);
		QString ToggleKeyName() const;            // клавіша ручного «пішки ↔ транспорт» ("" — нема)
		QString ModeHint(const QString &id) const; // «🚗 Транспорт. U — назад «🚶 Пішки»»
		void SetProfile(const QString &id, const QString &hint_text);
		QString ProfileName(const QString &id) const;
		void StartMacro(const QList<APStep> &steps);
		void NextMacroStep();
		void AddTap(const APStep &step, int ms);

		QList<APProfile> profiles;
		QString current_profile;
		QHash<QString, APBinding> active; // утримувані клавіші -> дія, яку вони почали
		QSet<QString> held;               // 118: фізично затиснуті клавіші й кнопки миші (і ті, чия дія вже скинута)
		QList<Tapped> taps;
		int next_tap_id = 0;
		QList<APStep> macro;
		int macro_index = -1;
		QTimer macro_timer;
		QTimer turbo_timer;
		QTimer spin_timer;   // поки крутиться стік: стан на приставку ~60 разів на секунду
		void UpdateSpinTimer();
		bool turbo_phase = false;
		int slot = 0; // яка зброя з колеса вибрана останньою (для перебору по колу)
		int wheel_sector = -1;            // сектор колеса, обраний коліщатком миші, поки колесо відкрите
		float wheel_rx = 0, wheel_ry = 0;
		QElapsedTimer clock;

		bool preview = false;
		bool gamepad_mode = false;
		bool auto_vehicle = true;
		QString hint;

		// транспорт/пішки по-справжньому (anyplayvehicle.h): перевірка кілька разів на секунду
		AnyPlayVehicleDetector vehicle;
		QTimer vehicle_timer;
		uint8_t trig_left = 0, trig_right = 0;       // останні типи ефектів курків від приставки
		uint8_t rumble_left = 0, rumble_right = 0;   // остання вібрація
		void TickVehicle();
		void ApplyAuto(bool to_vehicle, const QString &why);
		void NoteGameEvent(const APBinding &b);   // △ і меню гри для автоматики
		void FlushVehicleLog();

		// точний режим лівого стіка (тримають клавішу Precise)
		bool precise_active = false;
		QString precise_key;
		AnyPlayPreciseStick precise;
		QHash<QString, int> precise_keys;            // натиснуті клавіші руху в точному режимі → роль (1 вліво, 2 вправо, 3 вперед, 4 назад)
		qint64 precise_tick = 0;
		bool PreciseRole(const APBinding &b, int *role) const;
		void UpdatePrecise();

		// «утримати» правий стік: точка, яку тягне миша
		bool stick_hold = false;
		AnyPlayMousePoint mouse_point;
		// злам машини (input4): обидва стіки до упору назустріч, миша веде спільну точку дотику по дузі
		bool hotwire_active = false;
		QString hotwire_key;
		AnyPlayHotwire hotwire;
		qint64 hotwire_pressed_at = 0;
		qint64 hotwire_released_at = -1;
		int hotwire_count = 0;          // скільки разів тримали V за цю гру (уперше — порада про «Упрощенные мини-игры»)
		int hotwire_shown = 9999;       // кут, який востаннє показали на екрані (щоб не смикати підказку від кожного пікселя)
		void StartHotwire(const QString &key);
		void EndHotwire(bool released);
		void HotwireMoved();

		// тремор камери від вібрації: кілька кадрів правий стік смикається на ±amp
		qint64 tremor_until = 0;
		qint64 tremor_last = 0;
		float tremor_amp = 0;
		bool tremor_phase = false;
};

#endif // ANYPLAY_INPUT_H
