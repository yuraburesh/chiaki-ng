// AnyPlay: вхід у PSN через браузер без копіювання адреси.
// Після входу Sony відкриває сторінку «redirect» — програма сама бере її адресу з браузера:
//   macOS   — питає в активного браузера адресу відкритої вкладки (Safari, Chrome, Edge, Brave, Arc…),
//             і лише якщо це саме сторінка «redirect»; система один раз просить на це дозвіл;
//   Windows — читає заголовок вікна браузера (у сторінки «redirect» немає назви, тож у заголовку її адреса).
// Якщо не вийшло — лишається копіювання адреси вручну.
#pragma once

#include <QObject>
#include <QProcess>
#include <QStringList>
#include <QTimer>
#include <QUrl>

class AnyPlayBrowserWatch : public QObject
{
	Q_OBJECT

public:
	explicit AnyPlayBrowserWatch(QObject *parent = nullptr);

	void setActive(bool on);
	bool active() const { return timer.isActive(); }
	bool supported() const;                              // на цій системі вміємо підхоплювати адресу самі
	bool denied() const { return denied_; }              // користувач не дав програмі дозволу читати адресу

	static QStringList browsers();                       // браузери на цьому комп'ютері (для «відкрити в іншому»)
	static bool openIn(const QString &browser, const QUrl &url);

signals:
	void found(const QString &url);
	void deniedChanged();

private:
	void tick();
#ifdef Q_OS_MACOS
	void askFront();
	void askBrowser(const QString &bundle_id);
	QProcess *proc = nullptr;
	QString last_browser;
#endif
	QTimer timer;
	bool denied_ = false;
};
