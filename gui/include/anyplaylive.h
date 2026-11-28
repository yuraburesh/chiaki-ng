// AnyPlay 116–118: трансляція гри друзям (Cloudflare Realtime SFU через наш сервер), голос, чат, допомога друга.
// Для QML: Chiaki.live. Медіа (пересилання, WebRTC) — у anyplaylivemedia.*, тут — стан, сервер, правила.
// Сервер: scratchpad/team7/контракт.md (/api/live/*), методи для QML: scratchpad/team8/контракт-трансляція.md.
//
// Головне правило (118): гравцю нічого не заважає. Трансляція нічого не розкодовує й не кодує: глядачі отримують
// ті самі стиснені кадри H.264/H.265 і пакети Opus, що прийшли з PS5 (див. anyplaylivemedia.h). Якість і кадри —
// як у гравця. Ефір сам не стає на паузу й не знижує якість: зупиняє його лише гравець, а якщо зник інтернет —
// трансляція чекає й повертається сама. Чи потягне вихідний інтернет — перевіряємо ДО старту.
#pragma once

#include <QObject>
#include <QElapsedTimer>
#include <QHash>
#include <QJsonObject>
#include <QPointer>
#include <QSet>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include <atomic>
#include <functional>
#include <memory>

#include <chiaki/controller.h>

class AnyPlayCloud;
class QmlBackend;
class StreamSession;
class QNetworkAccessManager;
struct AnyPlayLiveMedia;

class AnyPlayLive : public QObject
{
	Q_OBJECT
	Q_PROPERTY(bool supported READ supported NOTIFY changed)
	Q_PROPERTY(QString unsupportedText READ unsupportedText NOTIFY changed)
	Q_PROPERTY(QVariantMap features READ features NOTIFY changed)     // з /api/live/config: live, helper, handoff, friends, gifts
	Q_PROPERTY(QString state READ state NOTIFY changed)               // off | checking | starting | live | reconnecting | error
	Q_PROPERTY(QString statusText READ statusText NOTIFY changed)
	Q_PROPERTY(QString quality READ quality NOTIFY changed)           // "game": глядачі бачать гру такою ж, як гравець
	Q_PROPERTY(bool gameAudio READ gameAudio NOTIFY changed)
	Q_PROPERTY(bool micOn READ micOn NOTIFY changed)
	Q_PROPERTY(int micVolume READ micVolume NOTIFY changed)           // 0…200, 100 — як є
	Q_PROPERTY(bool voicesOn READ voicesOn NOTIFY changed)
	Q_PROPERTY(int voiceVolume READ voiceVolume NOTIFY changed)       // 0…100
	Q_PROPERTY(QString encoderName READ encoderName NOTIFY changed)   // "" — нічого не кодуємо (лишено для старого QML)
	Q_PROPERTY(int liveFps READ liveFps NOTIFY changed)               // кадрів/с, що йдуть глядачам
	Q_PROPERTY(int liveKbps READ liveKbps NOTIFY changed)             // кбіт/с, що йдуть глядачам (вихідний інтернет)
	Q_PROPERTY(int liveHeight READ liveHeight NOTIFY changed)
	// гра зараз (те, що трансляція пересилатиме): кодек, потік, кадри
	Q_PROPERTY(QString gameCodec READ gameCodec NOTIFY gameChanged)   // "H.264" | "H.265" | ""
	Q_PROPERTY(int gameKbps READ gameKbps NOTIFY gameChanged)         // середнє за 10 с
	Q_PROPERTY(int gameFps READ gameFps NOTIFY gameChanged)
	Q_PROPERTY(int needKbps READ needKbps NOTIFY gameChanged)         // скільки вихідного інтернету треба трансляції
	Q_PROPERTY(int uplinkKbps READ uplinkKbps NOTIFY changed)         // остання перевірка (−1 — не міряли)
	Q_PROPERTY(bool viewersLag READ viewersLag NOTIFY changed)        // вихідний канал не встигає: у глядачів картинка завмирає
	Q_PROPERTY(bool compatVideo READ compatVideo NOTIFY gameChanged)  // «Відео для всіх браузерів»: гра в H.264
	Q_PROPERTY(bool compatPending READ compatPending NOTIFY gameChanged)   // увімкнено, але діє з наступного підключення гри
	Q_PROPERTY(QString browserNote READ browserNote NOTIFY gameChanged)    // хто з глядачів побачить відео (для H.265)
	Q_PROPERTY(QString roomId READ roomId NOTIFY changed)             // номер кімнати на сервері (рядком)
	Q_PROPERTY(QString code READ code NOTIFY changed)                 // код кімнати («AB3K9M»)
	Q_PROPERTY(QString link READ link NOTIFY changed)                 // посилання для Telegram (міні-застосунок)
	Q_PROPERTY(QString webLink READ webLink NOTIFY changed)           // посилання для браузера (watch.html)
	Q_PROPERTY(QString botLink READ botLink NOTIFY changed)
	Q_PROPERTY(QString qr READ qr NOTIFY changed)                     // адреса картинки QR, якщо сервер дасть ("" — малюйте самі з link)
	Q_PROPERTY(int viewerLimit READ viewerLimit NOTIFY changed)
	Q_PROPERTY(QVariantList viewers READ viewers NOTIFY viewersChanged)
	Q_PROPERTY(int viewerCount READ viewerCount NOTIFY viewersChanged)
	Q_PROPERTY(QVariantList chat READ chat NOTIFY chatChanged)
	Q_PROPERTY(int chatUnread READ chatUnread NOTIFY chatChanged)
	Q_PROPERTY(qint64 controlUid READ controlUid NOTIFY controlChanged)       // memberId того, кому дано керування (0 — нікому)
	Q_PROPERTY(QString controlName READ controlName NOTIFY controlChanged)
	Q_PROPERTY(bool controlActive READ controlActive NOTIFY controlChanged)   // від друга справді йде ввід (останні 0,5 с)
	Q_PROPERTY(QString handoverState READ handoverState NOTIFY controlChanged)   // "" | ready | active
	Q_PROPERTY(QString handoverName READ handoverName NOTIFY controlChanged)
	Q_PROPERTY(bool handedOver READ handedOver NOTIFY controlChanged)        // гру повністю передано другові
	Q_PROPERTY(QVariantMap offer READ offer NOTIFY controlChanged)           // для друга: {id, from, state, until, waiting, roomId}
	Q_PROPERTY(QString takeBackKey READ takeBackKey CONSTANT)                // чим забрати керування в грі

public:
	AnyPlayLive(AnyPlayCloud *cloud, QmlBackend *backend, QObject *parent = nullptr);
	~AnyPlayLive() override;

	static AnyPlayLive *instance();

	// ── гачки з потоків chiaki (дешеві; коли трансляції нема — лічильник байтів і погляд на перший байт) ──
	// кожен зразок відео, що йде в декодер (заголовок SPS/PPS або кадр), — як є, стиснений
	static void tapVideoSample(const uint8_t *data, size_t size);
	// звук гри: заголовок (канали, частота, тривалість пакета) і кожен пакет Opus з PS5 (size 0 — втрачений)
	static void tapGameAudioHeader(unsigned channels, unsigned rate, unsigned frameSize);
	static void tapGameOpus(const uint8_t *data, size_t size);
	// StreamSessionConnectInfo: гравець обрав «Відео для всіх браузерів» — гра в H.264 замість H.265
	static bool compatVideoWanted();

	// StreamSession (головний потік), перед chiaki_session_set_controller_state: поки керує друг — його стан;
	// PS гравця миттєво забирає керування. Повертає true, якщо стан замінено.
	bool filterControllerState(ChiakiControllerState *state);

	// AnyPlayCloud: поля «live*» для К14 (за проміжок між heartbeat) і поля відповідей сервера
	// (/api/app/session, heartbeat: handoffOffer, handoff)
	QJsonObject takeHeartbeatStats();
	void applyServerHint(const QJsonObject &o);

	bool supported() const;
	QString unsupportedText() const { return unsupported_text_; }
	QVariantMap features() const { return features_; }
	QString state() const { return hidden_ ? QStringLiteral("off") : state_; }
	QString statusText() const { return status_text_; }
	QString quality() const { return quality_; }
	bool gameAudio() const { return game_audio_; }
	bool micOn() const { return mic_on_; }
	int micVolume() const { return mic_volume_; }
	bool voicesOn() const { return voices_on_; }
	int voiceVolume() const { return voice_volume_; }
	QString encoderName() const { return QString(); }
	QString gameCodec() const;
	int gameKbps() const { return game_kbps_; }
	int gameFps() const { return game_fps_; }
	int needKbps() const;
	int uplinkKbps() const { return uplink_kbps_; }
	bool viewersLag() const { return viewers_lag_; }
	bool compatVideo() const { return compat_video_; }
	bool compatPending() const;
	QString browserNote() const;
	int liveFps() const { return live_fps_; }
	int liveKbps() const { return live_kbps_; }
	int liveHeight() const { return live_height_; }
	QString roomId() const { return room_id_; }
	QString code() const { return hidden_ ? QString() : code_; }
	QString link() const { return link_; }
	QString webLink() const { return web_link_; }
	QString botLink() const { return bot_link_; }
	QString qr() const { return qr_; }
	int viewerLimit() const { return viewer_limit_; }
	QVariantList viewers() const { return hidden_ ? QVariantList() : viewers_; }
	int viewerCount() const { return hidden_ ? 0 : viewers_.size(); }
	QVariantList chat() const { return hidden_ ? QVariantList() : chat_; }
	int chatUnread() const { return hidden_ ? 0 : chat_unread_; }
	qint64 controlUid() const { return control_member_; }
	QString controlName() const { return control_name_; }
	bool controlActive() const { return remote_active_; }
	QString handoverState() const { return handoff_state_; }
	QString handoverName() const { return handoff_name_; }
	bool handedOver() const { return handed_over_; }
	QVariantMap offer() const { return offer_; }
	QString takeBackKey() const { return tr("PS на геймпаді або клавіша, що дає PS (P)"); }

	Q_INVOKABLE void loadConfig();
	Q_INVOKABLE void start(const QString &quality = QStringLiteral("720p"), bool gameAudio = true);
	Q_INVOKABLE void stop();
	/** 156: адмін дивиться гру клієнта (сервер: preview.live) — прихована трансляція лише для нього; false — закрити */
	void adminWatch(bool on);
	Q_INVOKABLE void setQuality(const QString &quality);
	Q_INVOKABLE void setGameAudio(bool on);
	Q_INVOKABLE void setMicOn(bool on);
	Q_INVOKABLE void setMicVolume(int volume);
	Q_INVOKABLE void setVoicesOn(bool on);
	Q_INVOKABLE void setVoiceVolume(int volume);
	Q_INVOKABLE void sendChat(const QString &text);
	Q_INVOKABLE void markChatRead();
	Q_INVOKABLE void kick(qint64 uid);                            // uid = memberId із viewers
	Q_INVOKABLE void muteViewer(qint64 uid, bool muted = true);   // не чути цього глядача (лише в гравця)
	Q_INVOKABLE void invite(qint64 friendUserId);                 // id друга (зі списку друзів): сповіщення в боті
	Q_INVOKABLE void grantControl(qint64 uid);                    // uid = memberId
	Q_INVOKABLE void takeControl();                               // «Забрати керування» (миттєво)
	Q_INVOKABLE void prepareHandover(qint64 uid);                 // заздалегідь (друг отримує ключі); uid = memberId
	Q_INVOKABLE void handoverFull(qint64 uid);                    // «Передати повністю» (prepare, якщо ще ні, і start)
	Q_INVOKABLE void cancelHandover();                            // підготовлену, ще не почату
	Q_INVOKABLE void returnFull();                                // «Повернути собі»
	Q_INVOKABLE void acceptHandover(const QString &id = QString());   // друг: «Грати» (одразу, якщо вже передано; інакше чекати)
	Q_INVOKABLE void setWatching(const QString &code);            // друг відкрив/закрив («») перегляд у програмі
	Q_INVOKABLE void setCompatVideo(bool on);                     // «Відео для всіх браузерів» (діє з наступного підключення гри)
	Q_INVOKABLE void holdForReconnect(int seconds = 120);         // гра зараз перепідключиться (за згодою гравця): ефір чекає

signals:
	void changed();
	void gameChanged();
	void viewersChanged();
	void chatChanged();
	void controlChanged();
	void message(const QString &text);
	void chatMessage(const QVariantMap &m);

private:
	using Done = std::function<void(bool ok, int status, const QJsonObject &o)>;
	void api(const char *path, QJsonObject body, Done done);
	void apiGet(const char *path, Done done);
	QString errorText(int status, const QJsonObject &o, const QString &fallback) const;

	void setState(const QString &state, const QString &text = QString());
	void say(const QString &text) { if(!hidden_) emit message(text); }
	void prepareStart();
	bool hidden_ = false;   // 156: прихована трансляція для перегляду адміном (гравець її не бачить)
	void fail(const QString &text);
	void teardown(bool tellServer);
	void checkUplink();
	void uplinkResult(int kbps, const QString &why);
	void beginServer();
	void negotiatePublish();
	void openChannels();
	void goLive();
	// інтернет зник / гра перепідключається: ефір чекає й повертається сам
	void enterReconnecting(const QString &text);
	void scheduleRepublish(int delayMs);
	void republish();
	void requestKeyframe(const char *why);
	void gameTick();

	// черга змін сесії SFU: кожна зміна (з її offer/answer) завершується до початку наступної
	void enqueue(std::function<void(std::function<void()> next)> op);
	void runQueue();
	void whenGathered(std::function<void()> cb);
	void waitFor(std::function<bool()> cond, int timeoutMs, std::function<void(bool)> done);
	void answerSfuOffer(const QJsonObject &o, std::function<void(bool)> done);

	void poll();
	void applyRoomState(const QJsonObject &o);
	bool rebuildViewers();
	void reconcileVoices();
	void subscribeVoice(qint64 member, const QString &sessionId);
	void closeVoice(const QString &mid);

	void onInputPacket(const QByteArray &data);
	void sendEvent(const QJsonObject &m);
	void sendHello();
	void addChat(const QJsonObject &c);
	void releaseRemote(bool tellServer);
	void pokeSession();
	void pushState(const QJsonObject &fields);

	void statsTick();
	void updateStatusText();

	void openMic();
	void closeMic();
	void openVoiceOut();
	void closeVoiceOut();
	void pollHandoff();
	void applyHandoff(const QJsonObject &h);
	void startHandoff(qint64 handoffId);

	AnyPlayCloud *cloud_ = nullptr;
	QmlBackend *backend_ = nullptr;
	QPointer<StreamSession> session_;
	std::unique_ptr<AnyPlayLiveMedia> media_;

	QVariantMap features_;
	QString state_ = QStringLiteral("off");
	QString status_text_;
	QString unsupported_text_;
	QString quality_ = QStringLiteral("720p");
	bool game_audio_ = true;
	bool mic_on_ = false;
	int mic_volume_ = 100;
	bool voices_on_ = true;
	int voice_volume_ = 80;
	int live_fps_ = 0, live_kbps_ = 0, live_height_ = 0;
	quint32 generation_ = 0;   // кожен старт — нове покоління: відповіді від старого ігноруються
	quint32 pub_gen_ = 0;      // кожне з'єднання з SFU (перше й після обриву) — своє покоління

	// гра (для перевірки до старту й для меню)
	int game_kbps_ = 0, game_fps_ = 0, game_peak_kbps_ = 0;
	QList<qint64> game_bytes_hist_;   // байти відео+звуку за кожну секунду, до 10
	qint64 game_bytes_last_ = 0;
	int game_frames_last_ = 0;
	QString game_codec_;
	bool compat_video_ = false;
	QTimer game_timer_;

	// перевірка вихідного інтернету до старту
	int uplink_kbps_ = -1;
	qint64 uplink_at_ms_ = 0;
	int pace_kbps_ = 0;
	QNetworkAccessManager *nam_ = nullptr;

	// обрив / перепідключення
	bool ever_live_ = false;          // цей ефір уже йшов: помилки далі — привід чекати, а не вимикати
	bool republish_busy_ = false;
	int republish_tries_ = 0;
	qint64 last_poll_ok_ms_ = 0;
	qint64 session_error_ms_ = 0;     // гра щойно завершилась з помилкою (зв'язок)
	qint64 hold_until_ms_ = 0;        // чекаємо нову сесію гри до цього часу
	quint32 header_gen_seen_ = 0;
	QTimer republish_timer_, disconnect_timer_;
	bool viewers_lag_ = false;
	int last_overflows_ = 0;
	QList<qint64> overflow_times_;
	qint64 last_key_ms_ = 0;
	bool key_pending_ = false;
	int key_requests_ = 0;

	QString token_;            // токен учасника-гравця (з /api/live/start)
	QString room_id_, code_, link_, web_link_, bot_link_, qr_, session_id_;
	qint64 my_member_ = 0;
	int viewer_limit_ = 5;
	QStringList ice_urls_;
	int input_channel_ = -1, events_channel_ = -1;
	qint64 last_chat_id_ = -1;

	struct Member
	{
		qint64 id = 0, userId = 0;
		QString name, role, sessionId;
		bool isFriend = false, muted = false, hasVoice = false;
		QString voiceMid;
		bool voicePending = false;
	};
	QHash<qint64, Member> people_;
	QSet<qint64> muted_;
	QVariantList viewers_;
	QVariantList chat_;
	int chat_unread_ = 0;

	// керування другом
	qint64 control_member_ = 0;
	quint32 control_gen_ = 0;
	QString control_name_;
	bool remote_active_ = false;
	ChiakiControllerState remote_state_ = {};
	quint16 remote_seq_ = 0;
	bool remote_seq_valid_ = false;
	QElapsedTimer remote_last_;
	bool swallow_ps_ = false;
	QTimer remote_watchdog_, hello_timer_;

	// «передати повністю»
	qint64 handoff_id_ = 0;
	qint64 handoff_member_ = 0;
	QString handoff_state_, handoff_name_;
	bool handed_over_ = false;
	bool handoff_start_pending_ = false;
	QVariantMap offer_;
	bool accept_waiting_ = false;
	QString watching_code_;
	QTimer handoff_timer_;

	// черга SFU
	QList<std::function<void(std::function<void()>)>> ops_;
	bool op_busy_ = false;
	QList<std::function<void()>> gathered_waiters_;

	QTimer poll_timer_, stats_timer_, connect_timer_;
	qint64 last_stats_ms_ = 0;
	int last_frames_ = 0;
	qint64 last_bytes_ = 0;

	// К14 за проміжок
	struct Beat
	{
		int seconds = 0, fps_sum = 0, kbps_sum = 0, reconnect_s = 0, skipped = 0, overflows = 0, keys = 0, rtt_max = 0;
	} beat_;
};
