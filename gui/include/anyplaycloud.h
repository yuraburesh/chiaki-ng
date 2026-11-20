// AnyPlay: вхід через Telegram і доступ до PS5 лише в час оплаченої броні.
#pragma once

#include <QObject>
#include <QTimer>
#include <QNetworkAccessManager>
#include <QJsonObject>
#include <QVariantMap>
#include <QHash>
#include <functional>

class Settings;
class QmlBackend;

class AnyPlayCloud : public QObject
{
	Q_OBJECT
	Q_PROPERTY(QString state READ state NOTIFY changed)          // login | pairing | wait | play | no_console | offline | update | other_device
	Q_PROPERTY(QString otherDevice READ otherDevice NOTIFY changed)   // other_device: на якому пристрої клієнт зараз грає
	Q_PROPERTY(bool paymentChecking READ paymentChecking NOTIFY changed)  // гра в кредит: оплату продовження ще перевіряють, endTs — кінець кредиту
	Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY changed)
	Q_PROPERTY(bool admin READ admin NOTIFY changed)
	Q_PROPERTY(QString userName READ userName NOTIFY changed)
	Q_PROPERTY(qint64 endTs READ endTs NOTIFY changed)           // кінець поточної броні (unix, час сервера)
	Q_PROPERTY(qint64 nextStart READ nextStart NOTIFY changed)
	Q_PROPERTY(qint64 nextEnd READ nextEnd NOTIFY changed)
	Q_PROPERTY(qint64 ownEnd READ ownEnd NOTIFY changed)            // кінець саме поточної броні (endTs — кінець усього ланцюжка броней)
	Q_PROPERTY(bool continues READ continues NOTIFY changed)        // наступна оплачена бронь цього клієнта йде одразу, без перерви
	Q_PROPERTY(qint64 clockSkew READ clockSkew NOTIFY changed)   // сервер − комп'ютер, секунди
	Q_PROPERTY(QString consoleName READ consoleName NOTIFY changed)
	Q_PROPERTY(QString notice READ notice NOTIFY changed)
	Q_PROPERTY(bool clientMode READ clientMode NOTIFY changed)  // звичайний клієнт: ховаємо зайві налаштування
	Q_PROPERTY(QString myPsn READ myPsn NOTIFY changed)         // власний акаунт PSN клієнта
	Q_PROPERTY(bool myPsnReady READ myPsnReady NOTIFY changed)
	Q_PROPERTY(bool closed READ closed NOTIFY changed)          // адмін тимчасово закрив доступ
	Q_PROPERTY(QString myPsnStatus READ myPsnStatus NOTIFY changed)   // requested | qr_sent | signed_in | ready
	Q_PROPERTY(bool myPsnQr READ myPsnQr NOTIFY changed)              // адмін надіслав QR для входу на PS5
	Q_PROPERTY(bool myPsnLinked READ myPsnLinked NOTIFY changed)      // клієнт уже увійшов у PSN у програмі
	Q_PROPERTY(QString qrUrl READ qrUrl NOTIFY changed)
	Q_PROPERTY(QString myPsnCode READ myPsnCode NOTIFY changed)       // код для входу на PS5 цифрами (від адміна)
	Q_PROPERTY(QString myPsnLink READ myPsnLink NOTIFY changed)       // сторінка Sony для цього входу (якщо відома)
	Q_PROPERTY(QString playPsn READ playPsn NOTIFY changed)           // під яким акаунтом PSN зараз пускає приставка
	Q_PROPERTY(bool playOwn READ playOwn NOTIFY changed)              // true — це власний акаунт клієнта
	// якість: 0 — економна, 1 — оптимальна, 2 — максимальна; «авто» сама знижує її при слабкому зв'язку
	Q_PROPERTY(bool autoQuality READ autoQuality WRITE setAutoQuality NOTIFY changed)
	Q_PROPERTY(int qualityLevel READ qualityLevel NOTIFY changed)
	Q_PROPERTY(bool showStats READ showStats WRITE setShowStats NOTIFY changed)   // маленький індикатор під час гри: кадри, швидкість, якість
	Q_PROPERTY(bool reconnectOnce MEMBER reconnect_once_ NOTIFY changed)   // після зміни якості в грі: підключитись знову самому
	Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)                // іде прив'язка / перевірка
	Q_PROPERTY(QVariantMap extendInfo READ extendInfo NOTIFY extendChanged) // продовження: варіанти, ціни, заявка
	Q_PROPERTY(QVariantMap adminInfo READ adminInfo NOTIFY adminChanged) // адмін: хто грає, найближчі броні, доступ
	Q_PROPERTY(QVariantMap bookInfo READ bookInfo NOTIFY bookChanged)     // бронювання в програмі: дні, тарифи, мої броні
	Q_PROPERTY(QVariantList bookStarts READ bookStarts NOTIFY bookStartsChanged) // вільні старти для обраного дня й тарифу
	Q_PROPERTY(bool bookStartsLoading READ bookStartsLoading NOTIFY bookStartsChanged)
	// баланс (передоплата за гру): {balances: [{currency, amount, symbol}], primary} із сесії; після loadWallet() ще history, topup, pending
	Q_PROPERTY(QVariantMap wallet READ wallet NOTIFY walletChanged)
	Q_PROPERTY(bool hasWallet READ hasWallet NOTIFY walletChanged)    // сервер уміє баланс і це клієнт (в адмінів балансу немає)

public:
	AnyPlayCloud(Settings *settings, QmlBackend *backend, QObject *parent = nullptr);

	QString state() const { return state_; }
	QString server() const { return server_; }   // адреса сервера AnyPlay (для перевірки оновлень)
	bool loggedIn() const { return !token_.isEmpty(); }
	bool admin() const { return admin_; }
	QString userName() const { return user_; }
	qint64 endTs() const { return end_; }
	qint64 nextStart() const { return next_start_; }
	qint64 nextEnd() const { return next_end_; }
	qint64 ownEnd() const { return own_end_ > 0 ? own_end_ : end_; }
	bool continues() const { return continues_; }
	QString otherDevice() const { return other_device_; }
	bool paymentChecking() const { return payment_checking_; }
	qint64 clockSkew() const { return skew_; }
	QString consoleName() const { return console_; }
	QString notice() const { return notice_; }
	bool clientMode() const { return !admin_; }  // доки не зайшов адмін — простий інтерфейс клієнта
	QString myPsn() const { return my_psn_; }
	bool myPsnReady() const { return my_psn_ready_; }
	QVariantMap adminInfo() const { return admin_info_; }
	bool closed() const { return closed_; }
	QVariantMap extendInfo() const { return extend_info_; }
	QString myPsnStatus() const { return my_psn_status_; }
	bool myPsnQr() const { return my_psn_qr_; }
	bool myPsnLinked() const { return my_psn_linked_; }
	QString qrUrl() const;
	QString myPsnCode() const { return my_psn_code_; }
	QString myPsnLink() const { return my_psn_link_; }
	QString playPsn() const { return play_psn_; }
	bool playOwn() const { return play_own_; }
	bool busy() const { return busy_; }

	Q_INVOKABLE void login();
	Q_INVOKABLE void cancelLogin();
	Q_INVOKABLE void logout();
	Q_INVOKABLE void refresh();
	Q_INVOKABLE void openBot();
	Q_INVOKABLE void uploadConsole();                // адмін: передати свою прив'язку PS5 і вхід PSN на сервер
	Q_INVOKABLE void setMyPsn(const QString &psn);   // клієнт: додати/прибрати свій акаунт PSN
	Q_INVOKABLE QString formatTime(qint64 ts) const;
	Q_INVOKABLE void loadExtend();
	// клієнт: продовжити гру на N годин; pay: wallet — з балансу, mix — баланс + доплата переказом, transfer — уся сума переказом
	Q_INVOKABLE void extend(int hours, const QString &method = QString(), const QString &pay = QStringLiteral("transfer"));
	Q_INVOKABLE void payExtend(qint64 bookingId, const QString &sender);    // клієнт: «Я оплатив»
	Q_INVOKABLE bool beginMyPsnLogin();              // клієнт: перед входом у PSN (офіційна сторінка Sony)
	Q_INVOKABLE void sendMyPsnLogin();               // клієнт: після входу — передати ID акаунта на сервер
	Q_INVOKABLE void myPsnDone();                    // клієнт: «Я увійшов на приставці»
	Q_INVOKABLE void linkClientConsole(qint64 userId, const QString &accountId, const QString &pin); // адмін
	Q_INVOKABLE void copyText(const QString &text);
	bool autoQuality() const;
	bool showStats() const;
	void setShowStats(bool on);
	void setAutoQuality(bool on);
	int qualityLevel() const;
	Q_INVOKABLE void setQualityLevel(int level);   // застосувати рівень: роздільність, кадри, бітрейт
	Q_INVOKABLE void prepareAutoQuality();         // перед «Грати»: після довгої чистої гри пробуємо рівень вище
	Q_INVOKABLE bool autoQualityDown();            // зв'язок слабкий: рівень нижче (false — нижче нікуди)
	Q_INVOKABLE void autoQualityGood();            // довго грали без втрат
	Q_INVOKABLE bool renderLighter();              // ноутбук не встигає малювати: простіша обробка картинки на цю гру
	Q_INVOKABLE void renderUndo();                 // спрощення не допомогло (кадри губляться не через обробку): повертаємо як було
	void applyRender(int level, bool keepOwn = false);
	Q_INVOKABLE void refreshAdmin();
	Q_INVOKABLE void adminKick(qint64 bookingId);    // адмін: завершити поточну гру клієнта
	Q_INVOKABLE void adminSetClosed(bool closed);    // адмін: закрити / відкрити доступ усім клієнтам
	Q_INVOKABLE void adminDropShared();              // адмін: прибрати спільний акаунт PSN із сервера
	Q_INVOKABLE QString localPsnName() const;        // під яким акаунтом PSN увійдено в цій програмі ("" — не увійдено)
	Q_INVOKABLE QString localConsoleName() const;    // PS5, прив'язана в цій програмі ("" — немає)
	Q_INVOKABLE int localRegistState() const;        // 0 — PS5 не прив'язана, 1 — прив'язана під поточним входом PSN, 2 — під іншим або невідомо
	Q_INVOKABLE void openMyPsnLink();                // клієнт: відкрити сторінку Sony для входу на приставці
	Q_INVOKABLE void loadBook();                                               // екран бронювання
	Q_INVOKABLE void loadBookStarts(const QString &day, const QString &code);   // вільний час на день
	Q_INVOKABLE void book(qint64 start, const QString &code, const QString &method, const QString &pay = QStringLiteral("transfer"));
	Q_INVOKABLE void cancelBooking(qint64 bookingId);
	Q_INVOKABLE void payBooking(qint64 bookingId, const QString &sender);       // «Я оплатив» для броні
	Q_INVOKABLE void loadWallet();                                             // баланс, історія, суми поповнення, відкриті поповнення
	Q_INVOKABLE void topUp(const QString &method, double amount);               // поповнити баланс переказом
	Q_INVOKABLE void topUpPaid(qint64 topupId, const QString &sender);          // «Я оплатив» для поповнення
	Q_INVOKABLE void topUpCancel(qint64 topupId);
	Q_INVOKABLE void walletCurrency(const QString &currency, bool preview);      // валюта балансу: показати, що вийде, або перевести
	QVariantMap wallet() const { return wallet_; }
	bool hasWallet() const { return has_wallet_ && !admin_; }
	QVariantMap bookInfo() const { return book_info_; }
	QVariantList bookStarts() const { return book_starts_; }
	bool bookStartsLoading() const { return book_starts_loading_; }

signals:
	void changed();
	void adminChanged();
	void extendChanged();
	void extendResult(bool ok, const QString &text);
	void bookChanged();
	void bookStartsChanged();
	void bookResult(bool ok, const QString &text);
	void walletChanged();
	void walletCurrencyPreview(const QVariantMap &info);   // що буде після переведення балансу в іншу валюту
	void walletResult(bool ok, const QString &text);   // поповнення: створено, «Я оплатив», скасовано, зараховано
	void busyChanged();
	void linkResult(bool ok, const QString &text);
	void message(const QString &text);       // коротке сповіщення для інтерфейсу
	void stopRequested(const QString &reason);

private:
	void request(const QString &method, const QString &path, const QJsonObject &body,
	             std::function<void(int, const QJsonObject &)> done, bool auth = true);
	void applySession(const QJsonObject &o);
	void startClientLink(qint64 userId, const QByteArray &account, const QString &digits, const QString &host);
	QString linkErrorText(const QString &errors) const;
	void saveClientLink(const QJsonObject &body, int attempt);
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
	qint64 own_end_ = 0;
	bool continues_ = false;
	QString other_device_;          // стан other_device: назва пристрою, на якому йде гра
	bool payment_checking_ = false; // гра в кредит, поки адмін перевіряє оплату продовження
	QTimer other_timer;             // other_device: частіше питаємо сервер, щоб «Грати» з'явилось одразу, як там вийдуть з гри
	QTimer start_timer;     // оновитись рівно в момент початку гри, а не чекати звичайного опитування раз на хвилину
	int start_polls_ = 0;
	void scheduleStartRefresh();
	int pair_tries_ = 0;
	QVariantMap admin_info_, extend_info_;
	QVariantMap book_info_;
	QVariantList book_starts_;
	QString book_starts_key_;
	bool book_starts_loading_ = false;
	int book_polls_ = 0;
	QTimer book_timer;
	QString my_psn_status_, my_psn_code_, my_psn_link_, play_psn_;
	bool play_own_ = false;
	bool my_psn_qr_ = false, my_psn_linked_ = false, busy_ = false, psn_login_active_ = false;
	int qr_rev_ = 0, psn_wait_tries_ = 0, pay_polls_ = 0;
	QTimer psn_wait_timer, pay_timer, admin_timer;
	QJsonObject admin_cmp_;
	bool reconnect_once_ = false;
	struct { int preset = -1; QVariant cap, until; } render_undo_;   // що було до останнього спрощення обробки
	qint64 link_job_user_ = 0;   // прив'язка за кодом, який адмін написав у боті: кому звітувати
	void setBusy(bool b) { if(busy_ != b) { busy_ = b; emit busyChanged(); } }
	// ── баланс ──
	QVariantMap wallet_;
	bool has_wallet_ = false;
	QTimer wallet_timer;            // після «Я оплатив» за поповнення: перепитуємо, поки гроші не з'являться на балансі
	int wallet_polls_ = 0;
	QHash<QString, QString> request_ids_;   // дія клієнта → requestId: повтор тієї самої дії після збою зв'язку йде з тим самим ідентифікатором
	QString requestId(const QString &action);
	void requestDone(const QString &action, int status);
	bool applyWalletBalances(const QJsonValue &w);   // balances + primary з відповіді сервера; true — щось змінилось
	double walletBalance(const QString &currency) const;
	QString walletMoney(double amount, const QString &currency, const QString &symbol = QString()) const;
	QString walletLeftText(const QString &currency) const;
	QString walletError(const QString &error, int status) const;
};
