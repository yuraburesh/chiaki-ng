// AnyPlay: оновлення програми прямо в ній (Windows і Mac).
// Сервер каже, чи є нова опублікована збірка; програма завантажує файл, звіряє SHA-256 і розмір,
// закривається, ставить нову версію й відкривається сама. Під час гри вікно не показуємо.
#pragma once

#include <QObject>
#include <QTimer>
#include <QFile>
#include <QElapsedTimer>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QFutureWatcher>
#include <QJsonObject>

#ifndef ANYPLAY_BUILD_NUMBER
#error "ANYPLAY_BUILD_NUMBER не задано: його бере CMake з anyplay-build.txt"
#endif

class AnyPlayCloud;
class QmlBackend;
class QNetworkReply;

// Номер цієї збірки програми (з anyplay-build.txt)
static constexpr int AnyPlayBuildNumber = ANYPLAY_BUILD_NUMBER;

// Платформа для сервера: windows | mac | mac_intel | linux
const char *anyplayPlatform();

class AnyPlayUpdater : public QObject
{
	Q_OBJECT
	Q_PROPERTY(bool supported READ supported CONSTANT)             // на цій системі програма вміє оновлюватись сама
	Q_PROPERTY(int currentBuild READ currentBuild CONSTANT)
	Q_PROPERTY(bool available READ available NOTIFY changed)       // є новіша опублікована збірка
	Q_PROPERTY(int build READ build NOTIFY changed)
	Q_PROPERTY(QString version READ version NOTIFY changed)
	Q_PROPERTY(QString notes READ notes NOTIFY changed)
	Q_PROPERTY(bool mandatory READ mandatory NOTIFY changed)       // без оновлення грати не вийде
	Q_PROPERTY(QString manual READ manual NOTIFY changed)          // сторінка, де завантажити вручну
	Q_PROPERTY(QString phase READ phase NOTIFY changed)            // idle | downloading | verifying | installing | error
	Q_PROPERTY(qint64 received READ received NOTIFY progressChanged)
	Q_PROPERTY(qint64 total READ total NOTIFY progressChanged)
	Q_PROPERTY(double speed READ speed NOTIFY progressChanged)     // байт за секунду
	Q_PROPERTY(QString error READ error NOTIFY changed)
	Q_PROPERTY(bool prompt READ prompt NOTIFY changed)             // зараз можна (і треба) показати вікно оновлення
	Q_PROPERTY(bool needsMove READ needsMove CONSTANT)             // Mac: програма запущена не з «Програм» (з образу диска чи «Завантажень»)
	Q_PROPERTY(bool moving READ moving NOTIFY changed)             // Mac: переносимо програму в «Програми»
	Q_PROPERTY(QString revealPath READ revealPath NOTIFY changed)  // Mac: нова версія, яку треба перетягти в «Програми» самому

public:
	AnyPlayUpdater(AnyPlayCloud *cloud, QmlBackend *backend, QObject *parent = nullptr);

	bool supported() const;
	int currentBuild() const { return AnyPlayBuildNumber; }
	bool available() const { return available_; }
	int build() const { return build_; }
	QString version() const { return version_; }
	QString notes() const { return notes_; }
	bool mandatory() const { return mandatory_ && !may_play_; }   // поки сервер дозволяє грати, не блокуємо
	QString manual() const { return manual_; }
	QString phase() const { return phase_; }
	qint64 received() const { return received_; }
	qint64 total() const { return total_; }
	double speed() const { return speed_; }
	QString error() const { return error_; }
	bool prompt() const { return prompt_; }
	bool needsMove() const { return needs_move_; }
	bool moving() const { return moving_; }
	QString revealPath() const { return reveal_path_; }

	Q_INVOKABLE void check();             // запитати сервер, чи є оновлення
	Q_INVOKABLE void start();             // «Оновити»: завантажити, перевірити, встановити
	Q_INVOKABLE void cancel();            // «Скасувати» завантаження (недокачаний файл лишається для докачування)
	Q_INVOKABLE void openManual();        // «Завантажити вручну»
	Q_INVOKABLE void later();             // «Пізніше»: не показувати до наступної перевірки
	Q_INVOKABLE void show();              // відкрити вікно оновлення самому (кнопка на головному екрані)
	Q_INVOKABLE void moveToApplications(); // Mac: «Перенести в Програми»
	Q_INVOKABLE void revealNew();         // Mac: показати нову версію у Finder

signals:
	void changed();
	void progressChanged();
	void message(const QString &text);   // коротке сповіщення для головного екрана

private:
	void requestManifest();
	void applyManifest(const QJsonObject &o);
	void beginDownload();
	void setPhase(const QString &phase, const QString &error = QString());
	void updatePrompt();
	bool streaming() const;
	QString updatesDir() const;
	QString targetFile() const;
	void download();
	void onDownloadFinished();
	void verify();
	void install(const QString &file);
	void installWindows(const QString &file);
	void installMac(const QString &file);
	bool runMacHelper(const QString &source, const QString &bundle);
	QString macBundlePath() const;
	void readLastAttempt();
	void quitForUpdate();

	AnyPlayCloud *cloud;
	QmlBackend *backend;
	QNetworkAccessManager nam;
	QTimer check_timer, speed_timer;
	QPointer<QNetworkReply> check_reply, dl_reply;
	QFile part_file;
	QFutureWatcher<QByteArray> hash_watcher;
	QElapsedTimer speed_clock;
	qint64 speed_bytes_ = 0;

	bool available_ = false, mandatory_ = false, prompt_ = false, dismissed_ = false;
	bool start_after_check_ = false, canceled_ = false, needs_move_ = false, moving_ = false;
	bool range_sent_ = false, forced_ = false, may_play_ = false;
	int build_ = 0, min_build_ = 0;
	QString version_, notes_, manual_, url_, sha256_;
	qint64 size_ = 0, received_ = 0, total_ = 0, offset_ = 0;
	double speed_ = 0;
	QString phase_ = QStringLiteral("idle"), error_, reveal_path_;
	qint64 last_check_ms_ = 0;
};
