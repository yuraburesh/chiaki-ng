// AnyPlay: клавіатура й миша замість DualSense з розкладками під гру (пішки / транспорт / авіація).
// Як на приставці: кнопка геймпада натиснута рівно стільки, скільки тримаєш клавішу.
// Коліщатко миші дає коротке натискання; комбінації (макроси) і перебір зброї по колу лишились.
#ifndef ANYPLAY_INPUT_H
#define ANYPLAY_INPUT_H

#include <chiaki/controller.h>

#include <QObject>
#include <QHash>
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
	// Hold — тримається, поки тримаєш клавішу; Tap/Turbo лишились лише для сумісності формату
	enum class Kind { Hold, Tap, Turbo, Macro, Cycle, None };
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

		// «Сісти в транспорт» натиснуто пішки, чекаємо підтвердження від приставки
		// (вібрація двигуна / опір курків). Можна читати з будь-якого потоку.
		bool VehiclePending() const { return pending.load(std::memory_order_relaxed); }
		// Сигнали від приставки, поки чекаємо (викликати в потоці об'єкта)
		void NoteHaptics();
		void NoteRumble(uint8_t left, uint8_t right);
		void NoteTriggers(uint8_t type_left, uint8_t type_right);

		// true: F перемикає на «транспорт» лише після підтвердження приставки; false: одразу
		static bool AutoVehicle();
		static void SetAutoVehicle(bool enabled);

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

	signals:
		void Changed();
		void ProfileChanged(const QString &name);

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
		QList<const APBinding *> Slots(const QString &owner) const;
		APStep Output() const;
		void SwitchProfile(const QString &target);
		void SetProfile(const QString &id, const QString &hint_text);
		QString ProfileName(const QString &id) const;
		void StartPending();
		void StopPending();
		void ConfirmVehicle();
		void StartMacro(const QList<APStep> &steps);
		void NextMacroStep();
		void AddTap(const APStep &step, int ms);

		QList<APProfile> profiles;
		QString current_profile;
		QHash<QString, APBinding> active; // утримувані клавіші -> дія, яку вони почали
		QList<Tapped> taps;
		int next_tap_id = 0;
		QList<APStep> macro;
		int macro_index = -1;
		QTimer macro_timer;
		QTimer turbo_timer;
		bool turbo_phase = false;
		int slot = 0; // яка зброя з колеса вибрана останньою (для перебору по колу)
		int wheel_sector = -1;            // сектор колеса, обраний коліщатком миші, поки колесо відкрите
		float wheel_rx = 0, wheel_ry = 0;
		QElapsedTimer clock;

		bool preview = false;
		bool auto_vehicle = true;
		std::atomic<bool> pending{false};
		QElapsedTimer pending_since;
		QTimer pending_timer;
		int haptic_hits = 0;
		QString hint;
		uint8_t trig_left = 0, trig_right = 0;       // останні типи ефектів курків від приставки
		uint8_t base_left = 0, base_right = 0;       // ... у мить натискання F
};

#endif // ANYPLAY_INPUT_H
