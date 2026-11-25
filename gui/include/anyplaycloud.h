// AnyPlay: вхід через Telegram і доступ до PS5 лише в час оплаченої броні.
#pragma once

#include <QObject>
#include <QTimer>
#include <QNetworkAccessManager>
#include <QJsonObject>
#include <QJsonArray>
#include <QUrl>
#include <QVariantMap>
#include <QHash>
#include <functional>

class Settings;
class QmlBackend;

class AnyPlayCloud : public QObject
{
	Q_OBJECT
	Q_PROPERTY(QString state READ state NOTIFY changed)
	// вхід, коли Telegram не на цьому комп'ютері: QR-код для телефона і шість цифр для бота
	Q_PROPERTY(QString pairShort MEMBER pair_short_ NOTIFY changed)
	Q_PROPERTY(QString pairQr MEMBER pair_qr_ NOTIFY changed)
	Q_PROPERTY(QString pairBot MEMBER pair_bot_ NOTIFY changed)          // login | pairing | wait | play | no_console | offline | update | other_device
	Q_PROPERTY(QString otherDevice READ otherDevice NOTIFY changed)   // other_device: на якому пристрої клієнт зараз грає
	// «Грати тут» (115): сервер у стані other_device дозволяє забрати гру на цей пристрій
	Q_PROPERTY(bool canTakeover READ canTakeover NOTIFY changed)
	Q_PROPERTY(int otherSeen READ otherSeen NOTIFY changed)               // секунд від останнього сигналу того пристрою, -1 — невідомо
	Q_PROPERTY(bool takeoverWaiting READ takeoverWaiting NOTIFY takeoverChanged)   // після «Грати тут»: забираємо гру або чекаємо, поки той пристрій відпустить приставку
	Q_PROPERTY(QString takeoverText READ takeoverText NOTIFY takeoverChanged)      // напис на цей час («Чекаємо, поки «…» відпустить приставку…»), інакше ""
	Q_PROPERTY(QString takeoverFrom READ takeoverFrom NOTIFY takeoverChanged)      // з якого пристрою забрали гру
	Q_PROPERTY(QString movedText READ movedText NOTIFY changed)           // гру забрав інший пристрій: «Гра продовжилась на іншому пристрої…» (до наступної гри тут)
	Q_PROPERTY(bool paymentChecking READ paymentChecking NOTIFY changed)  // гра в кредит: оплату продовження ще перевіряють, endTs — кінець кредиту
	Q_PROPERTY(bool loggedIn READ loggedIn NOTIFY changed)
	Q_PROPERTY(bool admin READ admin NOTIFY changed)
	Q_PROPERTY(QString userName READ userName NOTIFY changed)
	Q_PROPERTY(qint64 endTs READ endTs NOTIFY changed)           // кінець поточної броні (unix, час сервера)
	Q_PROPERTY(qint64 nextStart READ nextStart NOTIFY changed)
	Q_PROPERTY(qint64 nextEnd READ nextEnd NOTIFY changed)
	Q_PROPERTY(qint64 ownEnd READ ownEnd NOTIFY changed)            // кінець саме поточної броні (endTs — кінець усього ланцюжка броней)
	Q_PROPERTY(bool continues READ continues NOTIFY changed)        // наступна оплачена бронь цього клієнта йде одразу, без перерви
	Q_PROPERTY(bool guest READ guest NOTIFY changed)                // гостьовий доступ: грає, поки приставка вільна (endTs — початок найближчої чужої гри)
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
	// ── підтримка з програми (К11): чат з адміном, не виходячи з гри ──
	Q_PROPERTY(QVariantList supportMessages READ supportMessages NOTIFY supportChanged)
	Q_PROPERTY(int supportUnread READ supportUnread NOTIFY supportChanged)        // нові відповіді адміна (крапка на «Підтримка»)
	Q_PROPERTY(QString supportHours READ supportHours NOTIFY supportChanged)
	Q_PROPERTY(bool supportTyping READ supportTyping NOTIFY supportChanged)
	Q_PROPERTY(bool supportLoaded READ supportLoaded NOTIFY supportChanged)
	Q_PROPERTY(bool supportSending READ supportSending NOTIFY supportChanged)
	// ── перегляд гри клієнта адміном (К12): останній кадр як data:-адреса ──
	Q_PROPERTY(QString previewImage READ previewImage NOTIFY previewChanged)
	Q_PROPERTY(qint64 previewAt READ previewAt NOTIFY previewChanged)
	// 115: стан перегляду з відповіді сервера (оновлюється і на 204): ok | wait | offline | unsupported; "" — старий сервер;
	// error — запит не вдався (немає броні, немає права, немає зв'язку)
	Q_PROPERTY(QString previewState READ previewState NOTIFY previewChanged)
	Q_PROPERTY(qint64 previewNext READ previewNext NOTIFY previewChanged)        // X-Preview-Next: коли програма клієнта найпізніше дізнається про запит (час сервера, 0 — невідомо)
	Q_PROPERTY(qint64 previewFrameAt READ previewFrameAt NOTIFY previewChanged)  // X-Preview-At: коли сервер отримав останній кадр (час сервера, 0 — кадру ще не було)
	// ── CRM усередині програми (К10) ──
	Q_PROPERTY(bool webEngine READ webEngine CONSTANT)
	// AnyPlay 113, екран «Зображення» (К18): яка обробка картинки діє, чи обмежено її через слабкий ноутбук, оцінка комп'ютера
	Q_PROPERTY(QString renderName READ renderName NOTIFY renderChanged)     // яка обробка діє зараз: fast | default | high | ai | ai2 | custom
	Q_PROPERTY(bool renderCapped READ renderCapped NOTIFY renderChanged)     // ноутбук не встигав: обробку тримаємо простішою (3 дні)
	Q_PROPERTY(int renderCap READ renderCap NOTIFY renderChanged)            // до якого рівня (0..3), -1 — без обмеження
	Q_PROPERTY(int renderCappedFrom READ renderCappedFrom NOTIFY renderChanged) // яка обробка (VideoPreset) не потягнулась, -1 — жодна
	Q_PROPERTY(QString gpuName READ gpuName NOTIFY renderChanged)            // «Apple M2», «NVIDIA GeForce RTX 4060»
	Q_PROPERTY(QString pcInfo READ pcInfo NOTIFY renderChanged)              // «Apple M2, 8 ГБ»
	Q_PROPERTY(QString pcTier READ pcTier NOTIFY renderChanged)              // weak | ok | strong
	Q_PROPERTY(bool qualityHintShown READ qualityHintShown NOTIFY renderChanged) // під час гри: показано «Картинка просідає»

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
	bool guest() const { return guest_; }
	QString otherDevice() const { return other_device_; }
	bool canTakeover() const { return can_takeover_; }
	int otherSeen() const { return other_seen_; }
	bool takeoverWaiting() const;
	QString takeoverText() const;
	QString takeoverFrom() const { return takeover_from_; }
	QString movedText() const { return moved_text_; }
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

	Q_INVOKABLE void login(bool openTelegram = true);
	Q_INVOKABLE void openPairLink();
	Q_INVOKABLE void cancelLogin();
	Q_INVOKABLE void logout();
	Q_INVOKABLE void refresh();
	// «Грати тут»: POST /api/app/session {takeover:true}, далі підключення до приставки з повторами раз на 3 с,
	// поки вона відповідає «вже зайнято» (до takeover.waitUntil від сервера). Підсумок: takeoverChanged / takeoverFailed
	Q_INVOKABLE void takeover();
	Q_INVOKABLE void openBot();
	Q_INVOKABLE void uploadConsole(const QString &mac = QString());   // адмін: передати свою прив'язку PS5 і вхід PSN на сервер (mac — яка PS5, якщо прив'язано кілька)
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
	// ── екран «Зображення» ──
	bool renderCapped() const;
	int renderCap() const;
	int renderCappedFrom() const;
	QString gpuName() const;
	QString pcInfo() const;
	QString pcTier() const;
	bool qualityHintShown() const { return quality_hint_shown_; }
	Q_INVOKABLE QString renderLabel(int preset) const;   // назва обробки людською мовою за VideoPreset
	Q_INVOKABLE QString renderNameOf(int preset) const;  // fast | default | high | ai | ai2 | custom (К18)
	QString renderName() const;                          // те саме для обробки, що діє зараз
	Q_INVOKABLE void setRenderPreset(int preset);        // обробка вручну з екрана «Зображення»: у вікно й у налаштування; знімає обмеження
	Q_INVOKABLE void clearRenderCap();                   // «Спробувати ще раз»: дати ноутбуку нову спробу
	Q_INVOKABLE bool pcCanRender(int preset) const;      // чи потягне цей комп'ютер таку обробку (за оцінкою і за виміром)
	Q_INVOKABLE int renderCheck(int streamFps, int shownFps, bool networkOk);   // раз на 2 с під час гри: 0 нічого, 1 спростили, 2 повернули, 3 радимо знизити якість
	Q_INVOKABLE void qualityHintDone();                  // натиснули «Знизити» або закрили підказку
	Q_INVOKABLE void refreshAdmin();
	Q_INVOKABLE void adminKick(qint64 bookingId);    // адмін: завершити поточну гру клієнта
	Q_INVOKABLE void adminGrant(qint64 userId, int minutes, const QString &name = QString());   // адмін: подарувати гру просто зараз на 10…2880 хв (крок 5)
	Q_INVOKABLE void adminSetClosed(bool closed);    // адмін: закрити / відкрити доступ усім клієнтам
	Q_INVOKABLE void adminDropShared();              // адмін: прибрати спільний акаунт PSN із сервера
	Q_INVOKABLE void adminSharedActive(qint64 consoleId);   // К16: зробити цей спільний акаунт активним на його приставці
	Q_INVOKABLE void adminSharedRemove(qint64 consoleId);   // К16: прибрати цей спільний акаунт із сервера
	Q_INVOKABLE int adminHostIndex(const QVariantMap &unit) const;   // К15: яка з прив'язаних у цій програмі PS5 є цією приставкою (індекс у Chiaki.hosts, -1 — не знайдено)
	Q_INVOKABLE QVariantList localConsoles() const;  // усі PS5, прив'язані в цій програмі: {name, mac}
	Q_INVOKABLE QString localPsnName() const;        // під яким акаунтом PSN увійдено в цій програмі ("" — не увійдено)
	Q_INVOKABLE QString localConsoleName(const QString &mac = QString()) const;    // PS5, прив'язана в цій програмі ("" — немає); mac — яка саме, якщо їх кілька
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
	// підтримка (К11)
	QVariantList supportMessages() const { return support_msgs_; }
	int supportUnread() const { return support_unread_; }
	QString supportHours() const { return support_hours_; }
	bool supportTyping() const { return support_typing_; }
	bool supportLoaded() const { return support_loaded_; }
	bool supportSending() const { return support_sending_; }
	Q_INVOKABLE void loadSupport();                          // нові повідомлення (усі, якщо ще не вантажили)
	Q_INVOKABLE void sendSupport(const QString &text);
	Q_INVOKABLE void sendSupportPhoto(const QUrl &file);     // фото з диска, до 8 МБ
	Q_INVOKABLE void loadSupportImage(const QString &fileUrl);   // фото з чату: відповідь сигналом supportImage (data:-адреса)
	Q_INVOKABLE void reportPicture(const QString &note = QString());   // «Картинка глючить»: скарга в телеметрії + журнал
	// перегляд гри клієнта (К12)
	QString previewImage() const { return preview_image_; }
	qint64 previewAt() const { return preview_at_; }
	QString previewState() const { return preview_state_; }
	qint64 previewNext() const { return preview_next_; }
	qint64 previewFrameAt() const { return preview_frame_at_; }
	Q_INVOKABLE void loadPreview(qint64 bookingId, qint64 userId = 0);   // адмін: забрати останній кадр гри клієнта (гість без броні — за userId)
	Q_INVOKABLE void clearPreview();
	// CRM у програмі (К10)
	bool webEngine() const;
	Q_INVOKABLE QString crmUrl() const;                      // сторінка CRM на нашому сервері
	Q_INVOKABLE QString webAppScript() const;                // скрипт window.AnyPlayApp (лише для нашого домену)
	Q_INVOKABLE bool isOwnUrl(const QUrl &url) const;        // сторінка нашого сервера (інше відкриваємо зовні)
	Q_INVOKABLE void openExternal(const QUrl &url);
	Q_INVOKABLE void uploadLog(const QString &reason);       // журнал програми для підтримки (К13)
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
	void renderChanged();
	void renderNotice(const QString &text);  // під час гри: людське пояснення, чому обробку спростили чи повернули
	void qualityHint();                      // під час гри: кадри просідають не через обробку — запропонувати знизити якість
	void menuRequested();                    // відкрити меню AnyPlay (кнопка на геймпаді від «Керування»)
	void stopRequested(const QString &reason);
	void supportChanged();
	void supportResult(bool ok, const QString &text);
	void supportImage(const QString &fileUrl, const QString &dataUrl);
	void previewChanged();
	void takeoverChanged();
	void takeoverFailed(const QString &text);   // «Грати тут» не вийшло (текст для людини)
	void playMoved(const QString &text);        // гру зупинено, бо клієнт продовжив на іншому пристрої (текст для людини)

private slots:
	void onPreviewFrame(const QByteArray &jpeg);             // кадр від QmlMainWindow::previewFrameReady (К12)
	void onPreviewFailed(const QString &reason);             // QmlMainWindow::previewFrameFailed (115)

private:
	void request(const QString &method, const QString &path, const QJsonObject &body,
	             std::function<void(int, const QJsonObject &)> done, bool auth = true);
	void applySession(const QJsonObject &o);
	void startClientLink(qint64 userId, const QByteArray &account, const QString &digits, const QString &host);
	QString linkErrorText(const QString &errors) const;
	void saveClientLink(const QJsonObject &body, int attempt);
	void heartbeat();
	void setState(const QString &s);
	void stopPlay(const QString &reason, bool sleep = true);   // sleep=false: приставку не присипляти (на ній уже грають з іншого пристрою)

	Settings *settings;
	QmlBackend *backend;
	QNetworkAccessManager nam;
	QTimer poll_timer, pair_timer, beat_timer;
	QString pair_short_, pair_qr_, pair_bot_, pair_link_;
	QString server_, token_, pair_code_, state_ = "login", user_, console_, notice_, my_psn_;
	bool admin_ = false, playing_ = false, my_psn_ready_ = false, closed_ = false;
	qint64 end_ = 0, next_start_ = 0, next_end_ = 0, skew_ = 0;
	qint64 own_end_ = 0;
	bool continues_ = false;
	bool guest_ = false;            // гостьовий доступ (сервер каже «guest» у сесії)
	// ── телеметрія гри: раз на секунду знімаємо показники трансляції, у heartbeat ідуть середні за проміжок ──
	struct StatWindow { int n = 0; double fps_stream = 0, fps_shown = 0, bitrate = 0, loss = 0; int dropped = 0; };
	StatWindow stat_;
	qint64 stat_connected_ms_ = 0;  // коли трансляція підключилась (перші секунди не рахуємо: кадри ще не пішли)
	bool stat_sent_ = false;        // перші показники цієї трансляції вже надіслано
	QTimer stat_timer;
	void sampleStats();
	QJsonObject takeStats();
	QString adminError(const QJsonObject &o, int status, const QString &fallback) const;
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
	// вимір обробки під час гри (renderCheck): скільки тиків поспіль кадри на екрані < 80% потоку, перевірка після спрощення
	struct { int slow = 0; int ticks = 0; int check = 0; int before = 0; int sum = 0; bool gaveUp = false; qint64 hintAt = 0; int hintSlow = 0; } rc_;
	bool quality_hint_shown_ = false;
	mutable QString pc_cpu_, pc_mem_, pc_model_;
	QString pcCpu() const;
	QString pcMem() const;
	int pcRamGb() const;        // 117: оперативна пам'ять, ГБ (0 — невідомо)
	QString pcModel() const;    // 117: модель комп'ютера: «MacBook Air 15″ M2», «Lenovo Legion 5 15ACH6H»
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
	// ── етап 3: підтримка, перегляд, журнал ──
	void rawRequest(const QString &method, const QString &path, const QByteArray &contentType, const QByteArray &body,
	                std::function<void(int, const QByteArray &, const QByteArray &)> done);   // статус, тіло, тип вмісту
	void applyExtras(const QJsonObject &o);                  // поля heartbeat і /api/app/session: support, preview, sendLog
	void mergeSupport(const QJsonArray &messages, bool replace);
	void previewTick();
	QVariantList support_msgs_;
	int support_unread_ = 0;
	qint64 support_last_id_ = 0;
	QString support_hours_;
	bool support_typing_ = false, support_loaded_ = false, support_sending_ = false, support_loading_ = false;
	QString preview_image_;
	qint64 preview_at_ = 0;
	bool preview_loading_ = false;
	QString preview_state_;
	qint64 preview_next_ = 0, preview_frame_at_ = 0;
	qint64 preview_until_ms_ = 0;                            // до коли надсилати кадри (час цього комп'ютера)
	int preview_width_ = 480;
	bool preview_busy_ = false;                              // кадр уже готується або летить на сервер
	QTimer preview_timer;
	int preview_quality_ = 60;                               // якість JPEG; сервер відповів 413 — знижуємо разом із шириною
	qint64 preview_busy_since_ms_ = 0;                       // запобіжник: вікно не відповіло — через 8 с питаємо знову
	int preview_errors_ = 0;                                 // помилок надсилання поспіль (для журналу)
	quint32 idr_sent_ = 0, decode_errors_sent_ = 0;          // К14: лічильники трансляції на момент минулого heartbeat
	void updateBeatInterval();                               // поки адмін дивиться гру, heartbeat раз на 5 с (щоб швидше дізнаватись про запити)
	// «Грати тут»
	bool can_takeover_ = false;
	int other_seen_ = -1;
	bool takeover_busy_ = false;                             // запит на сервер іще йде
	QString takeover_from_;
	qint64 takeover_until_ms_ = 0;                           // до коли повторювати підключення (час цього комп'ютера)
	int takeover_tries_ = 0;
	QTimer takeover_timer;
	QString moved_text_;
	void takeoverConnect();
	void takeoverFinish(const QString &failText);
	void sendStoppedBeat();                                  // програма закривається посеред гри: «стрім не йде» одразу
	qint64 log_sent_ms_ = 0, log_admin_ms_ = 0;              // журнал: коли надсилали після помилки і на прохання адміна
	bool complaint_ = false;                                 // клієнт натиснув «Картинка глючить» (піде в наступні stats)
};
