#include "anyplaybrowser.h"

#include <QFileInfo>
#include <QRegularExpression>
#include <QSettings>

#ifdef Q_OS_WINDOWS
#include <windows.h>
#endif

#ifdef Q_OS_MACOS
static const char REDIRECT_HOST_PATH[] = "remoteplay.dl.playstation.net/remoteplay/redirect?";
#endif

// З довільного тексту (вивід скрипта, заголовок вікна) дістаємо адресу сторінки «redirect» з кодом входу
static QString RedirectFrom(const QString &text)
{
	static const QRegularExpression re(QStringLiteral("remoteplay\\.dl\\.playstation\\.net/remoteplay/redirect\\?[^\\s\"<>,]*code=[^\\s\"<>,]+"));
	QRegularExpressionMatch m = re.match(text);
	return m.hasMatch() ? QStringLiteral("https://") + m.captured(0) : QString();
}

AnyPlayBrowserWatch::AnyPlayBrowserWatch(QObject *parent) : QObject(parent)
{
	timer.setInterval(1200);
	connect(&timer, &QTimer::timeout, this, &AnyPlayBrowserWatch::tick);
}

bool AnyPlayBrowserWatch::supported() const
{
#if defined(Q_OS_MACOS) || defined(Q_OS_WINDOWS)
	return true;
#else
	return false;
#endif
}

void AnyPlayBrowserWatch::setActive(bool on)
{
	if(on == timer.isActive())
		return;
	if(on && supported())
	{
#ifdef Q_OS_MACOS
		last_browser.clear();
#endif
		timer.start();
	}
	else
		timer.stop();
}

#ifdef Q_OS_MACOS

// Браузери, які вміють віддати адресу вкладки через AppleScript: Safari і всі на основі Chromium
static bool IsSafari(const QString &id)
{
	return id == QLatin1String("com.apple.Safari") || id == QLatin1String("com.apple.SafariTechnologyPreview");
}

static bool IsChromium(const QString &id)
{
	static const QStringList ids = {
		QStringLiteral("com.google.Chrome"), QStringLiteral("com.google.Chrome.beta"), QStringLiteral("com.google.Chrome.canary"),
		QStringLiteral("com.microsoft.edgemac"), QStringLiteral("com.brave.Browser"), QStringLiteral("company.thebrowser.Browser"),
		QStringLiteral("com.vivaldi.Vivaldi"), QStringLiteral("com.operasoftware.Opera"), QStringLiteral("org.chromium.Chromium"),
		QStringLiteral("ru.yandex.desktop.yandex-browser"),
	};
	return ids.contains(id);
}

void AnyPlayBrowserWatch::tick()
{
	if(proc)   // попередній запит ще триває (наприклад, система питає дозвіл)
		return;
	if(denied_)
		return;
	askFront();
}

// Який застосунок зараз на передньому плані (дозволів це не потребує)
void AnyPlayBrowserWatch::askFront()
{
	proc = new QProcess(this);
	connect(proc, &QProcess::finished, this, [this](int, QProcess::ExitStatus) {
		if(!proc)
			return;
		QString out = QString::fromUtf8(proc->readAllStandardOutput());
		proc->deleteLater();
		proc = nullptr;
		static const QRegularExpression re(QStringLiteral("=\\s*\"([^\"]+)\""));
		QString id = re.match(out).captured(1);
		if(IsSafari(id) || IsChromium(id))
			last_browser = id;
		// клієнт міг уже повернутись у програму — тоді питаємо браузер, у якому він щойно був
		if(!last_browser.isEmpty() && timer.isActive())
			askBrowser(last_browser);
	});
	connect(proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError e) {
		if(e == QProcess::FailedToStart && proc) { proc->deleteLater(); proc = nullptr; }
	});
	proc->start(QStringLiteral("/bin/sh"), {QStringLiteral("-c"),
		QStringLiteral("/usr/bin/lsappinfo info -only bundleid \"$(/usr/bin/lsappinfo front)\"")});
}

// Адреса активної вкладки — і лише якщо це сторінка «redirect»; інші адреси з браузера не виходять
void AnyPlayBrowserWatch::askBrowser(const QString &bundle_id)
{
	const QString tab = IsSafari(bundle_id) ? QStringLiteral("current tab") : QStringLiteral("active tab");
	QStringList script = {
		QStringLiteral("set found to \"\""),
		QStringLiteral("tell application id \"%1\"").arg(bundle_id),
		QStringLiteral("repeat with w in (get windows)"),
		QStringLiteral("try"),
		QStringLiteral("set u to (URL of %1 of w) as text").arg(tab),
		QStringLiteral("if u contains \"%1\" then set found to u").arg(QLatin1String(REDIRECT_HOST_PATH)),
		QStringLiteral("end try"),
		QStringLiteral("end repeat"),
		QStringLiteral("end tell"),
		QStringLiteral("return found"),
	};
	QStringList args;
	for(const QString &line : script)
		args << QStringLiteral("-e") << line;
	proc = new QProcess(this);
	connect(proc, &QProcess::finished, this, [this](int, QProcess::ExitStatus) {
		if(!proc)
			return;
		QString out = QString::fromUtf8(proc->readAllStandardOutput());
		QString err = QString::fromUtf8(proc->readAllStandardError());
		proc->deleteLater();
		proc = nullptr;
		if(err.contains(QLatin1String("-1743")))   // «не дозволено надсилати Apple-події» — користувач відмовив
		{
			denied_ = true;
			emit deniedChanged();
			return;
		}
		QString url = RedirectFrom(out);
		if(!url.isEmpty() && timer.isActive())
		{
			timer.stop();
			emit found(url);
		}
	});
	connect(proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError e) {
		if(e == QProcess::FailedToStart && proc) { proc->deleteLater(); proc = nullptr; }
	});
	proc->start(QStringLiteral("/usr/bin/osascript"), args);
}

QStringList AnyPlayBrowserWatch::browsers()
{
	QStringList out;
	for(const char *name : {"Safari", "Google Chrome", "Firefox", "Microsoft Edge", "Brave Browser", "Arc", "Opera"})
	{
		QString n = QString::fromLatin1(name);
		if(QFileInfo::exists(QStringLiteral("/Applications/%1.app").arg(n))
			|| QFileInfo::exists(QStringLiteral("/System/Volumes/Preboot/Cryptexes/App/System/Applications/%1.app").arg(n)))
			out << n;
	}
	return out;
}

bool AnyPlayBrowserWatch::openIn(const QString &browser, const QUrl &url)
{
	if(!browsers().contains(browser))
		return false;
	return QProcess::startDetached(QStringLiteral("/usr/bin/open"),
		{QStringLiteral("-a"), browser, QString::fromUtf8(url.toEncoded())});
}

#elif defined(Q_OS_WINDOWS)

static BOOL CALLBACK AnyPlayEnumWindow(HWND hwnd, LPARAM lparam)
{
	if(!IsWindowVisible(hwnd))
		return TRUE;
	wchar_t buf[2048];
	int n = GetWindowTextW(hwnd, buf, 2048);
	if(n <= 0)
		return TRUE;
	QString url = RedirectFrom(QString::fromWCharArray(buf, n));
	if(url.isEmpty())
		return TRUE;
	*reinterpret_cast<QString *>(lparam) = url;
	return FALSE;
}

void AnyPlayBrowserWatch::tick()
{
	QString url;
	EnumWindows(AnyPlayEnumWindow, reinterpret_cast<LPARAM>(&url));
	if(!url.isEmpty())
	{
		timer.stop();
		emit found(url);
	}
}

static QString BrowserExe(const QString &exe)
{
	const QString key = QStringLiteral("\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\") + exe;
	for(const char *root : {"HKEY_CURRENT_USER", "HKEY_LOCAL_MACHINE"})
	{
		QString path = QSettings(QString::fromLatin1(root) + key, QSettings::NativeFormat).value(QStringLiteral(".")).toString();
		path.remove(QLatin1Char('"'));
		if(!path.isEmpty() && QFileInfo::exists(path))
			return path;
	}
	return QString();
}

static const struct { const char *name; const char *exe; } WIN_BROWSERS[] = {
	{"Google Chrome", "chrome.exe"}, {"Microsoft Edge", "msedge.exe"}, {"Firefox", "firefox.exe"},
	{"Brave", "brave.exe"}, {"Opera", "opera.exe"},
};

QStringList AnyPlayBrowserWatch::browsers()
{
	QStringList out;
	for(const auto &b : WIN_BROWSERS)
		if(!BrowserExe(QString::fromLatin1(b.exe)).isEmpty())
			out << QString::fromLatin1(b.name);
	return out;
}

bool AnyPlayBrowserWatch::openIn(const QString &browser, const QUrl &url)
{
	for(const auto &b : WIN_BROWSERS)
	{
		if(browser != QLatin1String(b.name))
			continue;
		QString exe = BrowserExe(QString::fromLatin1(b.exe));
		return !exe.isEmpty() && QProcess::startDetached(exe, {QString::fromUtf8(url.toEncoded())});
	}
	return false;
}

#else

void AnyPlayBrowserWatch::tick() {}
QStringList AnyPlayBrowserWatch::browsers() { return {}; }
bool AnyPlayBrowserWatch::openIn(const QString &, const QUrl &) { return false; }

#endif
