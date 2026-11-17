#include "anyplayinput.h"
#include "settings.h"

#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QSettings>
#include <QVariantMap>

namespace {

constexpr int TurboIntervalMs = 55;  // sprint: the button is tapped ~9 times a second while the key is held
constexpr int TapMs = 90;            // a short press: long enough for the game to register it

const QString OverrideGroup = QStringLiteral("anyplay_keys");
const QString AutoVehicleKey = QStringLiteral("anyplay/auto_vehicle");
constexpr int PendingMs = 7000;      // how long after F we wait for the console's confirmation
constexpr int PendingGraceMs = 250;  // ignore signals right at the key press
constexpr int HapticHitsNeeded = 3;  // haptic frames (10 ms each) above the noise floor

uint32_t ButtonFromName(const QString &name)
{
	static const QHash<QString, uint32_t> buttons = {
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
	return buttons.value(name.toUpper(), 0);
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

// Cyrillic letter -> the Latin key at the same place (Ukrainian/Russian ЙЦУКЕН layout)
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
		// on a Mac Qt reports the Control key as Meta and Command as Control
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

} // namespace

AnyPlayInput::AnyPlayInput(QObject *parent) : QObject(parent)
{
	macro_timer.setSingleShot(true);
	connect(&macro_timer, &QTimer::timeout, this, &AnyPlayInput::NextMacroStep);
	turbo_timer.setInterval(TurboIntervalMs);
	connect(&turbo_timer, &QTimer::timeout, this, [this]() {
		turbo_phase = !turbo_phase;
		emit Changed();
	});
	pending_timer.setSingleShot(true);
	pending_timer.setInterval(PendingMs);
	connect(&pending_timer, &QTimer::timeout, this, [this]() {
		if(!VehiclePending())
			return;
		StopPending();
		// no confirmation: stay on foot, but tell how to switch by hand if the player did get in
		hint = QStringLiteral("%1 · якщо ти вже в транспорті — натисни F2").arg(ProfileName(current_profile));
		emit ProfileChanged(StatusText());
	});
}

QJsonObject AnyPlayInput::DefaultConfig()
{
	QFile file(QStringLiteral(":/anyplay/anyplay-controls.json"));
	if(!file.open(QIODevice::ReadOnly))
		return {};
	return QJsonDocument::fromJson(file.readAll()).object();
}

QList<APProfile> AnyPlayInput::ParseProfiles(const QJsonObject &config, bool apply_overrides)
{
	QSettings settings;
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
				: kind == "none" ? APBinding::Kind::None
				: APBinding::Kind::Hold;
			binding.out = StepFromJson(bo);
			for(const auto &s : bo.value("steps").toArray())
				binding.steps.append(StepFromJson(s.toObject()));
			binding.profile = bo.value("profile").toString();
			if(apply_overrides)
			{
				const QString path = QStringLiteral("%1/%2/%3").arg(OverrideGroup, profile.id, binding.id);
				if(settings.contains(path))
					binding.key = settings.value(path).toString();
			}
			profile.bindings.append(binding);
		}
		result.append(profile);
	}
	return result;
}

void AnyPlayInput::Load()
{
	const QJsonObject config = DefaultConfig();
	profiles = ParseProfiles(config, true);
	current_profile = config.value("start").toString("foot");
	auto_vehicle = AutoVehicle();
	StopPending();
	hint.clear();
	ReleaseAll();
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
	if(name.isEmpty())
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
				return &b; // the current mode wins over the shared keys
			global = &b;
		}
	}
	return global;
}

bool AnyPlayInput::HandleInput(const QString &name, bool pressed)
{
	if(!pressed)
	{
		auto it = active.find(name);
		if(it == active.end())
			return Find(name) != nullptr;
		const bool turbo = it->kind == APBinding::Kind::Turbo;
		active.erase(it);
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

	if(active.contains(name))
		return true; // key repeat
	const APBinding *binding = Find(name);
	if(!binding)
		return false;
	const APBinding b = *binding; // copy: switching the profile below invalidates the pointer
	switch(b.kind)
	{
		case APBinding::Kind::Hold:
			active.insert(name, b);
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
			StartMacro(b.steps);
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
	const APBinding *binding = Find(name);
	if(!binding)
		return false;
	const APBinding b = *binding;
	if(b.kind == APBinding::Kind::Macro)
		StartMacro(b.steps);
	else if(b.kind != APBinding::Kind::None)
		AddTap(b.out, TapMs);
	if(!b.profile.isEmpty())
		SwitchProfile(b.profile);
	emit Changed();
	return true;
}

void AnyPlayInput::ReleaseAll()
{
	active.clear();
	taps.clear();
	macro.clear();
	macro_index = -1;
	macro_timer.stop();
	turbo_timer.stop();
	emit Changed();
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

void AnyPlayInput::SwitchProfile(const QString &target)
{
	if(target == QLatin1String("toggle"))
	{
		if(current_profile == QLatin1String("foot"))
		{
			if(auto_vehicle)
			{
				// The player may be nowhere near a vehicle: keep "on foot" until the console
				// confirms that he got in (vibration / trigger resistance when the engine starts).
				StartPending();
				return;
			}
			SetProfile(QStringLiteral("vehicle"),
				QStringLiteral("%1 · F — назад «%2»").arg(ProfileName(QStringLiteral("vehicle")), ProfileName(QStringLiteral("foot"))));
			return;
		}
		SetProfile(QStringLiteral("foot"), QString());
		return;
	}
	SetProfile(target, QString());
}

void AnyPlayInput::SetProfile(const QString &id, const QString &hint_text)
{
	const bool was_pending = VehiclePending();
	StopPending();
	if(id == current_profile && !was_pending && hint_text.isEmpty())
		return;
	current_profile = id;
	hint = hint_text;
	emit ProfileChanged(StatusText());
}

void AnyPlayInput::StartPending()
{
	base_left = trig_left;
	base_right = trig_right;
	haptic_hits = 0;
	pending_since.start();
	pending_timer.start();
	pending.store(true, std::memory_order_relaxed);
	hint = QStringLiteral("Чекаю посадки в транспорт…");
	emit ProfileChanged(StatusText());
}

void AnyPlayInput::StopPending()
{
	pending.store(false, std::memory_order_relaxed);
	pending_timer.stop();
	haptic_hits = 0;
}

void AnyPlayInput::ConfirmVehicle()
{
	if(!VehiclePending() || pending_since.elapsed() < PendingGraceMs)
		return;
	SetProfile(QStringLiteral("vehicle"), QString());
}

void AnyPlayInput::NoteHaptics()
{
	if(!VehiclePending() || pending_since.elapsed() < PendingGraceMs)
		return;
	if(++haptic_hits >= HapticHitsNeeded)
		ConfirmVehicle();
}

void AnyPlayInput::NoteRumble(uint8_t left, uint8_t right)
{
	if(left || right)
		ConfirmVehicle();
}

void AnyPlayInput::NoteTriggers(uint8_t type_left, uint8_t type_right)
{
	trig_left = type_left;
	trig_right = type_right;
	if(!VehiclePending())
		return;
	// 0x00 and 0x05 mean "no effect"; a new effect that was not there when F was pressed
	// is the vehicle's pedals getting their resistance
	auto on = [](uint8_t t) { return t != 0x00 && t != 0x05; };
	if((on(type_left) && type_left != base_left) || (on(type_right) && type_right != base_right))
		ConfirmVehicle();
}

bool AnyPlayInput::AutoVehicle()
{
	QSettings settings;
	return settings.value(AutoVehicleKey, true).toBool();
}

void AnyPlayInput::SetAutoVehicle(bool enabled)
{
	QSettings settings;
	settings.setValue(AutoVehicleKey, enabled);
}

void AnyPlayInput::ApplyTo(ChiakiControllerState *state) const
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

	state->buttons = sum.buttons & ~(CHIAKI_CONTROLLER_ANALOG_BUTTON_L2 | CHIAKI_CONTROLLER_ANALOG_BUTTON_R2);
	state->l2_state = (sum.buttons & CHIAKI_CONTROLLER_ANALOG_BUTTON_L2) ? 0xff : 0;
	state->r2_state = (sum.buttons & CHIAKI_CONTROLLER_ANALOG_BUTTON_R2) ? 0xff : 0;
	state->left_x = Axis(sum.lx);
	state->left_y = Axis(sum.ly);
	state->right_x = Axis(sum.rx);
	state->right_y = Axis(sum.ry);
}

QString AnyPlayInput::KeyName(const QKeyEvent *event)
{
	const bool keypad = event->modifiers().testFlag(Qt::KeypadModifier);
	// letters and digits by their physical position, so any keyboard layout works
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

QString AnyPlayInput::KeyNameFromQml(int key, int modifiers, const QString &text)
{
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
		{"MouseLeft", "ЛКМ"}, {"MouseRight", "ПКМ"}, {"MouseMiddle", "Коліщатко (клік)"},
		{"Mouse4", "Миша 4"}, {"Mouse5", "Миша 5"},
		{"WheelUp", "Коліщатко ↑"}, {"WheelDown", "Коліщатко ↓"},
		{"Space", "Пробіл"}, {"CapsLock", "Caps Lock"},
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
	const QJsonObject config = DefaultConfig();
	const QList<APProfile> defaults = ParseProfiles(config, false);
	const QList<APProfile> current = ParseProfiles(config, true);
	QVariantList result;
	for(int p = 0; p < current.size(); p++)
	{
		QVariantList bindings;
		for(int i = 0; i < current[p].bindings.size(); i++)
		{
			const APBinding &b = current[p].bindings[i];
			QVariantMap row;
			row["id"] = b.id;
			row["name"] = b.name;
			row["key"] = b.key;
			row["keyName"] = DisplayName(b.key);
			row["changed"] = b.key != defaults[p].bindings[i].key;
			bindings.append(row);
		}
		QVariantMap profile;
		profile["id"] = current[p].id;
		profile["name"] = current[p].name;
		profile["bindings"] = bindings;
		result.append(profile);
	}
	return result;
}

void AnyPlayInput::SetKeyOverride(const QString &profile, const QString &id, const QString &key)
{
	QSettings settings;
	settings.setValue(QStringLiteral("%1/%2/%3").arg(OverrideGroup, profile, id), key);
}

void AnyPlayInput::ResetKeyOverrides()
{
	QSettings settings;
	settings.remove(OverrideGroup);
}
