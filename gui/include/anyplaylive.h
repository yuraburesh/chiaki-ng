// AnyPlay 116: трансляція гри друзям (Cloudflare Realtime SFU через наш сервер), голос, чат, допомога друга.
// Для QML: Chiaki.live. Медіа (кодування, WebRTC) — у anyplaylivemedia.*, тут — стан, сервер, правила.
// Сервер: scratchpad/team7/контракт.md (/api/live/*), методи для QML: scratchpad/team7/контракт-трансляція.md.
//
// Головне правило: гравцю нічого не заважає. Трансляція не торкається з'єднання з PS5, кадри береться
// копією-посиланням не частіше потрібного, кодування — в окремому потоці з низьким пріоритетом, а якщо гра
// в гравця почала страждати, трансляція сама знижує якість і далі стає на паузу.
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

struct AVFrame;
class AnyPlayCloud;
class QmlBackend;
class StreamSession;
struct AnyPlayLiveMedia;

class AnyPlayLive : public QObject
{
	Q_OBJECT
	Q_PROPERTY(bool supported READ supported NOTIFY changed)
	Q_PROPERTY(QString unsupportedText READ unsupportedText NOTIFY changed)
	Q_PROPERTY(QVariantMap features READ features NOTIFY changed)     // з /api/live/config: live, helper, handoff, friends, gifts
	Q_PROPERTY(QString state READ state NOTIFY changed)               // off | starting | live | paused | error
	Q_PROPERTY(QString statusText READ statusText NOTIFY changed)
	Q_PROPERTY(QString quality READ quality NOTIFY changed)           // 540p | 720p
	Q_PROPERTY(bool gameAudio READ gameAudio NOTIFY changed)
	Q_PROPERTY(bool micOn READ micOn NOTIFY changed)
	Q_PROPERTY(int micVolume READ micVolume NOTIFY changed)           // 0…200, 100 — як є
	Q_PROPERTY(bool voicesOn READ voicesOn NOTIFY changed)
	Q_PROPERTY(int voiceVolume READ voiceVolume NOTIFY changed)       // 0…100
	Q_PROPERTY(QString encoderName READ encoderName NOTIFY changed)
	Q_PROPERTY(int liveFps READ liveFps NOTIFY changed)
	Q_PROPERTY(int liveKbps READ liveKbps NOTIFY changed)
	Q_PROPERTY(int liveHeight READ liveHeight NOTIFY changed)
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

	// ── гачки з інших потоків (дешеві, коли трансляції нема: одна атомарна перевірка) ──
	static void tapVideoFrame(const AVFrame *frame);   // QmlMainWindow::presentFrame
	static void tapGameAudio(const int16_t *pcm, size_t frames, unsigned channels);   // StreamSession::PushAudioFrame (48 кГц)

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
	QString state() const { return state_; }
	QString statusText() const { return status_text_; }
	QString quality() const { return quality_; }
	bool gameAudio() const { return game_audio_; }
	bool micOn() const { return mic_on_; }
	int micVolume() const { return mic_volume_; }
	bool voicesOn() const { return voices_on_; }
	int voiceVolume() const { return voice_volume_; }
	QString encoderName() const { return encoder_name_; }
	int liveFps() const { return live_fps_; }
	int liveKbps() const { return live_kbps_; }
	int liveHeight() const { return live_height_; }
	QString roomId() const { return room_id_; }
	QString code() const { return code_; }
	QString link() const { return link_; }
	QString webLink() const { return web_link_; }
	QString botLink() const { return bot_link_; }
	QString qr() const { return qr_; }
	int viewerLimit() const { return viewer_limit_; }
	QVariantList viewers() const { return viewers_; }
	int viewerCount() const { return viewers_.size(); }
	QVariantList chat() const { return chat_; }
	int chatUnread() const { return chat_unread_; }
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

signals:
	void changed();
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
	void fail(const QString &text);
	void teardown(bool tellServer);
	void onEncoderStatus(bool ok, const QString &encoder, const QString &err);
	void beginServer();
	void negotiatePublish();
	void openChannels();
	void goLive();

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

	void adaptTick();
	void applyLevel(int level, const char *why);
	void setPaused(bool paused, const QString &reason);
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
	QString encoder_name_;
	int live_fps_ = 0, live_kbps_ = 0, live_height_ = 0;
	quint32 generation_ = 0;   // кожен старт — нове покоління: відповіді від старого ігноруються

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

	QTimer poll_timer_, adapt_timer_, connect_timer_;

	// адаптація
	int level_ = 0, start_level_ = 0;
	int bad_streak_ = 0, good_streak_ = 0;
	qint64 up_blocked_until_ms_ = 0, last_up_ms_ = 0, last_stats_ms_ = 0;
	bool paused_ = false;
	QString pause_reason_;
	double base_loss_ = 0;
	int base_samples_ = 0;
	int last_pipe_dropped_ = 0, last_frames_ = 0;
	qint64 last_bytes_ = 0;

	// К14 за проміжок
	struct Beat
	{
		int seconds = 0, fps_sum = 0, kbps_sum = 0, enc_us_max = 0, paused_s = 0, level_max = 0, downs = 0;
	} beat_;
};
