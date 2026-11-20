// AnyPlay: необов'язкова перевірка інтернету на екрані «Якість».
// Затримка (медіана кількох маленьких запитів), швидкість завантаження й (за бажанням) віддачі
// через speed.cloudflare.com і порада, яку якість обрати. Нічого не змінює сама: застосовує лише кнопка «Застосувати».
#pragma once

#include <QObject>
#include <QElapsedTimer>
#include <QNetworkAccessManager>
#include <QPointer>
#include <QTimer>
#include <QVector>

class QNetworkReply;

class AnyPlaySpeedTest : public QObject
{
	Q_OBJECT
	Q_PROPERTY(bool running READ running NOTIFY changed)
	Q_PROPERTY(double progress READ progress NOTIFY changed)         // 0…1
	Q_PROPERTY(QString stage READ stage NOTIFY changed)              // "" | ping | down | up | done
	Q_PROPERTY(double pingMs READ pingMs NOTIFY changed)             // −1 — ще не виміряно
	Q_PROPERTY(double downMbps READ downMbps NOTIFY changed)         // −1 — ще не виміряно
	Q_PROPERTY(double upMbps READ upMbps NOTIFY changed)             // −1 — не міряли
	Q_PROPERTY(QString error READ error NOTIFY changed)
	Q_PROPERTY(int recommendedLevel READ recommendedLevel NOTIFY changed)   // −1 немає, 0 Економна, 1 Оптимальна, 2 Максимальна або Ультра

public:
	explicit AnyPlaySpeedTest(QObject *parent = nullptr);
	~AnyPlaySpeedTest() override;

	bool running() const { return running_; }
	double progress() const { return progress_; }
	QString stage() const { return stage_; }
	double pingMs() const { return ping_ms_; }
	double downMbps() const { return down_mbps_; }
	double upMbps() const { return up_mbps_; }
	QString error() const { return error_; }
	int recommendedLevel() const;

	Q_INVOKABLE void start(bool upload = true);
	Q_INVOKABLE void cancel();

signals:
	void changed();

private:
	void nextPing();
	void startDownload();
	void finishDownload();
	void startUpload();
	void finishUpload();
	void finish();
	void fail(const QString &text);
	void abortReply();
	void setProgress(double p);

	QNetworkAccessManager nam;
	QPointer<QNetworkReply> reply_;
	QElapsedTimer clock_;          // час поточного запиту
	QElapsedTimer phase_clock_;    // час поточного етапу (від першого байта)
	QTimer limit_timer_;           // межа тривалості етапу
	QVector<double> pings_;
	int ping_left_ = 0;
	qint64 bytes_ = 0;
	qint64 first_byte_ms_ = -1;
	bool running_ = false, upload_ = true;
	double progress_ = 0, ping_ms_ = -1, down_mbps_ = -1, up_mbps_ = -1;
	QString stage_, error_;
	int generation_ = 0;           // щоб відповіді від скасованої перевірки нічого не міняли
};
