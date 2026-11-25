#include "anyplayinput.h"
#include "anyplayspin.h"
#include "settings.h"

#include <QCoreApplication>
#include <QMutex>
#include <QMutexLocker>
#include <QPointF>
#include <algorithm>
#include <cmath>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QMetaObject>
#include <QPointer>
#include <QRegularExpression>
#include <QSet>
#include <QSettings>
#include <QStringList>
#include <QVariantMap>

namespace {

constexpr int TurboIntervalMs = 55;  // старий формат «turbo»: кнопка натискається ~9 разів на секунду
constexpr int SpinTickMs = 16;       // обертання стіка: оновлення ~60 разів на секунду, коло плавне
constexpr int TapMs = 90;            // коротке натискання (коліщатко): досить довге, щоб гра його помітила

const QString OverrideGroupBase = QStringLiteral("anyplay_keys");
const QString LayoutKey = QStringLiteral("anyplay/layout");
const QString SensitivityKey = QStringLiteral("anyplay/mouse_sensitivity");
const QString VehicleSensitivityKey = QStringLiteral("anyplay/mouse_sensitivity_vehicle");
const QString InvertYKey = QStringLiteral("anyplay/invert_y");
const QString AskGameKey = QStringLiteral("anyplay/ask_game");
const QStringList LayoutIds = {QStringLiteral("gta6"), QStringLiteral("gta5"), QStringLiteral("universal")};
// змінені клієнтом клавіші зберігаються окремо для кожної розкладки (GTA 5 — на старому місці)
QString OverrideGroupFor(const QString &layout)
{
	return layout == QLatin1String("gta5") ? OverrideGroupBase : OverrideGroupBase + QLatin1Char('_') + layout;
}
// v3: автоматика в обидва боки за ефектами курків (anyplayvehicle.h), типово увімкнена; v2 чекала підтвердження після F
const QString AutoVehicleKey = QStringLiteral("anyplay/auto_vehicle_v3");
constexpr int VehicleTickMs = 200;       // як часто перевіряємо, чи герой сів у транспорт або вийшов
constexpr int PreciseTapMs = 300;        // коротше натискання клавіші точного режиму вмикає його до наступного натискання
constexpr float AimSlowFactor = 0.6f;    // «повільніша миша в прицілі»: чутливість у прицілі
constexpr int TremorMs = 110;            // тремор камери від вібрації: тривалість одного поштовху
constexpr int TremorMinGapMs = 260;      // ... не частіше
constexpr int TremorMinRumble = 90;      // ... лише від помітної вібрації (0..255)

// Налаштування керування з типовими значеннями: екран клавіш читає і пише через Option/SetOption
const QList<QPair<QString, QVariant>> &OptionDefaults()
{
	static const QList<QPair<QString, QVariant>> defaults = {
		{QStringLiteral("auto_vehicle"), true},    // «Автоматично визначати транспорт»
		{QStringLiteral("haptic_strong"), false},  // «Віддача на екрані»: сильно (false — м'яко)
		{QStringLiteral("kick_screen"), true},     // віддача на екрані від пострілів і ударів з клавіатури
		{QStringLiteral("tremor"), false},         // тремор камери від вібрації (правий стік смикається)
		{QStringLiteral("aim_slow"), false},       // повільніша миша в прицілі
		{QStringLiteral("menu_create"), true},     // утримання Create 1 с відкриває меню AnyPlay
		{QStringLiteral("menu_sticks"), false},    // L3 + R3 разом 1 с теж відкриває меню
	};
	return defaults;
}
QString OptionKey(const QString &name)
{
	return name == QLatin1String("auto_vehicle") ? AutoVehicleKey : QStringLiteral("anyplay/") + name;
}
QMutex option_mutex;
QHash<QString, QVariant> option_cache;   // прочитане з налаштувань: миша питає кілька сотень разів на секунду

constexpr float MinSensitivity = 0.3f;
constexpr float MaxSensitivity = 3.0f;
std::atomic<float> cached_sensitivity{-1.0f}; // -1: ще не прочитано з налаштувань
std::atomic<float> cached_vehicle_sensitivity{-1.0f}; // -1: ще не прочитано; 0: не задано, діє та сама, що пішки
std::atomic<int> cached_invert{-1};
std::atomic<bool> pad_preview{false};   // екран клавіш показує справжній геймпад

// кнопки геймпада за назвами з файлів розкладок; порядок — для показу на екрані клавіш
const QList<QPair<QString, uint32_t>> &ButtonList()
{
	static const QList<QPair<QString, uint32_t>> buttons = {
		{"CROSS", CHIAKI_CONTROLLER_BUTTON_CROSS}, {"MOON", CHIAKI_CONTROLLER_BUTTON_MOON},
		{"BOX", CHIAKI_CONTROLLER_BUTTON_BOX}, {"PYRAMID", CHIAKI_CONTROLLER_BUTTON_PYRAMID},
		{"DPAD_LEFT", CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT}, {"DPAD_RIGHT", CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT},
		{"DPAD_UP", CHIAKI_CONTROLLER_BUTTON_DPAD_UP}, {"DPAD_DOWN", CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN},
		{"L1", CHIAKI_CONTROLLER_BUTTON_L1}, {"R1", CHIAKI_CONTROLLER_BUTTON_R1},
		{"L3", CHIAKI_CONTROLLER_BUTTON_L3}, {"R3", CHIAKI_CONTROLLER_BUTTON_R3},
		{"OPTIONS", CHIAKI_CONTROLLER_BUTTON_OPTIONS}, {"SHARE", CHIAKI_CONTROLLER_BUTTON_SHARE},
		{"TOUCHPAD", CHIAKI_CONTROLLER_BUTTON_TOUCHPAD}, {"PS", CHIAKI_CONTROLLER_BUTTON_PS},
		{"L2", CHIAKI_CONTROLLER_ANALOG_BUTTON_L2}, {"R2", CHIAKI_CONTROLLER_ANALOG_BUTTON_R2},
	};
	return buttons;
}

uint32_t ButtonFromName(const QString &name)
{
	const QString upper = name.toUpper();
	for(const auto &b : ButtonList())
		if(b.first == upper)
			return b.second;
	return 0;
}

APStep StepFromJson(const QJsonObject &o)
{
	APStep step;
	for(const auto &b : o.value("btn").toArray())
		step.buttons |= ButtonFromName(b.toString());
	const QJsonArray l = o.value("l").toArray();
	if(l.size() == 2) { step.lx = float(l[0].toDouble()); step.ly = float(l[1].toDouble()); }
	const QJsonArray r = o.value("r").toArray();
	if(r.size() == 2) { step.rx = float(r[0].toDouble()); step.ry = float(r[1].toDouble()); }
	step.ms = o.value("ms").toInt(0);
	return step;
}

void AddStep(APStep *sum, const APStep &step)
{
	sum->buttons |= step.buttons;
	sum->lx += step.lx; sum->ly += step.ly;
	sum->rx += step.rx; sum->ry += step.ry;
}

int16_t Axis(float v)
{
	return static_cast<int16_t>(qBound(-1.0f, v, 1.0f) * 32767.0f);
}

// кирилична літера -> латинська клавіша на тому самому місці (українська/російська ЙЦУКЕН)
QString LatinForCyrillic(QChar c)
{
	static const QHash<QChar, QString> map = {
		{u'й', "Q"}, {u'ц', "W"}, {u'у', "E"}, {u'к', "R"}, {u'е', "T"}, {u'н', "Y"}, {u'г', "U"},
		{u'ш', "I"}, {u'щ', "O"}, {u'з', "P"}, {u'ф', "A"}, {u'і', "S"}, {u'ы', "S"}, {u'в', "D"},
		{u'а', "F"}, {u'п', "G"}, {u'р', "H"}, {u'о', "J"}, {u'л', "K"}, {u'д', "L"}, {u'я', "Z"},
		{u'ч', "X"}, {u'с', "C"}, {u'м', "V"}, {u'и', "B"}, {u'т', "N"}, {u'ь', "M"}, {u'ґ', "U"},
	};
	return map.value(c.toLower());
}

QString NameForQtKey(int key, bool keypad)
{
	if(keypad && key >= Qt::Key_0 && key <= Qt::Key_9)
		return QStringLiteral("Num%1").arg(key - Qt::Key_0);
	if((key >= Qt::Key_A && key <= Qt::Key_Z) || (key >= Qt::Key_0 && key <= Qt::Key_9))
		return QString(QChar(static_cast<char16_t>(key)));
	if(key >= Qt::Key_F1 && key <= Qt::Key_F24)
		return QStringLiteral("F%1").arg(key - Qt::Key_F1 + 1);
	switch(key)
	{
		case Qt::Key_Shift: return "Shift";
#ifdef Q_OS_MACOS
		// на Mac Qt називає Control клавішею Meta, а Command — Control
		case Qt::Key_Meta: return "Ctrl";
		case Qt::Key_Control: return "Cmd";
#else
		case Qt::Key_Control: return "Ctrl";
		case Qt::Key_Meta: return "Win";
#endif
		case Qt::Key_Alt: return "Alt";
		case Qt::Key_AltGr: return "Alt";
		case Qt::Key_Tab: case Qt::Key_Backtab: return "Tab";
		case Qt::Key_Space: return "Space";
		case Qt::Key_Escape: return "Esc";
		case Qt::Key_Return: case Qt::Key_Enter: return "Enter";
		case Qt::Key_Backspace: return "Backspace";
		case Qt::Key_CapsLock: return "CapsLock";
		case Qt::Key_Up: return "Up";
		case Qt::Key_Down: return "Down";
		case Qt::Key_Left: return "Left";
		case Qt::Key_Right: return "Right";
		case Qt::Key_Home: return "Home";
		case Qt::Key_End: return "End";
		case Qt::Key_PageUp: return "PageUp";
		case Qt::Key_PageDown: return "PageDown";
		case Qt::Key_Insert: return "Insert";
		case Qt::Key_Delete: return "Delete";
		case Qt::Key_Minus: return "-";
		case Qt::Key_Equal: return "=";
		case Qt::Key_BracketLeft: return "[";
		case Qt::Key_BracketRight: return "]";
		case Qt::Key_Semicolon: return ";";
		case Qt::Key_Apostrophe: return "'";
		case Qt::Key_Comma: return ",";
		case Qt::Key_Period: return ".";
		case Qt::Key_Slash: return "/";
		case Qt::Key_Backslash: return "\\";
		case Qt::Key_QuoteLeft: return "`";
		default: return QString();
	}
}

// клавіша меню AnyPlay за кодом Qt або (у QML, де є лише код сканування) за фізичним місцем
bool IsMenuKeyCode(int key, quint32 scan_code)
{
	switch(key)
	{
		case Qt::Key_QuoteLeft: case Qt::Key_AsciiTilde: case Qt::Key_Dead_Grave:
		case Qt::Key_section: case Qt::Key_plusminus:
			return true;
		default:
			break;
	}
#if defined(Q_OS_WIN)
	return scan_code == 0x29;
#elif defined(Q_OS_MACOS)
	Q_UNUSED(scan_code);
	return false;
#else
	return scan_code == 49; // X11/Wayland: TLDE (evdev 41 + 8)
#endif
}

// усі рушії клавіш у програмі: коли розкладку чи клавіші змінили, кожен перечитує їх
QList<AnyPlayInput *> &Instances()
{
	static QList<AnyPlayInput *> list;
	return list;
}

// останнє натискання клавіші в програмі: QML не бачить фізичних кодів, а рушій їх розпізнає
class KeyWatcher : public QObject
{
	public:
		using QObject::QObject;
		int key = 0;
		QString name;

		bool eventFilter(QObject *obj, QEvent *event) override
		{
			if(event->type() == QEvent::KeyPress || event->type() == QEvent::KeyRelease)
			{
				const auto *k = static_cast<const QKeyEvent *>(event);
				key = k->key();
				name = AnyPlayInput::KeyName(k);
			}
			return QObject::eventFilter(obj, event);
		}
};
QPointer<KeyWatcher> key_watcher;

} // namespace

AnyPlayInput::AnyPlayInput(QObject *parent) : QObject(parent)
{
	Instances().append(this);
	clock.start();
	macro_timer.setSingleShot(true);
	connect(&macro_timer, &QTimer::timeout, this, &AnyPlayInput::NextMacroStep);
	turbo_timer.setInterval(TurboIntervalMs);
	connect(&turbo_timer, &QTimer::timeout, this, [this]() {
		turbo_phase = !turbo_phase;
		emit Changed();
	});
	spin_timer.setInterval(SpinTickMs);
	spin_timer.setTimerType(Qt::PreciseTimer);
	// той самий такт ~60 разів на секунду веде обертання стіка, точний режим, злам машини, «утримати» стік і тремор
	connect(&spin_timer, &QTimer::timeout, this, [this]() {
		const qint64 now = clock.elapsed();
		if(precise_active)
		{
			precise.Advance(now - precise_tick);
			precise_tick = now;
		}
		tremor_phase = !tremor_phase;
		if(tremor_until && now >= tremor_until)
		{
			tremor_until = 0;
			UpdateSpinTimer();
		}
		emit Changed();
	});
	vehicle_timer.setInterval(VehicleTickMs);
	connect(&vehicle_timer, &QTimer::timeout, this, &AnyPlayInput::TickVehicle);
}

AnyPlayInput::~AnyPlayInput()
{
	Instances().removeAll(this);
}

QJsonObject AnyPlayInput::DefaultConfig(const QString &layout)
{
	QFile file(layout == QLatin1String("gta5") ? QStringLiteral(":/anyplay/anyplay-controls.json")
		: QStringLiteral(":/anyplay/anyplay-controls-%1.json").arg(layout));
	if(!file.open(QIODevice::ReadOnly))
		return {};
	return QJsonDocument::fromJson(file.readAll()).object();
}

// Зміни клієнта для дій, яких у розкладці вже нема, прибираємо; клавішу меню (`) теж
void AnyPlayInput::PruneOverrides(const QString &layout, const QJsonObject &config)
{
	static QSet<QString> done;
	if(done.contains(layout) || config.isEmpty())
		return;
	done.insert(layout);
	QSet<QString> ids;
	for(const auto &p : config.value("profiles").toArray())
	{
		const QJsonObject po = p.toObject();
		for(const auto &b : po.value("bindings").toArray())
			ids.insert(po.value("id").toString() + QLatin1Char('/') + b.toObject().value("id").toString());
	}
	QSettings settings;
	settings.beginGroup(OverrideGroupFor(layout));
	for(const QString &profile : settings.childGroups())
	{
		settings.beginGroup(profile);
		for(const QString &id : settings.childKeys())
			if(!ids.contains(profile + QLatin1Char('/') + id) || settings.value(id).toString() == MenuKeyName())
				settings.remove(id);
		settings.endGroup();
	}
	settings.endGroup();
}

QList<APProfile> AnyPlayInput::ParseProfiles(const QJsonObject &config, const QString &layout, bool apply_overrides)
{
	if(apply_overrides)
		PruneOverrides(layout, config);
	QSettings settings;
	const QString group = OverrideGroupFor(layout);
	QList<APProfile> result;
	for(const auto &p : config.value("profiles").toArray())
	{
		const QJsonObject po = p.toObject();
		APProfile profile;
		profile.id = po.value("id").toString();
		profile.name = po.value("name").toString();
		for(const auto &b : po.value("bindings").toArray())
		{
			const QJsonObject bo = b.toObject();
			APBinding binding;
			binding.id = bo.value("id").toString();
			binding.name = bo.value("name").toString();
			binding.key = bo.value("key").toString();
			const QString kind = bo.value("do").toString("hold");
			binding.kind = kind == "tap" ? APBinding::Kind::Tap
				: kind == "turbo" ? APBinding::Kind::Turbo
				: kind == "macro" ? APBinding::Kind::Macro
				: kind == "cycle" ? APBinding::Kind::Cycle
				: kind == "spin" ? APBinding::Kind::Spin
				: kind == "precise" ? APBinding::Kind::Precise
				: kind == "hold_stick" ? APBinding::Kind::StickHold
				: kind == "hotwire" ? APBinding::Kind::Hotwire
				: kind == "none" ? APBinding::Kind::None
				: APBinding::Kind::Hold;
			binding.out = StepFromJson(bo);
			for(const auto &s : bo.value("steps").toArray())
				binding.steps.append(StepFromJson(s.toObject()));
			binding.dir = bo.value("dir").toInt(1) < 0 ? -1 : 1;
			binding.when = ButtonFromName(bo.value("when").toString());
			const QJsonObject aim = bo.value("aim").toObject();
			binding.aim_when = ButtonFromName(aim.value("when").toString());
			binding.aim_out = StepFromJson(aim);
			const QJsonObject hold = bo.value("hold").toObject();
			if(!hold.isEmpty())
			{
				binding.hold_open = true;
				binding.hold_out = StepFromJson(hold);
				binding.hold_min = qMax(0, hold.value("ms").toInt(300));
			}
			const QJsonObject spin = bo.value("spin").toObject();
			binding.spin_l = qBound(-1, spin.value("l").toInt(0), 1);
			binding.spin_r = qBound(-1, spin.value("r").toInt(0), 1);
			binding.profile = bo.value("profile").toString();
			binding.owner = profile.id;
			if(apply_overrides)
			{
				const QString path = QStringLiteral("%1/%2/%3").arg(group, profile.id, binding.id);
				if(settings.contains(path))
					binding.key = settings.value(path).toString();
			}
			if(binding.key == MenuKeyName())
				binding.key.clear();
			profile.bindings.append(binding);
		}
		result.append(profile);
	}
	return result;
}

void AnyPlayInput::Load()
{
	const QString layout = Layout();
	const QJsonObject config = DefaultConfig(layout);
	const QString previous = current_profile;
	profiles = ParseProfiles(config, layout, true);
	// поточний режим лишається (розкладку можна змінити просто під час гри), якщо він є і в новій розкладці
	bool keep = false;
	for(const auto &p : profiles)
		keep |= !current_profile.isEmpty() && p.id == current_profile;
	if(!keep)
		current_profile = config.value("start").toString("foot");
	auto_vehicle = preview ? false : AutoVehicle();
	hint.clear();
	ReleaseAll();
	// автоматика транспорту: з чистого аркуша (приставка про курки ще нічого не казала), правила своєї гри
	vehicle.Reset(AnyPlayVehicleRulesFor(layout.toStdString()), IsVehicleMode(current_profile), clock.elapsed());
	bool has_vehicle = false;
	for(const auto &p : profiles)
		has_vehicle |= p.id == QLatin1String("vehicle");
	if(auto_vehicle && has_vehicle)
		vehicle_timer.start();
	else
		vehicle_timer.stop();
	if(!previous.isEmpty() && previous != current_profile)
		emit ProfileChanged(StatusText());
}

void AnyPlayInput::NotifyConfigChanged()
{
	const auto list = Instances();
	for(AnyPlayInput *input : list)
	{
		QPointer<AnyPlayInput> guard(input);
		QMetaObject::invokeMethod(input, [guard]() { if(guard) guard->Load(); }, Qt::AutoConnection);
	}
}

QString AnyPlayInput::LiveMode()
{
	for(const AnyPlayInput *input : std::as_const(Instances()))
		if(!input->preview)
			return input->current_profile;
	return QString();
}

QString AnyPlayInput::ProfileName(const QString &id) const
{
	for(const auto &p : profiles)
		if(p.id == id)
			return p.name;
	return id;
}

QString AnyPlayInput::CurrentProfileName() const
{
	return ProfileName(current_profile);
}

const APBinding *AnyPlayInput::Find(const QString &name) const
{
	if(name.isEmpty() || name == MenuKeyName())
		return nullptr;
	const APBinding *global = nullptr;
	for(const auto &p : profiles)
	{
		if(p.id != current_profile && p.id != QLatin1String("global"))
			continue;
		for(const auto &b : p.bindings)
		{
			if(b.key.compare(name, Qt::CaseInsensitive) != 0)
				continue;
			if(p.id == current_profile)
				return &b; // дія поточного режиму важливіша за спільні клавіші
			if(!global)
				global = &b;
		}
	}
	return global;
}

// «лише в прицілі»: дія працює, тільки поки натиснута потрібна кнопка (наприклад L2)
bool AnyPlayInput::Allowed(const APBinding &b) const
{
	return !b.when || (Output().buttons & b.when);
}

// у дії є окремий варіант «у прицілі», і зараз саме приціл (натиснута aim_when)
bool AnyPlayInput::AimNow(const APBinding &b) const
{
	return b.aim_when && (Output().buttons & b.aim_when);
}

bool AnyPlayInput::HandleInput(const QString &name, bool pressed)
{
	if(name.isEmpty() || name == MenuKeyName())
		return false; // ` відкриває меню AnyPlay і в гру не йде
	if(!pressed)
	{
		// точний режим: відпущена клавіша руху більше не крутить стік, але стік лишається, де був
		if(precise_active && precise_keys.remove(name))
		{
			UpdatePrecise();
			emit Changed();
			return true;
		}
		auto it = active.find(name);
		if(it == active.end())
			return Find(name) != nullptr;
		// клавіша зброї: коротке натискання тримає колесо, доки гра не встигне прийняти вибір
		if(it->hold_min > 0 && it->pressed_at > 0)
		{
			const qint64 left = it->hold_min - (clock.elapsed() - it->pressed_at);
			if(left > 0)
			{
				const qint64 at = it->pressed_at;
				QTimer::singleShot(static_cast<int>(left), this, [this, name, at]() {
					auto again = active.find(name);
					if(again == active.end() || again->pressed_at != at)
						return;
					active.erase(again);
					AfterRelease();
					emit Changed();
				});
				return true;
			}
		}
		const bool turbo = it->kind == APBinding::Kind::Turbo;
		const bool spin = it->kind == APBinding::Kind::Spin;
		const APBinding::Kind kind = it->kind;
		const qint64 held_ms = clock.elapsed() - it->pressed_at;
		active.erase(it);
		AfterRelease();
		if(kind == APBinding::Kind::Precise && name == precise_key)
		{
			if(held_ms < PreciseTapMs)
			{
				// коротко натиснули: точний режим лишається, поки не натиснуть ще раз (зручно з CapsLock на Mac)
				hint = QStringLiteral("Точний рух увімкнено: %1 — вимкнути").arg(DisplayName(name));
				emit ProfileChanged(StatusText());
			}
			else
			{
				// відпустили клавішу точного режиму: стік знову слухає клавіші руху як завжди
				precise_active = false;
				precise_keys.clear();
				UpdateSpinTimer();
			}
		}
		if(kind == APBinding::Kind::Hotwire && name == hotwire_key)
		{
			hotwire_active = false;
			UpdateSpinTimer();
		}
		if(spin)
			UpdateSpinTimer();
		if(turbo)
		{
			bool any_turbo = false;
			for(const auto &b : active)
				any_turbo |= b.kind == APBinding::Kind::Turbo;
			if(!any_turbo)
				turbo_timer.stop();
		}
		emit Changed();
		return true;
	}

	if(active.contains(name) || (precise_active && precise_keys.contains(name)))
		return true; // автоповтор клавіші
	const APBinding *binding = Find(name);
	if(!binding)
		return false;
	APBinding b = *binding; // копія: перемикання режиму нижче робить вказівник недійсним
	NoteGameEvent(b);
	// злам машини: стрілки дрібно докручують стіки (вліво — проти годинникової)
	if(hotwire_active && (b.id == QLatin1String("nav_left") || b.id == QLatin1String("nav_right")))
	{
		mouse_point.Rotate(b.id == QLatin1String("nav_left") ? -AnyPlayHotwireStepDeg : AnyPlayHotwireStepDeg);
		emit Changed();
		return true;
	}
	// точний режим: клавіші руху крутять стік (кут) і міняють силу, а не штовхають його в 8 напрямків
	int role = 0;
	if(precise_active && PreciseRole(b, &role))
	{
		precise_keys.insert(name, role);
		UpdatePrecise();
		emit Changed();
		return true;
	}
	if(!Allowed(b))
		return true; // клавіша наша, але без прицілу нічого не робить
	if(!(Output().buttons & CHIAKI_CONTROLLER_BUTTON_L1))
		wheel_sector = -1;   // колесо відкривається заново: вибір коліщатком починаємо спочатку
	if(b.hold_open && !AimNow(b))
	{
		// клавіша зброї: колесо відкрите на її секторі, поки тримаєш; відпустив — гра бере цю зброю
		NoteSlot(b);
		macro.clear();
		macro_index = -1;
		macro_timer.stop();
		b.kind = APBinding::Kind::Hold;
		b.out = b.hold_out;
		b.pressed_at = clock.elapsed();
		active.insert(name, b);
		emit Changed();
		return true;
	}
	if(AimNow(b))
	{
		// у прицілі інша дія (наприклад △), тримається, поки тримаєш клавішу
		b.kind = APBinding::Kind::Hold;
		b.out = b.aim_out;
		b.profile.clear();
	}
	// постріл або удар з клавіатури: віддача на екрані (приставка вібрацію на мишку не шле)
	if(b.kind == APBinding::Kind::Hold && (b.out.buttons & (CHIAKI_CONTROLLER_ANALOG_BUTTON_R2 | CHIAKI_CONTROLLER_BUTTON_BOX))
		&& !preview && !gamepad_mode && Option(QStringLiteral("kick_screen")).toBool())
		emit Kick((b.out.buttons & CHIAKI_CONTROLLER_ANALOG_BUTTON_R2) ? 0.55f : 0.3f);
	switch(b.kind)
	{
		case APBinding::Kind::Hold:
			active.insert(name, b);
			break;
		case APBinding::Kind::Spin:
			b.pressed_at = clock.elapsed();
			active.insert(name, b);
			UpdateSpinTimer();
			break;
		case APBinding::Kind::Precise:
		{
			if(precise_active)
			{
				// режим було увімкнено коротким натисканням: ще одне вимикає
				precise_active = false;
				precise_keys.clear();
				hint.clear();
				emit ProfileChanged(StatusText());
				UpdateSpinTimer();
				break;
			}
			// точний режим: починаємо з того, куди стік дивиться зараз; натиснуті клавіші руху стають «кермом»
			const APStep now = Output();
			precise.Start(now.lx, now.ly);
			precise_active = true;
			precise_key = name;
			precise_tick = clock.elapsed();
			precise_keys.clear();
			for(auto it = active.begin(); it != active.end();)
			{
				int r = 0;
				if(PreciseRole(*it, &r))
				{
					precise_keys.insert(it.key(), r);
					it = active.erase(it);
				}
				else
					++it;
			}
			UpdatePrecise();
			b.pressed_at = precise_tick;
			active.insert(name, b);
			UpdateSpinTimer();
			break;
		}
		case APBinding::Kind::StickHold:
			// перемикач: стік тримає напрям, який задає миша, і не повертається в центр
			stick_hold = !stick_hold;
			mouse_point.Reset();
			hint = stick_hold ? QStringLiteral("Правий стік утримується: мишею задай напрям, %1 — відпустити").arg(DisplayName(name)) : QString();
			emit ProfileChanged(StatusText());
			UpdateSpinTimer();
			break;
		case APBinding::Kind::Hotwire:
			// злам машини: обидва стіки назустріч, далі крутяться за мишею, коліщатком чи стрілками
			hotwire_active = true;
			hotwire_key = name;
			AnyPlayHotwireStart(&mouse_point, AnyPlayHotwireRadiusPx);
			active.insert(name, b);
			UpdateSpinTimer();
			break;
		case APBinding::Kind::Turbo:
			active.insert(name, b);
			turbo_phase = true;
			if(!turbo_timer.isActive())
				turbo_timer.start();
			break;
		case APBinding::Kind::Tap:
			AddTap(b.out, TapMs);
			break;
		case APBinding::Kind::Macro:
			NoteSlot(b);
			StartMacro(b.steps);
			break;
		case APBinding::Kind::Cycle:
			Cycle(b);
			break;
		case APBinding::Kind::None:
			break;
	}
	if(!b.profile.isEmpty())
		SwitchProfile(b.profile);
	emit Changed();
	return true;
}

bool AnyPlayInput::Tap(const QString &name)
{
	// злам машини: поділка коліщатка дрібно докручує обидва стіки
	if(hotwire_active && (name == QLatin1String("WheelUp") || name == QLatin1String("WheelDown")))
	{
		mouse_point.Rotate(name == QLatin1String("WheelUp") ? AnyPlayHotwireStepDeg : -AnyPlayHotwireStepDeg);
		emit Changed();
		return true;
	}
	const APBinding *binding = Find(name);
	if(!binding)
		return false;
	const APBinding b = *binding;
	if(!Allowed(b))
		return true;
	if(b.kind == APBinding::Kind::Cycle && WheelStep(b))
	{
		emit Changed();
		return true;
	}
	if(AimNow(b))
	{
		AddTap(b.aim_out, TapMs);   // у прицілі: коротко інша кнопка (колесо в GTA VI: △)
		emit Changed();
		return true;
	}
	if(b.kind == APBinding::Kind::Macro)
	{
		NoteSlot(b);
		StartMacro(b.steps);
	}
	else if(b.kind == APBinding::Kind::Cycle)
		Cycle(b);
	else if(b.kind == APBinding::Kind::Precise || b.kind == APBinding::Kind::StickHold)
	{
		// коротке натискання (CapsLock на Mac приходить саме так): перемикач
		HandleInput(name, true);
		HandleInput(name, false);
		return true;
	}
	else if(b.kind != APBinding::Kind::None && b.kind != APBinding::Kind::Spin && b.kind != APBinding::Kind::Hotwire)
		AddTap(b.out, TapMs);
	if(!b.profile.isEmpty())
		SwitchProfile(b.profile);
	emit Changed();
	return true;
}

// комбінації slot1…slot9 того самого режиму: колесо зброї GTA V
QList<const APBinding *> AnyPlayInput::Slots(const QString &owner) const
{
	static const QRegularExpression slot_id(QStringLiteral("^slot\\d"));
	QList<const APBinding *> result;
	for(const auto &p : profiles)
	{
		if(p.id != owner)
			continue;
		for(const auto &b : p.bindings)
			if(b.kind == APBinding::Kind::Macro && slot_id.match(b.id).hasMatch())
				result.append(&b);
	}
	return result;
}

// коліщатко: наступна або попередня зброя по колу, тією самою комбінацією, що й клавіші 1–9
void AnyPlayInput::Cycle(const APBinding &b)
{
	const QList<const APBinding *> list = Slots(b.owner);
	if(list.isEmpty())
		return;
	const int n = list.size();
	slot = ((slot + b.dir) % n + n) % n;
	StartMacro(list[slot]->steps);
}

// Колесо зброї вже відкрите (тримають Tab чи клавішу зброї): коліщатко миші не відкриває його заново,
// а переводить правий стік на сусідній сектор, по колу за годинниковою стрілкою (вгору — наступний).
bool AnyPlayInput::WheelStep(const APBinding &b)
{
	if(!(Output().buttons & CHIAKI_CONTROLLER_BUTTON_L1) || macro_index >= 0)
		return false;
	QList<QPointF> dirs;
	for(const APBinding *s : Slots(b.owner))
	{
		const APStep st = s->hold_open ? s->hold_out : (s->steps.size() > 1 ? s->steps[1] : APStep());
		const QPointF d(st.rx, st.ry);
		if(qAbs(d.x()) + qAbs(d.y()) < 0.1)
			continue;
		bool dup = false;
		for(const QPointF &e : dirs)
			dup |= qAbs(e.x() - d.x()) + qAbs(e.y() - d.y()) < 0.05;
		if(!dup)
			dirs.append(d);
	}
	if(dirs.size() < 2)
		return false;
	// за годинниковою стрілкою від верху
	constexpr double Pi = 3.14159265358979323846;   // M_PI і std::min на Windows ненадійні (макроси min/max)
	auto angle = [](const QPointF &d) { double a = std::atan2(d.x(), -d.y()); return a < 0 ? a + 2 * Pi : a; };
	std::sort(dirs.begin(), dirs.end(), [&](const QPointF &x, const QPointF &y) { return angle(x) < angle(y); });
	int idx = wheel_sector;
	if(idx < 0 || idx >= dirs.size())
	{
		// з того сектора, куди зараз дивиться стік (клавіша зброї чи W A S D), інакше з останньої зброї
		const APStep now = Output();
		idx = -1;
		if(qAbs(now.rx) + qAbs(now.ry) > 0.3)
		{
			const double a = angle(QPointF(now.rx, now.ry));
			double best = 10;
			for(int i = 0; i < dirs.size(); i++)
			{
				double diff = std::fabs(angle(dirs[i]) - a);
				diff = qMin(diff, 2 * Pi - diff);
				if(diff < best) { best = diff; idx = i; }
			}
		}
		if(idx < 0)
		{
			const auto list = Slots(b.owner);
			const APBinding *cur = slot >= 0 && slot < list.size() ? list[slot] : nullptr;
			const APStep st = cur ? (cur->hold_open ? cur->hold_out : (cur->steps.size() > 1 ? cur->steps[1] : APStep())) : APStep();
			idx = 0;
			for(int i = 0; i < dirs.size(); i++)
				if(qAbs(dirs[i].x() - st.rx) + qAbs(dirs[i].y() - st.ry) < 0.05)
					idx = i;
			idx -= b.dir;   // перший крок коліщатка лишає на поточній зброї видимою і йде на сусідню
		}
	}
	const int n = dirs.size();
	wheel_sector = ((idx + b.dir) % n + n) % n;
	wheel_rx = float(dirs[wheel_sector].x());
	wheel_ry = float(dirs[wheel_sector].y());
	return true;
}

void AnyPlayInput::AfterRelease()
{
	if(!(Output().buttons & CHIAKI_CONTROLLER_BUTTON_L1))
		wheel_sector = -1;
}

void AnyPlayInput::NoteSlot(const APBinding &b)
{
	const QList<const APBinding *> list = Slots(b.owner);
	for(int i = 0; i < list.size(); i++)
		if(list[i]->id == b.id)
			slot = i;
}

void AnyPlayInput::ReleaseAll()
{
	wheel_sector = -1;
	precise_active = false;
	precise_keys.clear();
	hotwire_active = false;
	if(stick_hold)
	{
		stick_hold = false;
		hint.clear();
		emit ProfileChanged(StatusText());
	}
	tremor_until = 0;
	active.clear();
	taps.clear();
	macro.clear();
	macro_index = -1;
	macro_timer.stop();
	turbo_timer.stop();
	spin_timer.stop();
	emit Changed();
}

void AnyPlayInput::UpdateSpinTimer()
{
	bool any = precise_active || hotwire_active || stick_hold || tremor_until > 0;
	for(const auto &b : active)
		any |= b.kind == APBinding::Kind::Spin;
	if(any && !spin_timer.isActive())
		spin_timer.start();
	else if(!any)
		spin_timer.stop();
}

void AnyPlayInput::AddTap(const APStep &step, int ms)
{
	const int id = next_tap_id++;
	taps.append({id, step});
	QTimer::singleShot(ms, this, [this, id]() {
		for(int i = 0; i < taps.size(); i++)
		{
			if(taps[i].id == id)
			{
				taps.removeAt(i);
				emit Changed();
				return;
			}
		}
	});
}

void AnyPlayInput::StartMacro(const QList<APStep> &steps)
{
	macro = steps;
	macro_index = -1;
	NextMacroStep();
}

void AnyPlayInput::NextMacroStep()
{
	macro_index++;
	if(macro_index >= macro.size())
	{
		macro.clear();
		macro_index = -1;
	}
	else
		macro_timer.start(qMax(1, macro[macro_index].ms));
	emit Changed();
}

// Клавіша ручного перемикання «пішки ↔ транспорт» (дія з "profile": "toggle"; 115: U, а не F)
QString AnyPlayInput::ToggleKeyName() const
{
	for(const auto &p : profiles)
		for(const auto &b : p.bindings)
			if(b.profile == QLatin1String("toggle") && !b.key.isEmpty())
				return DisplayName(b.key);
	return QString();
}

// Підказка після перемикання: «🚗 Транспорт. U — назад «🚶 Пішки»» (AnyPlayHud робить з неї «U — пішки»)
QString AnyPlayInput::ModeHint(const QString &id) const
{
	const QString key = ToggleKeyName();
	if(key.isEmpty() || (id != QLatin1String("foot") && id != QLatin1String("vehicle")))
		return QString();
	const QString other = id == QLatin1String("foot") ? QStringLiteral("vehicle") : QStringLiteral("foot");
	return QStringLiteral("%1. %2 — назад «%3»").arg(ProfileName(id), key, ProfileName(other));
}

void AnyPlayInput::SwitchProfile(const QString &target)
{
	if(target == QLatin1String("toggle"))
	{
		// ручний перемикач (U): пішки → транспорт, транспорт чи авіація → пішки
		const QString id = current_profile == QLatin1String("foot") ? QStringLiteral("vehicle") : QStringLiteral("foot");
		SetProfile(id, ModeHint(id));
		return;
	}
	SetProfile(target, QString());
}

void AnyPlayInput::SetProfile(const QString &id, const QString &hint_text)
{
	if(id == current_profile && hint_text.isEmpty() && hint.isEmpty())
		return;
	const QString was = current_profile;
	current_profile = id;
	hint = hint_text;
	// гравець перемкнув сам (U, F1–F3, вкладка): автоматика приймає це і кілька секунд не сперечається
	if(auto_vehicle && !preview)
	{
		vehicle.Manual(IsVehicleMode(id), clock.elapsed());
		vehicle.TakeLog();
		if(id != was)
			emit VehicleLog(QStringLiteral("вручну %1 → %2 (%3)").arg(was, id, QString::fromStdString(vehicle.TrigText())));
	}
	emit ProfileChanged(StatusText());
}

void AnyPlayInput::SetCurrentProfile(const QString &id)
{
	bool known = false;
	for(const auto &p : profiles)
		known |= p.id == id;
	if(!known || (id == current_profile && hint.isEmpty()))
		return;
	ReleaseAll();
	SetProfile(id, QString());
}

void AnyPlayInput::SetPreview(bool enabled)
{
	preview = enabled;
	auto_vehicle = preview ? false : AutoVehicle();
}

void AnyPlayInput::NoteRumble(uint8_t left, uint8_t right)
{
	rumble_left = left;
	rumble_right = right;
	const qint64 now = clock.elapsed();
	vehicle.Rumble(left, right, now);
	// тремор камери: від помітної вібрації правий стік кілька кадрів смикається (гра хитає камеру)
	const int strength = qMax(left, right);
	if(strength >= TremorMinRumble && !preview && !gamepad_mode && now - tremor_last >= TremorMinGapMs && Option(QStringLiteral("tremor")).toBool())
	{
		tremor_last = now;
		tremor_until = now + TremorMs;
		tremor_amp = 0.10f + 0.22f * (strength - TremorMinRumble) / float(255 - TremorMinRumble);
		UpdateSpinTimer();
		emit Changed();
	}
}

void AnyPlayInput::NoteTriggers(uint8_t type_left, uint8_t type_right, bool empty_left, bool empty_right)
{
	trig_left = type_left;
	trig_right = type_right;
	vehicle.Triggers(AnyPlayTriggerClass(type_left, empty_left), AnyPlayTriggerClass(type_right, empty_right),
		type_left, type_right, clock.elapsed());
}

// Натиснули клавішу гри: △ — «можливо, сідає чи виходить» (чекаємо підтвердження курками), пауза/мапа — меню гри
void AnyPlayInput::NoteGameEvent(const APBinding &b)
{
	if(!auto_vehicle || preview || !vehicle_timer.isActive())
		return;
	const qint64 now = clock.elapsed();
	const bool global = b.owner == QLatin1String("global");
	if(global && b.id == QLatin1String("pause"))
		vehicle.SetMenu(!vehicle.menu, now);
	else if(global && (b.id == QLatin1String("map") || b.id == QLatin1String("ps")))
		vehicle.SetMenu(true, now);
	else if(!global && b.kind != APBinding::Kind::None)
		vehicle.SetMenu(false, now);   // клавіша дії в грі: меню вже закрите
	const bool warned = vehicle.warned_no_effects;
	if(!global && b.kind == APBinding::Kind::Hold && (b.out.buttons & CHIAKI_CONTROLLER_BUTTON_PYRAMID))
		vehicle.Interact(now);
	FlushVehicleLog();
	if(vehicle.warned_no_effects && !warned)
	{
		// адаптивні курки в грі вимкнені (або гра їх не має): автоматика сліпа, підказуємо ручну клавішу
		const QString key = ToggleKeyName();
		hint = key.isEmpty() ? QStringLiteral("Режим сам не перемкнеться: увімкни адаптивні курки в налаштуваннях гри")
			: QStringLiteral("Режим сам не перемкнеться: %1 — пішки або транспорт").arg(key);
		emit ProfileChanged(StatusText());
	}
}

void AnyPlayInput::FlushVehicleLog()
{
	const std::string line = vehicle.TakeLog();
	if(!line.empty())
		emit VehicleLog(QString::fromStdString(line));
}

// Кілька разів на секунду: чи час перемкнути режим за курками
void AnyPlayInput::TickVehicle()
{
	if(!auto_vehicle || preview)
		return;
	const qint64 now = clock.elapsed();
	// пішки тримають приціл чи постріл: ефекти на курках зараз від зброї, «сів» не рахуємо
	const bool aiming = current_profile == QLatin1String("foot")
		&& (Output().buttons & (CHIAKI_CONTROLLER_ANALOG_BUTTON_L2 | CHIAKI_CONTROLLER_ANALOG_BUTTON_R2));
	vehicle.SetAiming(aiming, now);
	// в «Авіації» автоматика лише виходить (пішки), а не вмикає «Транспорт»: детектор вважає авіацію транспортом
	const int verdict = vehicle.Tick(now);
	const QString why = QString::fromStdString(vehicle.TakeLog());
	if(verdict > 0)
		ApplyAuto(true, why);
	else if(verdict < 0)
		ApplyAuto(false, why);
	else if(!why.isEmpty())
		emit VehicleLog(why);
}

void AnyPlayInput::ApplyAuto(bool to_vehicle, const QString &why)
{
	const QString id = to_vehicle ? QStringLiteral("vehicle") : QStringLiteral("foot");
	if(id == current_profile)
	{
		if(!why.isEmpty())
			emit VehicleLog(why);
		return;
	}
	emit VehicleLog(QStringLiteral("авто %1 → %2: %3").arg(current_profile, id, why));
	ReleaseAll();
	current_profile = id;
	hint = ModeHint(id);
	emit ProfileChanged(StatusText());
	emit Changed();
}

// Роль клавіші руху в точному режимі: 1 вліво, 2 вправо, 3 вперед (сила більше), 4 назад (сила менше)
bool AnyPlayInput::PreciseRole(const APBinding &b, int *role) const
{
	if(b.kind != APBinding::Kind::Hold || b.out.buttons)
		return false;
	if(b.out.lx < -0.5f) { *role = 1; return true; }
	if(b.out.lx > 0.5f) { *role = 2; return true; }
	if(b.out.ly < -0.5f) { *role = 3; return true; }
	if(b.out.ly > 0.5f) { *role = 4; return true; }
	if(b.id == QLatin1String("nav_left")) { *role = 1; return true; }
	if(b.id == QLatin1String("nav_right")) { *role = 2; return true; }
	if(b.id == QLatin1String("nav_up")) { *role = 3; return true; }
	if(b.id == QLatin1String("nav_down")) { *role = 4; return true; }
	return false;
}

void AnyPlayInput::UpdatePrecise()
{
	int turn = 0, push = 0;
	for(int role : std::as_const(precise_keys))
	{
		if(role == 1) turn -= 1;
		if(role == 2) turn += 1;
		if(role == 3) push += 1;
		if(role == 4) push -= 1;
	}
	precise.turn = qBound(-1, turn, 1);
	precise.push = qBound(-1, push, 1);
	precise_tick = clock.elapsed();
}

void AnyPlayInput::MouseDelta(double dx, double dy)
{
	if(hotwire_active)
	{
		mouse_point.Move(dx, dy, AnyPlayHotwireRadiusPx);
		return;
	}
	if(stick_hold)
	{
		const double radius = AnyPlayHoldRadiusPx / qMax(0.3f, MouseSensitivity(current_profile));
		mouse_point.Move(dx, dy, radius);
	}
}

float AnyPlayInput::MouseScale() const
{
	if(current_profile != QLatin1String("foot") || !Option(QStringLiteral("aim_slow")).toBool())
		return 1.0f;
	return (Output().buttons & CHIAKI_CONTROLLER_ANALOG_BUTTON_L2) ? AimSlowFactor : 1.0f;
}

QVariant AnyPlayInput::Option(const QString &name)
{
	QMutexLocker lock(&option_mutex);
	auto it = option_cache.find(name);
	if(it != option_cache.end())
		return *it;
	QVariant value;
	for(const auto &d : OptionDefaults())
		if(d.first == name)
			value = QSettings().value(OptionKey(name), d.second);
	option_cache.insert(name, value);
	return value;
}

void AnyPlayInput::SetOption(const QString &name, const QVariant &value)
{
	bool known = false;
	for(const auto &d : OptionDefaults())
		known |= d.first == name;
	if(!known)
		return;
	{
		QMutexLocker lock(&option_mutex);
		option_cache.insert(name, value);
	}
	QSettings().setValue(OptionKey(name), value);
	if(name == QLatin1String("auto_vehicle"))
		NotifyConfigChanged();   // рушій у грі вмикає або вимикає автоматику одразу
}

QVariantMap AnyPlayInput::Options()
{
	QVariantMap map;
	for(const auto &d : OptionDefaults())
		map.insert(d.first, Option(d.first));
	return map;
}

bool AnyPlayInput::AutoVehicle()
{
	return Option(QStringLiteral("auto_vehicle")).toBool();
}

void AnyPlayInput::SetAutoVehicle(bool enabled)
{
	SetOption(QStringLiteral("auto_vehicle"), enabled);
}

float AnyPlayInput::MouseSensitivity(const QString &mode)
{
	if(IsVehicleMode(mode))
	{
		float w = cached_vehicle_sensitivity.load(std::memory_order_relaxed);
		if(w < 0)
		{
			const QVariant saved = QSettings().value(VehicleSensitivityKey);
			w = saved.isValid() ? qBound(MinSensitivity, saved.toFloat(), MaxSensitivity) : 0.0f;
			cached_vehicle_sensitivity.store(w, std::memory_order_relaxed);
		}
		if(w > 0)
			return w;
	}
	float v = cached_sensitivity.load(std::memory_order_relaxed);
	if(v < 0)
	{
		v = qBound(MinSensitivity, QSettings().value(SensitivityKey, 1.0).toFloat(), MaxSensitivity);
		cached_sensitivity.store(v, std::memory_order_relaxed);
	}
	return v;
}

void AnyPlayInput::SetMouseSensitivity(float value, const QString &mode)
{
	value = qBound(MinSensitivity, value, MaxSensitivity);
	if(IsVehicleMode(mode))
	{
		cached_vehicle_sensitivity.store(value, std::memory_order_relaxed);
		QSettings().setValue(VehicleSensitivityKey, static_cast<double>(value));
		return;
	}
	cached_sensitivity.store(value, std::memory_order_relaxed);
	QSettings().setValue(SensitivityKey, static_cast<double>(value));
}

bool AnyPlayInput::InvertY()
{
	int v = cached_invert.load(std::memory_order_relaxed);
	if(v < 0)
	{
		v = QSettings().value(InvertYKey, false).toBool() ? 1 : 0;
		cached_invert.store(v, std::memory_order_relaxed);
	}
	return v == 1;
}

void AnyPlayInput::SetInvertY(bool invert)
{
	cached_invert.store(invert ? 1 : 0, std::memory_order_relaxed);
	QSettings().setValue(InvertYKey, invert);
}

bool AnyPlayInput::AskGame()
{
	return QSettings().value(AskGameKey, true).toBool();
}

void AnyPlayInput::SetAskGame(bool ask)
{
	QSettings().setValue(AskGameKey, ask);
}

bool AnyPlayInput::PadPreview()
{
	return pad_preview.load(std::memory_order_relaxed);
}

void AnyPlayInput::SetPadPreview(bool on)
{
	pad_preview.store(on, std::memory_order_relaxed);
}

APStep AnyPlayInput::Output() const
{
	APStep sum;
	for(const auto &b : active)
	{
		if(b.kind == APBinding::Kind::Turbo && !turbo_phase)
			continue;
		AddStep(&sum, b.out);
	}
	for(const auto &t : taps)
		AddStep(&sum, t.step);
	if(macro_index >= 0 && macro_index < macro.size())
		AddStep(&sum, macro[macro_index]);
	// колесо зброї відкрите і сектор обрали коліщатком: правий стік дивиться саме туди
	if(wheel_sector >= 0 && (sum.buttons & CHIAKI_CONTROLLER_BUTTON_L1))
	{
		sum.rx = wheel_rx;
		sum.ry = wheel_ry;
	}
	// злам машини: поки тримаєш клавішу, стік крутиться по колу повного відхилення (замість руху клавішами)
	const qint64 now = clock.elapsed();
	for(const auto &b : active)
	{
		if(b.kind != APBinding::Kind::Spin)
			continue;
		if(b.spin_l)
			AnyPlaySpinStick(now - b.pressed_at, b.spin_l, &sum.lx, &sum.ly);
		if(b.spin_r)
			AnyPlaySpinStick(now - b.pressed_at, b.spin_r, &sum.rx, &sum.ry);
	}
	// точний режим: лівий стік — кут і сила, які крутять клавіші руху
	if(precise_active)
		precise.Stick(&sum.lx, &sum.ly);
	// «утримати» правий стік: напрям від миші, стік не повертається в центр
	if(stick_hold && !hotwire_active)
	{
		const double radius = AnyPlayHoldRadiusPx / qMax(0.3f, MouseSensitivity(current_profile));
		AnyPlayHoldStick(mouse_point, radius, InvertY(), &sum.rx, &sum.ry);
	}
	// злам машини: обидва стіки назустріч і крутяться за мишею
	if(hotwire_active)
		AnyPlayHotwireSticks(mouse_point, &sum.lx, &sum.ly, &sum.rx, &sum.ry);
	// тремор камери від вібрації: кілька кадрів правий стік смикається туди-сюди
	if(tremor_until && now < tremor_until)
	{
		sum.rx += tremor_phase ? tremor_amp : -tremor_amp;
		sum.ry += tremor_phase ? -tremor_amp * 0.5f : tremor_amp * 0.5f;
	}
	return sum;
}

void AnyPlayInput::ApplyTo(ChiakiControllerState *state) const
{
	const APStep sum = Output();
	state->buttons = sum.buttons & ~(CHIAKI_CONTROLLER_ANALOG_BUTTON_L2 | CHIAKI_CONTROLLER_ANALOG_BUTTON_R2);
	state->l2_state = (sum.buttons & CHIAKI_CONTROLLER_ANALOG_BUTTON_L2) ? 0xff : 0;
	state->r2_state = (sum.buttons & CHIAKI_CONTROLLER_ANALOG_BUTTON_R2) ? 0xff : 0;
	state->left_x = Axis(sum.lx);
	state->left_y = Axis(sum.ly);
	state->right_x = Axis(sum.rx);
	state->right_y = Axis(sum.ry);
}

QVariantMap AnyPlayInput::PreviewState() const
{
	const APStep sum = Output();
	QStringList buttons;
	for(const auto &b : ButtonList())
		if(sum.buttons & b.second)
			buttons.append(b.first);
	QVariantMap state;
	state["buttons"] = buttons;
	state["lx"] = qBound(-1.0f, sum.lx, 1.0f);
	state["ly"] = qBound(-1.0f, sum.ly, 1.0f);
	state["rx"] = qBound(-1.0f, sum.rx, 1.0f);
	state["ry"] = qBound(-1.0f, sum.ry, 1.0f);
	state["profile"] = current_profile;
	return state;
}

QVariantMap AnyPlayInput::PadState(const ChiakiControllerState &state)
{
	QStringList buttons;
	for(const auto &b : ButtonList())
	{
		const bool on = b.second == CHIAKI_CONTROLLER_ANALOG_BUTTON_L2 ? state.l2_state > 0x33
			: b.second == CHIAKI_CONTROLLER_ANALOG_BUTTON_R2 ? state.r2_state > 0x33
			: (state.buttons & b.second) != 0;
		if(on)
			buttons.append(b.first);
	}
	// мертва зона 0.14, як у прототипі; далі округлення до сотих
	auto axis = [](int16_t v) {
		const double x = qBound(-1.0, v / 32767.0, 1.0);
		return qAbs(x) < 0.14 ? 0.0 : qRound(x * 100) / 100.0;
	};
	QVariantMap m;
	m["buttons"] = buttons;
	m["lx"] = axis(state.left_x);
	m["ly"] = axis(state.left_y);
	m["rx"] = axis(state.right_x);
	m["ry"] = axis(state.right_y);
	return m;
}

bool AnyPlayInput::IsMenuKey(const QKeyEvent *event)
{
	if(!event)
		return false;
	const quint32 scan = event->nativeScanCode();
#if defined(Q_OS_WIN)
	// фізичне місце (скан-код 0x29); VK_OEM_3 — лише коли скан-коду нема (на німецькій розкладці VK_OEM_3 — це Ö)
	if(scan == 0x29 || (scan == 0 && event->nativeVirtualKey() == 0xC0))
		return true;
#elif defined(Q_OS_MACOS)
	// kVK_ANSI_Grave і kVK_ISO_Section (§ під Esc на європейських MacBook)
	const quint32 vk = event->nativeVirtualKey();
	if(vk == 0x32 || vk == 0x0A)
		return true;
#else
	if(scan == 49)
		return true;
#endif
	Q_UNUSED(scan);
	// і за символом: ` ~ § ± (якщо клавіша в іншому місці, вона однаково відкриває меню)
	return IsMenuKeyCode(event->key(), 0);
}

QString AnyPlayInput::KeyName(const QKeyEvent *event)
{
	if(IsMenuKey(event))
		return MenuKeyName();
	const bool keypad = event->modifiers().testFlag(Qt::KeypadModifier);
	// літери й цифри за фізичним місцем, щоб працювала будь-яка мова клавіатури
	if(!keypad)
	{
		const Qt::Key physical = Settings::PhysicalKey(event);
		if((physical >= Qt::Key_A && physical <= Qt::Key_Z) || (physical >= Qt::Key_0 && physical <= Qt::Key_9))
			return QString(QChar(static_cast<char16_t>(physical)));
	}
	const QString name = NameForQtKey(event->key(), keypad);
	if(!name.isEmpty())
		return name;
	if(!event->text().isEmpty())
		return LatinForCyrillic(event->text().at(0));
	return QString();
}

void AnyPlayInput::InstallKeyWatcher()
{
	if(key_watcher || !QCoreApplication::instance())
		return;
	key_watcher = new KeyWatcher(QCoreApplication::instance());
	QCoreApplication::instance()->installEventFilter(key_watcher);
}

QString AnyPlayInput::KeyNameFromQml(int key, int modifiers, const QString &text, int scan_code)
{
	// та сама клавіша щойно пройшла через програму: її фізичне місце вже відоме
	if(key_watcher && key_watcher->key == key && !key_watcher->name.isEmpty())
		return key_watcher->name;
	if(IsMenuKeyCode(key, static_cast<quint32>(scan_code)))
		return MenuKeyName();
	const bool keypad = modifiers & Qt::KeypadModifier;
	const QString name = NameForQtKey(key, keypad);
	if(!name.isEmpty())
		return name;
	if(!text.isEmpty())
		return LatinForCyrillic(text.at(0));
	return QString();
}

QString AnyPlayInput::MouseButtonName(Qt::MouseButton button)
{
	switch(button)
	{
		case Qt::LeftButton: return "MouseLeft";
		case Qt::RightButton: return "MouseRight";
		case Qt::MiddleButton: return "MouseMiddle";
		case Qt::BackButton: return "Mouse4";
		case Qt::ForwardButton: return "Mouse5";
		default: return QString();
	}
}

QString AnyPlayInput::DisplayName(const QString &key)
{
	static const QHash<QString, QString> names = {
		{"MouseLeft", "ЛКМ"}, {"MouseRight", "ПКМ"}, {"MouseMiddle", "СКМ"},
		{"Mouse4", "Миша 4"}, {"Mouse5", "Миша 5"},
		{"WheelUp", "Колесо↑"}, {"WheelDown", "Колесо↓"},
		{"Space", "Пробіл"},
		{"Up", "↑"}, {"Down", "↓"}, {"Left", "←"}, {"Right", "→"},
	};
	if(key.isEmpty())
		return QStringLiteral("—");
	if(names.contains(key))
		return names.value(key);
	if(key.startsWith("Num") && key.size() == 4)
		return QStringLiteral("Num %1").arg(key.at(3));
	return key;
}

QVariantList AnyPlayInput::ProfilesForEditor()
{
	const QString layout = Layout();
	const QJsonObject config = DefaultConfig(layout);
	const QList<APProfile> defaults = ParseProfiles(config, layout, false);
	const QList<APProfile> current = ParseProfiles(config, layout, true);
	const QJsonArray json = config.value("profiles").toArray();
	QVariantList result;
	for(int p = 0; p < current.size(); p++)
	{
		const QJsonObject po = json.at(p).toObject();
		const QJsonArray jb = po.value("bindings").toArray();
		QVariantList bindings;
		for(int i = 0; i < current[p].bindings.size(); i++)
		{
			const APBinding &b = current[p].bindings[i];
			const QJsonObject bo = jb.at(i).toObject();
			QVariantMap row;
			row["id"] = b.id;
			row["name"] = b.name;
			row["key"] = b.key;
			row["keyName"] = DisplayName(b.key);
			row["changed"] = b.key != defaults[p].bindings[i].key;
			// для малюнка геймпада: які кнопки натискає, стік, вид дії
			row["btn"] = bo.value("btn").toVariant();
			row["l"] = bo.value("l").toVariant();
			row["do"] = bo.value("do").toString();
			row["dir"] = b.dir;
			row["when"] = bo.value("when").toString();
			row["aim"] = bo.value("aim").toObject().toVariantMap();   // {when, btn}: що робить у прицілі
			row["x"] = bo.value("x").toInt(0) != 0;
			row["hold"] = !bo.value("hold").toObject().isEmpty();   // клавіша зброї: натисни або тримай
			row["spin"] = bo.value("spin").toObject().toVariantMap();   // злам машини: який стік і куди крутиться
			row["profile"] = b.profile;
			row["steps"] = b.steps.size();
			bindings.append(row);
		}
		QVariantMap profile;
		profile["id"] = current[p].id;
		profile["name"] = current[p].name;
		profile["labels"] = po.value("labels").toObject().toVariantMap();
		profile["bindings"] = bindings;
		result.append(profile);
	}
	return result;
}

QVariantMap AnyPlayInput::EditorData()
{
	QVariantMap data;
	data["layout"] = Layout();
	data["start"] = DefaultConfig(Layout()).value("start").toString("foot");
	data["profiles"] = ProfilesForEditor();
	return data;
}

void AnyPlayInput::SetKeyOverride(const QString &profile, const QString &id, const QString &key)
{
	QSettings settings;
	settings.setValue(QStringLiteral("%1/%2/%3").arg(OverrideGroupFor(Layout()), profile, id), key);
}

void AnyPlayInput::ResetKeyOverrides()
{
	QSettings settings;
	settings.remove(OverrideGroupFor(Layout()));
	NotifyConfigChanged();
}

QVariantMap AnyPlayInput::Rebind(const QString &profile, const QString &id, const QString &key)
{
	QVariantMap result;
	result["ok"] = false;
	result["reason"] = QString();
	result["cleared"] = QVariantList();
	if(key == MenuKeyName())
	{
		result["reason"] = QStringLiteral("menu");
		return result;
	}
	const QString layout = Layout();
	const QList<APProfile> current = ParseProfiles(DefaultConfig(layout), layout, true);
	const APBinding *target = nullptr;
	for(const auto &p : current)
		for(const auto &b : p.bindings)
			if(p.id == profile && b.id == id)
				target = &b;
	if(!target)
	{
		result["reason"] = QStringLiteral("missing");
		return result;
	}
	result["ok"] = true;
	if(target->key == key)
	{
		result["reason"] = QStringLiteral("same");
		return result;
	}
	// Одна клавіша — одна дія в режимі: в іншої дії цього режиму (і спільних клавіш) вона знімається.
	// Спільні клавіші («Меню») діють у всіх режимах, тож для них перевіряються всі режими.
	QVariantList cleared;
	if(!key.isEmpty())
	{
		for(const auto &p : current)
		{
			const bool clashes = p.id == profile || p.id == QLatin1String("global") || profile == QLatin1String("global");
			if(!clashes)
				continue;
			for(const auto &b : p.bindings)
			{
				if(b.key.compare(key, Qt::CaseInsensitive) != 0 || (p.id == profile && b.id == id))
					continue;
				SetKeyOverride(p.id, b.id, QString());
				QVariantMap row;
				row["profile"] = p.id;
				row["id"] = b.id;
				row["name"] = b.name;
				cleared.append(row);
			}
		}
	}
	SetKeyOverride(profile, id, key);
	result["cleared"] = cleared;
	NotifyConfigChanged();
	return result;
}

QVariantMap AnyPlayInput::PadData()
{
	static QVariantMap data;
	if(data.isEmpty())
	{
		QFile file(QStringLiteral(":/anyplay-pad/pad.json"));
		if(file.open(QIODevice::ReadOnly))
			data = QJsonDocument::fromJson(file.readAll()).object().toVariantMap();
	}
	return data;
}

QVariantList AnyPlayInput::Layouts()
{
	static const QHash<QString, QString> names = {
		{QStringLiteral("gta6"), QStringLiteral("GTA VI")},
		{QStringLiteral("gta5"), QStringLiteral("GTA V")},
		{QStringLiteral("universal"), QStringLiteral("Інша гра")},
	};
	static const QHash<QString, QString> info = {
		{QStringLiteral("gta6"), QStringLiteral("Клавіші під GTA VI")},
		{QStringLiteral("gta5"), QStringLiteral("Клавіші під GTA V")},
		{QStringLiteral("universal"), QStringLiteral("Кожна кнопка на клавіші")},
	};
	static const QHash<QString, QString> logos = {
		{QStringLiteral("gta6"), QStringLiteral("qrc:/anyplay-games/gta6.png")},
		{QStringLiteral("gta5"), QStringLiteral("qrc:/anyplay-games/gta5.png")},
		{QStringLiteral("universal"), QStringLiteral("qrc:/anyplay-games/other.png")},
	};
	QVariantList result;
	for(const QString &id : LayoutIds)
	{
		QVariantMap row;
		row["id"] = id;
		row["name"] = names.value(id);
		row["info"] = info.value(id);
		row["logo"] = logos.value(id);
		result.append(row);
	}
	return result;
}

QString AnyPlayInput::Layout()
{
	const QString id = QSettings().value(LayoutKey, QStringLiteral("gta6")).toString();
	return LayoutIds.contains(id) ? id : QStringLiteral("gta6");
}

void AnyPlayInput::SetLayout(const QString &id)
{
	if(!LayoutIds.contains(id) || id == Layout())
		return;
	QSettings().setValue(LayoutKey, id);
	NotifyConfigChanged();
}
