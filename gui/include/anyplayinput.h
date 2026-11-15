// AnyPlay: keyboard and mouse to DualSense with game-style control profiles
// (on foot / vehicle / aircraft), held buttons, auto-repeat, taps and macros.
#ifndef ANYPLAY_INPUT_H
#define ANYPLAY_INPUT_H

#include <chiaki/controller.h>

#include <QObject>
#include <QHash>
#include <QList>
#include <QString>
#include <QTimer>
#include <QJsonObject>
#include <QVariantList>

class QKeyEvent;

struct APStep
{
	uint32_t buttons = 0; // chiaki buttons, plus CHIAKI_CONTROLLER_ANALOG_BUTTON_L2/R2 for the triggers
	float lx = 0, ly = 0, rx = 0, ry = 0; // stick deflection -1..1 (y < 0 is up)
	int ms = 0; // macro step duration
};

struct APBinding
{
	enum class Kind { Hold, Tap, Turbo, Macro, None };
	QString id;
	QString name; // shown in the controls editor
	QString key;  // canonical input name, see AnyPlayInput::KeyName
	Kind kind = Kind::Hold;
	APStep out;
	QList<APStep> steps; // Macro
	QString profile;     // profile to switch to on press: an id or "toggle" (foot <-> vehicle)
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

		// Load the built-in layout and the user's key overrides from the settings
		void Load();

		// A key or mouse button went down / up. Returns true when the input is bound.
		bool HandleInput(const QString &name, bool pressed);
		// A short press (mouse wheel notch). Returns true when bound.
		bool Tap(const QString &name);
		void ReleaseAll();

		// Writes buttons, triggers and sticks of the current output into state
		void ApplyTo(ChiakiControllerState *state) const;

		QString CurrentProfileId() const { return current_profile; }
		QString CurrentProfileName() const;

		// Canonical input names
		static QString KeyName(const QKeyEvent *event);
		static QString KeyNameFromQml(int key, int modifiers, const QString &text);
		static QString MouseButtonName(Qt::MouseButton button);
		static QString DisplayName(const QString &key);

		// Controls editor
		static QVariantList ProfilesForEditor();
		static void SetKeyOverride(const QString &profile, const QString &id, const QString &key);
		static void ResetKeyOverrides();

	signals:
		void Changed();
		void ProfileChanged(const QString &name);

	private:
		struct Tapped { int id; APStep step; };

		static QJsonObject DefaultConfig();
		static QList<APProfile> ParseProfiles(const QJsonObject &config, bool apply_overrides);
		const APBinding *Find(const QString &name) const;
		void SwitchProfile(const QString &target);
		void StartMacro(const QList<APStep> &steps);
		void NextMacroStep();
		void AddTap(const APStep &step, int ms);

		QList<APProfile> profiles;
		QString current_profile;
		QHash<QString, APBinding> active; // held inputs -> the binding they started
		QList<Tapped> taps;
		int next_tap_id = 0;
		QList<APStep> macro;
		int macro_index = -1;
		QTimer macro_timer;
		QTimer turbo_timer;
		bool turbo_phase = false;
};

#endif // ANYPLAY_INPUT_H
