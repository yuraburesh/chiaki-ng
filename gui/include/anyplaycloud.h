// AnyPlay: вхід через Telegram і доступ до PS5 лише в час оплаченої броні.
#pragma once

#include <QObject>
#include <QTimer>
#include <QNetworkAccessManager>
#include <QJsonObject>
#include <QVariantMap>
#include <functional>

class Settings;
class QmlBackend;

class AnyPlayCloud : public QObject
{
	Q_OBJECT
	Q_PROPERTY(QString state READ state NOTIFY changed)          // login | pairing | wait | play | no_console | offline
	Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY changed)
	Q_PROPERTY(bool admin READ admin NOTIFY changed)
	Q_PROPERTY(QString userName READ userName NOTIFY changed)
	Q_PROPERTY(qint64 endTs READ endTs NOTIFY changed)           // кінець поточної броні (unix, час сервера)
	Q_PROPERTY(qint64 nextStart READ nextStart NOTIFY changed)
	Q_PROPERTY(qint64 nextEnd READ nextEnd NOTIFY changed)
	Q_PROPERTY(qint64 clockSkew READ clockSkew NOTIFY changed)   // сервер − комп'ютер, секунди
	Q_PROPERTY(QString consoleName READ consoleName NOTIFY changed)
	Q_PROPERTY(QString notice READ notice NOTIFY changed)
	Q_PROPERTY(bool clientMode READ clientMode NOTIFY changed)  // звичайний клієнт: ховаємо зайві налаштування
	Q_PROPERTY(QString myPsn READ myPsn NOTIFY changed)         // власний акаунт PSN клієнта
	Q_PROPERTY(bool myPsnReady READ myPsnReady NOTIFY changed)
	Q_PROPERTY(bool closed READ closed NOTIFY changed)          // адмін тимчасово закрив доступ
	Q_PROPERTY(QVariantMap adminInfo READ adminInfo NOTIFY adminChanged) // адмін: хто грає, найближчі броні, доступ

public:
	AnyPlayCloud(Settings *settings, QmlBackend *backend, QObject *parent = nullptr);

	QString state() const { return state_; }
	bool loggedIn() const { return !token_.isEmpty(); }
	bool admin() const { return admin_; }
	QString userName() const { return user_; }
	qint64 endTs() const { return end_; }
	qint64 nextStart() const { return next_start_; }
	qint64 nextEnd() const { return next_end_; }
	qint64 clockSkew() const { return skew_; }
	QString consoleName() const { return console_; }
	QString notice() const { return notice_; }
	bool clientMode() const { return !admin_; }  // доки не зайшов адмін — простий інтерфейс клієнта
	QString myPsn() const { return my_psn_; }
	bool myPsnReady() const { return my_psn_ready_; }
	QVariantMap adminInfo() const { return admin_info_; }
	bool closed() const { return closed_; }

	Q_INVOKABLE void login();
	Q_INVOKABLE void cancelLogin();
	Q_INVOKABLE void logout();
	Q_INVOKABLE void refresh();
	Q_INVOKABLE void openBot();
	Q_INVOKABLE void uploadConsole();                // адмін: передати свою прив'язку PS5 і вхід PSN на сервер
	Q_INVOKABLE void setMyPsn(const QString &psn);   // клієнт: додати/прибрати свій акаунт PSN
	Q_INVOKABLE QString formatTime(qint64 ts) const;
	Q_INVOKABLE void refreshAdmin();
	Q_INVOKABLE void adminKick(qint64 bookingId);    // адмін: завершити поточну гру клієнта
	Q_INVOKABLE void adminSetClosed(bool closed);    // адмін: закрити / відкрити доступ усім клієнтам

signals:
	void changed();
	void adminChanged();
	void message(const QString &text);       // коротке сповіщення для інтерфейсу
	void stopRequested(const QString &reason);

private:
	void request(const QString &method, const QString &path, const QJsonObject &body,
	             std::function<void(int, const QJsonObject &)> done, bool auth = true);
	void applySession(const QJsonObject &o);
	void heartbeat();
	void setState(const QString &s);
	void stopPlay(const QString &reason);

	Settings *settings;
	QmlBackend *backend;
	QNetworkAccessManager nam;
	QTimer poll_timer, pair_timer, beat_timer;
	QString server_, token_, pair_code_, state_ = "login", user_, console_, notice_, my_psn_;
	bool admin_ = false, playing_ = false, my_psn_ready_ = false, closed_ = false;
	qint64 end_ = 0, next_start_ = 0, next_end_ = 0, skew_ = 0;
	int pair_tries_ = 0;
	QVariantMap admin_info_;
};
