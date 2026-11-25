// AnyPlay 116: трансляція гри друзям. Див. anyplaylive.h, scratchpad/team7/контракт.md (сервер)
// і scratchpad/team7/контракт-трансляція.md (методи для QML).
#include "anyplaylive.h"
#include "anyplaycloud.h"
#include "anyplayupdater.h"
#include "qmlbackend.h"
#include "qmlmainwindow.h"
#include "streamsession.h"

#include <QCoreApplication>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSettings>
#include <QtEndian>
#include <QtGlobal>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>

#ifdef ANYPLAY_HAVE_LIVE
#include "anyplaylivemedia.h"
#include <SDL.h>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#ifdef Q_OS_MACOS
#include "macMicPermission.h"
#endif
#endif

// ───────────── Адреси сервера (контракт.md, п. 2–5) ─────────────
namespace {
const char *const kApiConfig = "/api/live/config";
const char *const kApiStart = "/api/live/start";
const char *const kApiPoll = "/api/live/poll";
const char *const kApiState = "/api/live/state";
const char *const kApiChat = "/api/live/chat";
const char *const kApiControl = "/api/live/control";
const char *const kApiInvite = "/api/live/invite";
const char *const kApiKick = "/api/live/kick";
const char *const kApiStop = "/api/live/stop";
const char *const kApiHandoff = "/api/live/handoff";
const char *const kApiHandoffPrepare = "/api/live/handoff/prepare";
const char *const kApiHandoffStart = "/api/live/handoff/start";
const char *const kApiHandoffReturn = "/api/live/handoff/return";
const char *const kSfuSession = "/api/live/sfu/session";
const char *const kSfuTracks = "/api/live/sfu/tracks";
const char *const kSfuRenegotiate = "/api/live/sfu/renegotiate";
const char *const kSfuTracksClose = "/api/live/sfu/tracks/close";
const char *const kSfuChannels = "/api/live/sfu/datachannels/new";

// назви треків і каналів гравця в SFU (сервер дозволяє лише їх)
const char *const kTrackVideo = "video";
const char *const kTrackGame = "game";
const char *const kTrackMic = "mic";
const char *const kTrackViewerVoice = "voice";
const char *const kChannelInput = "input";     // ввід помічника (canReply), без повторів і без порядку
const char *const kChannelEvents = "events";   // службові повідомлення гравця всім, надійний

const int kPollMs = 2000;          // pollEvery: це ж і «гравець живий» для сервера
const int kInputStaleMs = 500;     // від помічника нічого не було — нейтральний стан
const int kChatMax = 100;

// пакет вводу помічника (контракт.md, п. 4.1): 28 байтів, little-endian
const int kInputPacketSize = 28;
const uint8_t kInputMagic = 0xA7;
const uint8_t kInputVersion = 1;

struct Level
{
	int w, h, fps, kbps;
};
// сходинки якості: 0–1 для 720p, з 2 — для 540p; нижче — лише коли гравцеві гірше
const Level kLevels[] = {
	{ 1280, 720, 30, 2500 },
	{ 1280, 720, 30, 1800 },
	{ 960, 540, 30, 1500 },
	{ 960, 540, 24, 1000 },
	{ 960, 540, 15, 700 },
	{ 640, 360, 15, 450 },
};
const int kMaxLevel = int(sizeof(kLevels) / sizeof(kLevels[0])) - 1;

qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }

QString compact(const QJsonObject &o) { return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)); }
}

static AnyPlayLive *g_instance = nullptr;

#ifdef ANYPLAY_HAVE_LIVE
// Усе, що живе в інших потоках. Знищується лише після того, як усі потоки зупинено.
struct AnyPlayLiveMedia
{
	anyplaylive::VideoPipeline video;
	std::mutex peer_mutex;                       // кодування й звук шлють у peer зі своїх потоків
	std::unique_ptr<anyplaylive::Peer> peer;
	anyplaylive::VoiceMixer mixer;
	std::mutex mid_mutex;
	std::map<std::string, std::string> mid_owner;   // mid треку голосу → memberId глядача
	std::atomic<unsigned> remb_kbps{ 0 };

	// звук гри: копія з потоку звуку chiaki, кодування — у своєму потоці
	std::mutex audio_mutex;
	std::condition_variable audio_cv;
	std::deque<std::vector<int16_t>> audio_q;
	bool audio_quit = false;
	std::thread audio_thread;
	anyplaylive::OpusPacker game_opus;
	std::atomic<bool> game_on{ false };

	// мікрофон гравця і голоси глядачів (SDL)
	SDL_AudioDeviceID mic_dev = 0;
	anyplaylive::OpusPacker mic_opus;
	SDL_AudioDeviceID voice_dev = 0;

	void sendAudio(const char *mid, const uint8_t *data, size_t size, int samples)
	{
		std::lock_guard<std::mutex> lock(peer_mutex);
		if(peer)
			peer->sendAudio(mid, data, size, samples);
	}
};

static std::atomic<anyplaylive::VideoPipeline *> g_video{ nullptr };
static std::atomic<int> g_video_inflight{ 0 };
static std::atomic<AnyPlayLiveMedia *> g_audio{ nullptr };
static std::atomic<int> g_audio_inflight{ 0 };

static void SDLCALL liveMicCb(void *user, Uint8 *stream, int len)
{
	auto *m = static_cast<AnyPlayLiveMedia *>(user);
	m->mic_opus.push(reinterpret_cast<const int16_t *>(stream), static_cast<size_t>(len) / 2,
		[m](const uint8_t *d, size_t n, int samples) { m->sendAudio(kTrackMic, d, n, samples); });
}

static void SDLCALL liveVoiceCb(void *user, Uint8 *stream, int len)
{
	auto *m = static_cast<AnyPlayLiveMedia *>(user);
	m->mixer.pull(reinterpret_cast<int16_t *>(stream), static_cast<size_t>(len) / 4);
}

static bool allowSoftwareEncoder()
{
	// лише для перевірок розробника: у клієнтів програмне кодування заборонене (забирало б процесор у гри)
	return qEnvironmentVariableIntValue("ANYPLAY_LIVE_SOFTWARE") == 1;
}
#else
struct AnyPlayLiveMedia
{
};
#endif

AnyPlayLive *AnyPlayLive::instance()
{
	return g_instance;
}

AnyPlayLive::AnyPlayLive(AnyPlayCloud *cloud, QmlBackend *backend, QObject *parent)
	: QObject(parent), cloud_(cloud), backend_(backend)
{
	g_instance = this;
	chiaki_controller_state_set_idle(&remote_state_);
	QSettings st;
	quality_ = st.value(QStringLiteral("anyplay/live_quality"), QStringLiteral("720p")).toString() == QLatin1String("540p")
		? QStringLiteral("540p") : QStringLiteral("720p");
	game_audio_ = st.value(QStringLiteral("anyplay/live_game_audio"), true).toBool();
	mic_on_ = st.value(QStringLiteral("anyplay/live_mic"), false).toBool();
	voices_on_ = st.value(QStringLiteral("anyplay/live_voices"), true).toBool();
	voice_volume_ = qBound(0, st.value(QStringLiteral("anyplay/live_voice_volume"), 80).toInt(), 100);
	mic_volume_ = qBound(0, st.value(QStringLiteral("anyplay/live_mic_volume"), 100).toInt(), 200);

#ifdef ANYPLAY_HAVE_LIVE
	anyplaylive::setLogger([](const std::string &line) {
		qInfo().noquote() << "[anyplay-live]" << QString::fromStdString(line);
	});
#else
	unsupported_text_ = tr("Трансляція не ввійшла в цю збірку програми. Онови програму.");
#endif

	poll_timer_.setInterval(kPollMs);
	connect(&poll_timer_, &QTimer::timeout, this, &AnyPlayLive::poll);
	adapt_timer_.setInterval(1000);
	connect(&adapt_timer_, &QTimer::timeout, this, &AnyPlayLive::adaptTick);
	connect_timer_.setSingleShot(true);
	hello_timer_.setInterval(1000);
	connect(&hello_timer_, &QTimer::timeout, this, &AnyPlayLive::sendHello);
	remote_watchdog_.setInterval(100);
	connect(&remote_watchdog_, &QTimer::timeout, this, [this]() {
		if(!remote_active_)
		{
			remote_watchdog_.stop();
			return;
		}
		// друг загубив зв'язок посеред натискання: нейтральний стан, а керування знову в гравця, доки пакети не підуть
		if(remote_last_.isValid() && remote_last_.elapsed() > kInputStaleMs)
		{
			remote_active_ = false;
			remote_watchdog_.stop();
			chiaki_controller_state_set_idle(&remote_state_);
			pokeSession();
			emit controlChanged();
			qInfo() << "[anyplay-live] helper input silent > 500 ms: neutral state";
		}
	});
	handoff_timer_.setInterval(1500);
	connect(&handoff_timer_, &QTimer::timeout, this, &AnyPlayLive::pollHandoff);
	QTimer::singleShot(2000, this, &AnyPlayLive::loadConfig);

	connect(backend, &QmlBackend::sessionChanged, this, [this](StreamSession *s) {
		session_ = s;
		if(s)
			return;
		// гра закінчилась (бронь, вихід, передали другові): трансляцію вимикаємо
		if(state_ != QLatin1String("off") && state_ != QLatin1String("error"))
		{
			teardown(true);
			emit message(tr("Гра закінчилась, трансляцію вимкнено."));
		}
	});
	session_ = backend->qmlSession();
}

AnyPlayLive::~AnyPlayLive()
{
	teardown(false);
	if(g_instance == this)
		g_instance = nullptr;
}

bool AnyPlayLive::supported() const
{
#ifdef ANYPLAY_HAVE_LIVE
	return unsupported_text_.isEmpty();
#else
	return false;
#endif
}

// ───────────────────────────── гачки з інших потоків ─────────────────────────────

void AnyPlayLive::tapVideoFrame(const AVFrame *frame)
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!g_video.load(std::memory_order_relaxed))
		return;
	g_video_inflight.fetch_add(1);
	anyplaylive::VideoPipeline *p = g_video.load();
	if(p && p->wantsFrame(anyplaylive::nowUs()))
		p->offer(frame);
	g_video_inflight.fetch_sub(1);
#else
	Q_UNUSED(frame);
#endif
}

void AnyPlayLive::tapGameAudio(const int16_t *pcm, size_t frames, unsigned channels)
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!g_audio.load(std::memory_order_relaxed) || !pcm || !frames)
		return;
	g_audio_inflight.fetch_add(1);
	AnyPlayLiveMedia *m = g_audio.load();
	if(m && m->game_on.load(std::memory_order_relaxed))
	{
		std::vector<int16_t> st(frames * 2);
		if(channels == 2)
			memcpy(st.data(), pcm, frames * 2 * sizeof(int16_t));
		else
			for(size_t i = 0; i < frames; i++)
			{
				const int16_t l = pcm[i * (channels ? channels : 1)];
				const int16_t r = channels >= 2 ? pcm[i * channels + 1] : l;
				st[i * 2] = l;
				st[i * 2 + 1] = r;
			}
		{
			std::lock_guard<std::mutex> lock(m->audio_mutex);
			if(m->audio_q.size() < 20)   // ~200 мс; більше — потік кодування не встигає, старе не потрібне
				m->audio_q.push_back(std::move(st));
		}
		m->audio_cv.notify_one();
	}
	g_audio_inflight.fetch_sub(1);
#else
	Q_UNUSED(pcm);
	Q_UNUSED(frames);
	Q_UNUSED(channels);
#endif
}

// ───────────────────────────── ввід друга ─────────────────────────────

bool AnyPlayLive::filterControllerState(ChiakiControllerState *state)
{
	if(!state)
		return false;
	// після «Забрати» кнопкою PS сама PS на приставку не йде, доки її не відпустять
	if(swallow_ps_)
	{
		if(state->buttons & CHIAKI_CONTROLLER_BUTTON_PS)
			state->buttons &= ~CHIAKI_CONTROLLER_BUTTON_PS;
		else
			swallow_ps_ = false;
	}
	if(!control_member_ && !remote_active_)
		return false;
	// PS гравця (геймпад або клавіша, що дає PS) — «Забрати керування»; меню (` і Create 1 с) працює як завжди,
	// бо його розпізнає StreamSession ще до цього шару
	if(state->buttons & CHIAKI_CONTROLLER_BUTTON_PS)
	{
		swallow_ps_ = true;
		takeControl();
		state->buttons &= ~CHIAKI_CONTROLLER_BUTTON_PS;
		return false;
	}
	if(!remote_active_)
		return false;   // керування дано, але від друга нічого не йде: грає гравець
	*state = remote_state_;
	return true;
}

void AnyPlayLive::pokeSession()
{
	if(session_)
		QMetaObject::invokeMethod(session_.data(), "SendFeedbackState", Qt::QueuedConnection);
}

// ───────────────────────────── сервер ─────────────────────────────

void AnyPlayLive::api(const char *path, QJsonObject body, Done done)
{
	// запити кімнати — з токеном учасника; start/handoff/config — лише з токеном пристрою (Bearer, як /api/app/*)
	if(!token_.isEmpty() && !body.contains(QStringLiteral("token")))
		body["token"] = token_;
	QPointer<AnyPlayLive> self(this);
	const QString p = QString::fromLatin1(path);
	cloud_->apiRequest(QStringLiteral("POST"), p, body, [self, done, p](int status, const QJsonObject &o) {
		if(!self)
			return;
		const bool ok = status == 200 && o.value(QStringLiteral("ok")).toBool(true);
		if(!ok && p != QLatin1String(kApiPoll))
			qWarning().noquote() << "[anyplay-live]" << p << "status" << status << o.value(QStringLiteral("error")).toString()
			                     << o.value(QStringLiteral("errorCode")).toString();
		if(done)
			done(ok, status, o);
	});
}

void AnyPlayLive::apiGet(const char *path, Done done)
{
	QPointer<AnyPlayLive> self(this);
	cloud_->apiRequest(QStringLiteral("GET"), QString::fromLatin1(path), QJsonObject(), [self, done](int status, const QJsonObject &o) {
		if(!self)
			return;
		if(done)
			done(status == 200 && o.value(QStringLiteral("ok")).toBool(true), status, o);
	});
}

QString AnyPlayLive::errorText(int status, const QJsonObject &o, const QString &fallback) const
{
	const QString text = o.value(QStringLiteral("text")).toString();
	if(!text.isEmpty())
		return text;
	const QString err = o.value(QStringLiteral("error")).toString();
	if(err == QLatin1String("not_configured"))
		return tr("Трансляції ще не налаштовано.");
	if(err == QLatin1String("disabled"))
		return tr("Трансляції зараз вимкнено.");
	if(err == QLatin1String("not_playing"))
		return tr("Трансляцію можна ввімкнути лише під час своєї гри.");
	if(err == QLatin1String("not_friend"))
		return tr("Це можна лише для друзів. Спершу додай цю людину в друзі.");
	if(status == 404 && err.isEmpty())
		return tr("Сервер поки не вміє трансляцій. Спробуй пізніше.");
	if(status == 0)
		return tr("Немає зв'язку з сервером AnyPlay. Перевір інтернет.");
	return fallback;
}

void AnyPlayLive::loadConfig()
{
	apiGet(kApiConfig, [this](bool ok, int, const QJsonObject &o) {
		if(!ok)
			return;
		const QVariantMap f = o.value(QStringLiteral("features")).toObject().toVariantMap();
		const int limit = o.value(QStringLiteral("maxViewers")).toInt(viewer_limit_);
		if(f != features_ || limit != viewer_limit_)
		{
			features_ = f;
			if(state_ == QLatin1String("off"))
				viewer_limit_ = limit;
			emit changed();
		}
	});
}

// ───────────────────────────── стан ─────────────────────────────

void AnyPlayLive::setState(const QString &state, const QString &text)
{
	state_ = state;
	if(!text.isNull())
		status_text_ = text;
	else
		updateStatusText();
	emit changed();
}

void AnyPlayLive::updateStatusText()
{
	if(state_ == QLatin1String("live"))
	{
		const int n = viewers_.size();
		status_text_ = n == 0 ? tr("Трансляція йде. Чекаємо на глядачів.")
			: tr("Трансляція йде. Глядачів: %1").arg(n);
		if(level_ > start_level_)
			status_text_ += tr(". Якість знижено, щоб гра не гальмувала");
	}
	else if(state_ == QLatin1String("paused"))
		status_text_ = pause_reason_.isEmpty() ? tr("Трансляцію призупинено.") : pause_reason_;
	else if(state_ == QLatin1String("off"))
		status_text_ = handed_over_ ? tr("Гру передано. Тепер грає: %1").arg(handoff_name_) : QString();
}

void AnyPlayLive::fail(const QString &text)
{
	teardown(!token_.isEmpty());
	setState(QStringLiteral("error"), text);
	emit message(text);
}

void AnyPlayLive::start(const QString &quality, bool gameAudio)
{
#ifndef ANYPLAY_HAVE_LIVE
	Q_UNUSED(quality);
	Q_UNUSED(gameAudio);
	emit message(unsupported_text_);
#else
	if(state_ != QLatin1String("off") && state_ != QLatin1String("error"))
		return;
	if(!backend_->qmlSession())
	{
		emit message(tr("Трансляцію можна ввімкнути під час гри."));
		return;
	}
	quality_ = quality == QLatin1String("540p") ? QStringLiteral("540p") : QStringLiteral("720p");
	game_audio_ = gameAudio;
	QSettings st;
	st.setValue(QStringLiteral("anyplay/live_quality"), quality_);
	st.setValue(QStringLiteral("anyplay/live_game_audio"), game_audio_);

	generation_++;
	setState(QStringLiteral("starting"), tr("Готуємо трансляцію…"));
	media_ = std::make_unique<AnyPlayLiveMedia>();
	start_level_ = level_ = quality_ == QLatin1String("540p") ? 2 : 0;
	paused_ = false;
	bad_streak_ = good_streak_ = 0;
	up_blocked_until_ms_ = last_up_ms_ = last_stats_ms_ = 0;
	base_loss_ = 0;
	base_samples_ = 0;
	last_frames_ = last_pipe_dropped_ = 0;
	last_bytes_ = 0;
	last_chat_id_ = -1;
	const Level &l = kLevels[level_];
	anyplaylive::VideoConfig cfg;
	cfg.width = l.w;
	cfg.height = l.h;
	cfg.fps = l.fps;
	cfg.kbps = l.kbps;
	live_height_ = l.h;
	AnyPlayLiveMedia *m = media_.get();
	const quint32 gen = generation_;
	QPointer<AnyPlayLive> self(this);
	m->video.setPaused(true);   // кадри беремо лише тоді, коли є куди слати
	m->video.start(cfg, allowSoftwareEncoder(),
		[m](const std::vector<uint8_t> &au, bool, int64_t capture_us) {
			std::lock_guard<std::mutex> lock(m->peer_mutex);
			if(m->peer)
				m->peer->sendVideo(au, capture_us);
		},
		[self, gen](bool ok, const std::string &encoder, const std::string &err) {
			const QString enc = QString::fromStdString(encoder), e = QString::fromStdString(err);
			QMetaObject::invokeMethod(QCoreApplication::instance(), [self, gen, ok, enc, e]() {
				if(self && self->generation_ == gen)
					self->onEncoderStatus(ok, enc, e);
			}, Qt::QueuedConnection);
		});
	g_video.store(&m->video);

	// весь запуск не довше 30 с
	connect_timer_.disconnect();
	connect(&connect_timer_, &QTimer::timeout, this, [this, gen]() {
		if(generation_ == gen && state_ == QLatin1String("starting"))
			fail(tr("Трансляція не запустилась: сервер трансляцій не відповів вчасно. Спробуй ще раз."));
	});
	connect_timer_.start(30000);
	qInfo().noquote() << "[anyplay-live] start quality" << quality_ << "gameAudio" << game_audio_;
#endif
}

void AnyPlayLive::onEncoderStatus(bool ok, const QString &encoder, const QString &err)
{
	if(!ok)
	{
		qWarning().noquote() << "[anyplay-live] no hardware encoder:" << err;
		if(state_ == QLatin1String("starting"))
		{
			unsupported_text_ = tr("На цьому комп'ютері немає апаратного кодувальника відео, тому трансляцію не ввімкнути: "
			                       "кодування процесором забирало б ресурси в гри.");
			fail(unsupported_text_);
		}
		else
			fail(tr("Кодувальник відео зупинився, трансляцію вимкнено."));
		return;
	}
	encoder_name_ = encoder;
	unsupported_text_.clear();
	emit changed();
	if(state_ == QLatin1String("starting") && token_.isEmpty())
		beginServer();
}

void AnyPlayLive::beginServer()
{
	QJsonObject body;
	body["quality"] = quality_;
	body["gameAudio"] = game_audio_;
	body["access"] = QStringLiteral("link");
	const quint32 gen = generation_;
	api(kApiStart, body, [this, gen](bool ok, int status, const QJsonObject &o) {
		if(gen != generation_)
			return;
		token_ = o.value(QStringLiteral("token")).toString();
		if(!ok || token_.isEmpty())
		{
			token_.clear();
			fail(errorText(status, o, tr("Не вдалося почати трансляцію. Спробуй ще раз.")));
			return;
		}
		applyRoomState(o);
		negotiatePublish();
	});
}

static QStringList iceUrls(const QJsonArray &servers)
{
	QStringList out;
	for(const QJsonValue &v : servers)
	{
		const QJsonValue urls = v.toObject().value(QStringLiteral("urls"));
		if(urls.isArray())
			for(const QJsonValue &u : urls.toArray())
				out << u.toString();
		else if(urls.isString())
			out << urls.toString();
	}
	return out;
}

void AnyPlayLive::negotiatePublish()
{
#ifdef ANYPLAY_HAVE_LIVE
	const quint32 gen = generation_;
	api(kSfuSession, QJsonObject(), [this, gen](bool ok, int status, const QJsonObject &o) {
		if(gen != generation_)
			return;
		session_id_ = o.value(QStringLiteral("sessionId")).toString();
		if(!ok || session_id_.isEmpty())
		{
			fail(errorText(status, o, tr("Сервер трансляцій не відповів. Спробуй ще раз.")));
			return;
		}
		ice_urls_ = iceUrls(o.value(QStringLiteral("iceServers")).toArray());
		if(ice_urls_.isEmpty())
			ice_urls_ << QStringLiteral("stun:stun.cloudflare.com:3478");

		AnyPlayLiveMedia *m = media_.get();
		QPointer<AnyPlayLive> self(this);
		auto post = [self, gen](std::function<void(AnyPlayLive *)> f) {
			QMetaObject::invokeMethod(QCoreApplication::instance(), [self, gen, f]() {
				if(self && self->generation_ == gen)
					f(self.data());
			}, Qt::QueuedConnection);
		};
		anyplaylive::Peer::Callbacks cb;
		cb.state = [post](const std::string &s) {
			const QString st = QString::fromStdString(s);
			post([st](AnyPlayLive *me) {
				qInfo().noquote() << "[anyplay-live] peer" << st;
				if(st == QLatin1String("failed") || st == QLatin1String("closed"))
					me->fail(tr("Зв'язок трансляції обірвався. Увімкни трансляцію ще раз."));
			});
		};
		cb.gathered = [post]() {
			post([](AnyPlayLive *me) {
				const auto waiters = me->gathered_waiters_;
				me->gathered_waiters_.clear();
				for(const auto &w : waiters)
					w();
			});
		};
		cb.keyframe = [m]() { m->video.requestKeyframe(); };
		cb.remb = [m](unsigned kbps) { m->remb_kbps.store(kbps); };
		cb.remoteAudio = [m](const std::string &mid, const uint8_t *data, size_t size) {
			std::string who;
			{
				std::lock_guard<std::mutex> lock(m->mid_mutex);
				auto it = m->mid_owner.find(mid);
				if(it == m->mid_owner.end())
					return;
				who = it->second;
			}
			m->mixer.pushOpus(who, data, size);
		};
		cb.binary = [post](int id, const uint8_t *data, size_t size) {
			const QByteArray packet(reinterpret_cast<const char *>(data), static_cast<int>(size));
			post([id, packet](AnyPlayLive *me) {
				if(id == me->input_channel_)
					me->onInputPacket(packet);
			});
		};
		cb.channelState = [post](int id, bool open) {
			post([id, open](AnyPlayLive *me) {
				qInfo().noquote() << "[anyplay-live] channel" << id << (open ? "open" : "closed");
				if(open && id == me->input_channel_ && me->control_member_)
					me->sendHello();
			});
		};
		auto peer = std::make_unique<anyplaylive::Peer>(cb);
		std::vector<std::string> urls;
		for(const QString &u : ice_urls_)
			urls.push_back(u.toStdString());
		std::string err;
		if(!peer->create(urls, &err))
		{
			fail(tr("Не вдалося підготувати з'єднання трансляції (%1).").arg(QString::fromStdString(err)));
			return;
		}
		peer->addVideo(kTrackVideo, kLevels[0].kbps * 2.5);
		peer->addAudio(kTrackGame, 2);   // трек є завжди; коли звук гри вимкнено, по ньому просто нічого не йде
		peer->addAudio(kTrackMic, 1);
		{
			std::lock_guard<std::mutex> lock(m->peer_mutex);
			m->peer = std::move(peer);
		}
		// m=application одразу в першому offer: datachannels/establish не потрібен (контракт.md, п. 3.1)
		m->peer->makeOffer(true);
		whenGathered([this, gen]() {
			if(gen != generation_ || !media_ || !media_->peer)
				return;
			QJsonObject sd;
			sd["type"] = QStringLiteral("offer");
			sd["sdp"] = QString::fromStdString(media_->peer->localSdp());
			QJsonArray tracks;
			for(const char *name : { kTrackVideo, kTrackGame, kTrackMic })
			{
				QJsonObject t;
				t["location"] = QStringLiteral("local");
				t["mid"] = QString::fromLatin1(name);   // mid у нашому SDP збігається з назвою треку
				t["trackName"] = QString::fromLatin1(name);
				tracks.append(t);
			}
			QJsonObject body;
			body["sessionDescription"] = sd;
			body["tracks"] = tracks;
			api(kSfuTracks, body, [this, gen](bool ok, int status, const QJsonObject &o) {
				if(gen != generation_)
					return;
				const QJsonObject answer = o.value(QStringLiteral("sessionDescription")).toObject();
				std::string err;
				if(!ok || answer.value(QStringLiteral("type")).toString() != QLatin1String("answer")
					|| !media_->peer->applyAnswer(answer.value(QStringLiteral("sdp")).toString().toStdString(), &err))
				{
					qWarning().noquote() << "[anyplay-live] publish failed:" << QString::fromStdString(err);
					fail(errorText(status, o, tr("Сервер трансляцій не прийняв відео. Спробуй ще раз.")));
					return;
				}
				for(const QJsonValue &v : o.value(QStringLiteral("tracks")).toArray())
					if(v.toObject().contains(QStringLiteral("errorCode")))
						qWarning().noquote() << "[anyplay-live] track error" << compact(v.toObject());
				// чекаємо з'єднання з SFU (ICE + DTLS), далі канали даних
				waitFor([this]() { return media_ && media_->peer && media_->peer->connected(); }, 15000, [this, gen](bool connected) {
					if(gen != generation_)
						return;
					if(connected)
						openChannels();
					else
						fail(tr("Не вдалося з'єднатися з сервером трансляцій. Можливо, мережа блокує WebRTC."));
				});
			});
		});
	});
#endif
}

void AnyPlayLive::whenGathered(std::function<void()> cb)
{
#ifdef ANYPLAY_HAVE_LIVE
	if(media_ && media_->peer && media_->peer->gatheringComplete())
	{
		QTimer::singleShot(0, this, cb);
		return;
	}
	gathered_waiters_.append(cb);
	// STUN може не відповісти: через 2,5 с шлемо те, що є (SFU сам знаходить шлях до нас)
	const quint32 gen = generation_;
	QTimer::singleShot(2500, this, [this, gen]() {
		if(gen != generation_ || gathered_waiters_.isEmpty())
			return;
		qInfo() << "[anyplay-live] ICE gathering slow, sending partial candidates";
		const auto waiters = gathered_waiters_;
		gathered_waiters_.clear();
		for(const auto &w : waiters)
			w();
	});
#else
	Q_UNUSED(cb);
#endif
}

void AnyPlayLive::waitFor(std::function<bool()> cond, int timeoutMs, std::function<void(bool)> done)
{
	auto *t = new QTimer(this);
	t->setInterval(100);
	auto left = std::make_shared<int>(timeoutMs / 100);
	connect(t, &QTimer::timeout, this, [t, cond, done, left]() {
		const bool ok = cond();
		if(ok || --(*left) <= 0)
		{
			t->stop();
			t->deleteLater();
			done(ok);
		}
	});
	t->start();
}

void AnyPlayLive::answerSfuOffer(const QJsonObject &o, std::function<void(bool)> done)
{
#ifdef ANYPLAY_HAVE_LIVE
	const QJsonObject sd = o.value(QStringLiteral("sessionDescription")).toObject();
	if(sd.value(QStringLiteral("type")).toString() != QLatin1String("offer"))
	{
		done(true);
		return;
	}
	std::string err;
	if(!media_ || !media_->peer || !media_->peer->applyOffer(sd.value(QStringLiteral("sdp")).toString().toStdString(), &err))
	{
		qWarning().noquote() << "[anyplay-live] SFU offer rejected:" << QString::fromStdString(err);
		done(false);
		return;
	}
	const quint32 gen = generation_;
	whenGathered([this, gen, done]() {
		if(gen != generation_ || !media_ || !media_->peer)
			return;
		QJsonObject answer;
		answer["type"] = QStringLiteral("answer");
		answer["sdp"] = QString::fromStdString(media_->peer->localSdp());
		QJsonObject body;
		body["sessionDescription"] = answer;
		api(kSfuRenegotiate, body, [this, gen, done](bool ok, int, const QJsonObject &) {
			if(gen != generation_)
				return;
			done(ok);
		});
	});
#else
	Q_UNUSED(o);
	done(false);
#endif
}

void AnyPlayLive::openChannels()
{
#ifdef ANYPLAY_HAVE_LIVE
	const quint32 gen = generation_;
	QJsonObject input, events;
	input["location"] = QStringLiteral("local");
	input["dataChannelName"] = QString::fromLatin1(kChannelInput);
	events["location"] = QStringLiteral("local");
	events["dataChannelName"] = QString::fromLatin1(kChannelEvents);
	QJsonObject body;
	body["dataChannels"] = QJsonArray{ input, events };
	api(kSfuChannels, body, [this, gen](bool ok, int status, const QJsonObject &o) {
		if(gen != generation_)
			return;
		int in_id = -1, ev_id = -1;
		for(const QJsonValue &v : o.value(QStringLiteral("dataChannels")).toArray())
		{
			const QJsonObject c = v.toObject();
			if(c.contains(QStringLiteral("errorCode")) || !c.contains(QStringLiteral("id")))
				continue;
			const QString name = c.value(QStringLiteral("dataChannelName")).toString();
			if(name == QLatin1String(kChannelInput))
				in_id = c.value(QStringLiteral("id")).toInt(-1);
			else if(name == QLatin1String(kChannelEvents))
				ev_id = c.value(QStringLiteral("id")).toInt(-1);
		}
		// налаштування доставки — як у сервера (policy), типово input: без порядку, без повторів
		const QJsonObject pol = o.value(QStringLiteral("policy")).toObject().value(QLatin1String(kChannelInput)).toObject();
		const bool in_ordered = pol.value(QStringLiteral("ordered")).toBool(false);
		const int in_rexmit = pol.contains(QStringLiteral("maxRetransmits")) ? pol.value(QStringLiteral("maxRetransmits")).toInt(0) : 0;
		if(!ok || in_id < 0 || ev_id < 0 || !media_->peer->openChannel(in_id, kChannelInput, in_ordered, in_rexmit)
			|| !media_->peer->openChannel(ev_id, kChannelEvents, true, -1))
		{
			fail(errorText(status, o, tr("Сервер трансляцій не відкрив канал керування. Спробуй ще раз.")));
			return;
		}
		input_channel_ = in_id;
		events_channel_ = ev_id;
		goLive();
	});
#endif
}

void AnyPlayLive::goLive()
{
#ifdef ANYPLAY_HAVE_LIVE
	connect_timer_.stop();
	AnyPlayLiveMedia *m = media_.get();
	m->mixer.setEnabled(voices_on_);
	m->mixer.setVolume(voice_volume_ / 100.0f);
	for(const qint64 id : std::as_const(muted_))
		m->mixer.setMuted(QString::number(id).toStdString(), true);
	// звук гри: власний потік кодування
	m->game_opus.open(2, 96, false);
	m->audio_quit = false;
	m->audio_thread = std::thread([m]() {
		while(true)
		{
			std::vector<int16_t> chunk;
			{
				std::unique_lock<std::mutex> lock(m->audio_mutex);
				m->audio_cv.wait(lock, [m]() { return m->audio_quit || !m->audio_q.empty(); });
				if(m->audio_quit)
					break;
				chunk = std::move(m->audio_q.front());
				m->audio_q.pop_front();
			}
			m->game_opus.push(chunk.data(), chunk.size() / 2, [m](const uint8_t *d, size_t n, int samples) {
				m->sendAudio(kTrackGame, d, n, samples);
			});
		}
	});
	m->game_on.store(game_audio_);
	g_audio.store(m);
	m->video.setPaused(false);
	m->video.requestKeyframe();
	if(mic_on_)
		openMic();
	poll_timer_.start();
	adapt_timer_.start();
	setState(QStringLiteral("live"));
	QJsonObject st;
	st["paused"] = false;
	st["muted"] = !mic_on_;
	pushState(st);
	poll();
	reconcileVoices();
	emit message(tr("Трансляцію ввімкнено. Надішли друзям посилання."));
	qInfo().noquote() << "[anyplay-live] live room" << room_id_ << "code" << code_ << "encoder" << encoder_name_
	                  << "session" << session_id_;
#endif
}

void AnyPlayLive::teardown(bool tellServer)
{
	generation_++;
	poll_timer_.stop();
	adapt_timer_.stop();
	connect_timer_.stop();
	hello_timer_.stop();
	ops_.clear();
	op_busy_ = false;
	gathered_waiters_.clear();
	if(remote_active_ || control_member_)
	{
		remote_active_ = false;
		chiaki_controller_state_set_idle(&remote_state_);
		pokeSession();
	}
	remote_watchdog_.stop();
	control_member_ = 0;
	control_name_.clear();
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
	{
		if(events_channel_ >= 0 && media_->peer && tellServer)
		{
			QJsonObject bye;
			bye["t"] = QStringLiteral("bye");
			media_->peer->send(events_channel_, compact(bye).toStdString());
		}
		AnyPlayLiveMedia *m = media_.get();
		// спершу від'єднуємо гачки й чекаємо, поки потоки гри вийдуть із них
		g_audio.store(nullptr);
		while(g_audio_inflight.load())
			std::this_thread::yield();
		{
			std::lock_guard<std::mutex> lock(m->audio_mutex);
			m->audio_quit = true;
		}
		m->audio_cv.notify_all();
		if(m->audio_thread.joinable())
			m->audio_thread.join();
		closeMic();
		closeVoiceOut();
		g_video.store(nullptr);
		while(g_video_inflight.load())
			std::this_thread::yield();
		m->video.stop();
		std::unique_ptr<anyplaylive::Peer> peer;
		{
			std::lock_guard<std::mutex> lock(m->peer_mutex);
			peer = std::move(m->peer);
		}
		if(peer)
			peer->close();
		peer.reset();
		media_.reset();
	}
#endif
	if(tellServer && !token_.isEmpty())
	{
		QJsonObject body;
		body["token"] = token_;
		cloud_->apiRequest(QStringLiteral("POST"), QString::fromLatin1(kApiStop), body, [](int, const QJsonObject &) {});
	}
	token_.clear();
	people_.clear();
	if(!viewers_.isEmpty())
	{
		viewers_.clear();
		emit viewersChanged();
	}
	input_channel_ = events_channel_ = -1;
	session_id_.clear();
	room_id_.clear();
	code_.clear();
	link_.clear();
	web_link_.clear();
	bot_link_.clear();
	qr_.clear();
	my_member_ = 0;
	paused_ = false;
	pause_reason_.clear();
	live_fps_ = live_kbps_ = 0;
	state_ = QStringLiteral("off");
	updateStatusText();
	emit controlChanged();
	emit changed();
}

void AnyPlayLive::stop()
{
	if(state_ == QLatin1String("off"))
		return;
	const bool was_error = state_ == QLatin1String("error");
	teardown(!was_error);
	if(!was_error)
		emit message(tr("Трансляцію вимкнено."));
}

// ───────────────────────────── черга змін SFU ─────────────────────────────

void AnyPlayLive::enqueue(std::function<void(std::function<void()>)> op)
{
	ops_.append(std::move(op));
	runQueue();
}

void AnyPlayLive::runQueue()
{
	if(op_busy_ || ops_.isEmpty())
		return;
	op_busy_ = true;
	auto op = ops_.takeFirst();
	const quint32 gen = generation_;
	auto called = std::make_shared<bool>(false);
	op([this, gen, called]() {
		if(*called)
			return;
		*called = true;
		QTimer::singleShot(0, this, [this, gen]() {
			if(gen != generation_)
				return;
			op_busy_ = false;
			runQueue();
		});
	});
}

// ───────────────────────────── кімната (poll раз на 2 с) ─────────────────────────────

void AnyPlayLive::poll()
{
	if(token_.isEmpty())
		return;
	const quint32 gen = generation_;
	QJsonObject body;
	body["after"] = last_chat_id_;
	api(kApiPoll, body, [this, gen](bool ok, int status, const QJsonObject &o) {
		if(gen != generation_)
			return;
		const QString err = o.value(QStringLiteral("error")).toString();
		if(status == 404 || status == 410 || err == QLatin1String("closed"))
		{
			teardown(false);
			emit message(errorText(status, o, tr("Трансляцію завершено.")));
			return;
		}
		if(!ok)
			return;   // тимчасові збої зв'язку трансляцію не зупиняють
		applyRoomState(o);
	});
}

void AnyPlayLive::applyRoomState(const QJsonObject &o)
{
	const QJsonObject room = o.value(QStringLiteral("room")).toObject();
	if(room.isEmpty())
		return;
	if(room.value(QStringLiteral("status")).toString() == QLatin1String("closed")
		&& (state_ == QLatin1String("live") || state_ == QLatin1String("paused")))
	{
		teardown(false);
		emit message(tr("Трансляцію завершено на сервері."));
		return;
	}
	bool any = false;
	auto setStr = [&any](QString &dst, const QString &v) {
		if(dst != v)
		{
			dst = v;
			any = true;
		}
	};
	setStr(room_id_, room.value(QStringLiteral("id")).toVariant().toString());
	setStr(code_, room.value(QStringLiteral("code")).toString());
	setStr(link_, room.value(QStringLiteral("link")).toString());
	setStr(web_link_, room.value(QStringLiteral("webLink")).toString());
	setStr(bot_link_, room.value(QStringLiteral("botLink")).toString());
	setStr(qr_, room.value(QStringLiteral("qr")).toString());
	const int limit = room.value(QStringLiteral("maxViewers")).toInt(viewer_limit_);
	if(limit != viewer_limit_)
	{
		viewer_limit_ = limit;
		any = true;
	}
	const QJsonObject me = o.value(QStringLiteral("me")).toObject();
	if(me.contains(QStringLiteral("memberId")))
		my_member_ = me.value(QStringLiteral("memberId")).toVariant().toLongLong();
	if(o.value(QStringLiteral("features")).isObject())
	{
		const QVariantMap f = o.value(QStringLiteral("features")).toObject().toVariantMap();
		if(f != features_)
		{
			features_ = f;
			any = true;
		}
	}

	// керування: сервер міг забрати його сам (друг вийшов, прибрали з друзів) або це нова видача
	const QJsonValue cv = o.value(QStringLiteral("control"));
	const qint64 ctl = cv.isObject() ? cv.toObject().value(QStringLiteral("memberId")).toVariant().toLongLong() : 0;
	const quint32 gen = static_cast<quint32>(o.value(QStringLiteral("controlGen")).toVariant().toLongLong());
	if(o.contains(QStringLiteral("controlGen")) && (ctl != control_member_ || gen != control_gen_))
	{
		const bool had = control_member_ != 0;
		if(remote_active_ || had)
			releaseRemote(false);
		control_member_ = ctl;
		control_gen_ = gen;
		control_name_ = ctl ? cv.toObject().value(QStringLiteral("name")).toString() : QString();
		remote_seq_valid_ = false;
		if(ctl)
		{
			hello_timer_.start();
			sendHello();
			qInfo().noquote() << "[anyplay-live] control: member" << ctl << "gen" << gen;
		}
		QJsonObject ev;
		ev["t"] = QStringLiteral("control");
		ev["memberId"] = ctl;
		ev["gen"] = static_cast<qint64>(gen);
		sendEvent(ev);
		emit controlChanged();
	}

	// глядачі
	QSet<qint64> seen;
	for(const QJsonValue &v : o.value(QStringLiteral("members")).toArray())
	{
		const QJsonObject mo = v.toObject();
		if(mo.value(QStringLiteral("player")).toBool() || mo.value(QStringLiteral("me")).toBool())
			continue;
		const qint64 id = mo.value(QStringLiteral("memberId")).toVariant().toLongLong();
		if(!id)
			continue;
		seen.insert(id);
		Member &p = people_[id];
		p.id = id;
		p.userId = mo.value(QStringLiteral("userId")).toVariant().toLongLong();
		p.name = mo.value(QStringLiteral("name")).toString();
		p.role = mo.value(QStringLiteral("role")).toString();
		p.isFriend = mo.value(QStringLiteral("friend")).toBool();
		p.muted = mo.value(QStringLiteral("muted")).toBool();
		const QString sid = mo.value(QStringLiteral("sessionId")).toString();
		if(sid != p.sessionId && !p.voiceMid.isEmpty())
		{
			// глядач перепідключився (нова сесія): стара підписка на голос нічого не дасть
			closeVoice(p.voiceMid);
			p.voiceMid.clear();
		}
		p.sessionId = sid;
		p.hasVoice = false;
		for(const QJsonValue &t : mo.value(QStringLiteral("tracks")).toArray())
			if(t.toObject().value(QStringLiteral("trackName")).toString() == QLatin1String(kTrackViewerVoice))
				p.hasVoice = true;
	}
	for(const qint64 id : people_.keys())
		if(!seen.contains(id))
		{
			const Member p = people_.take(id);
			if(!p.voiceMid.isEmpty())
				closeVoice(p.voiceMid);
#ifdef ANYPLAY_HAVE_LIVE
			if(media_)
				media_->mixer.remove(QString::number(id).toStdString());
#endif
		}
	if(rebuildViewers())
		any = true;

	// чат: нові повідомлення
	for(const QJsonValue &v : o.value(QStringLiteral("chat")).toArray())
		addChat(v.toObject());
	if(o.contains(QStringLiteral("lastChatId")))
		last_chat_id_ = qMax(last_chat_id_, o.value(QStringLiteral("lastChatId")).toVariant().toLongLong());

	if(o.value(QStringLiteral("handoff")).isObject())
		applyHandoff(o.value(QStringLiteral("handoff")).toObject());

	if(any)
	{
		updateStatusText();
		emit changed();
	}
	reconcileVoices();
}

bool AnyPlayLive::rebuildViewers()
{
	QVariantList list;
#ifdef ANYPLAY_HAVE_LIVE
	std::vector<std::string> speaking;
	if(media_)
		speaking = media_->mixer.speaking();
#endif
	for(const Member &p : std::as_const(people_))
	{
		QVariantMap m;
		m["uid"] = p.id;   // для QML: це memberId (передавати в grantControl/kick/muteViewer)
		m["memberId"] = p.id;
		m["userId"] = p.userId;
		m["name"] = p.name;
		m["role"] = p.id == control_member_ ? QStringLiteral("helper") : (p.role.isEmpty() ? QStringLiteral("viewer") : p.role);
		m["friend"] = p.isFriend;
		m["mic"] = p.hasVoice && !p.muted;
		m["muted"] = muted_.contains(p.id);
		bool talking = false;
#ifdef ANYPLAY_HAVE_LIVE
		talking = std::find(speaking.begin(), speaking.end(), QString::number(p.id).toStdString()) != speaking.end();
#endif
		m["speaking"] = talking;
		list.append(m);
	}
	if(list == viewers_)
		return false;
	const bool count_changed = list.size() != viewers_.size();
	viewers_ = list;
	emit viewersChanged();
	return count_changed;
}

void AnyPlayLive::reconcileVoices()
{
	if(session_id_.isEmpty() || input_channel_ < 0 || !voices_on_)
		return;
	for(auto it = people_.begin(); it != people_.end(); ++it)
	{
		Member &p = it.value();
		if(p.hasVoice && !p.sessionId.isEmpty() && p.voiceMid.isEmpty() && !p.voicePending)
			subscribeVoice(p.id, p.sessionId);
	}
}

void AnyPlayLive::subscribeVoice(qint64 member, const QString &sessionId)
{
	people_[member].voicePending = true;
	enqueue([this, member, sessionId](std::function<void()> next) {
		if(!people_.contains(member) || !voices_on_ || people_[member].sessionId != sessionId)
		{
			if(people_.contains(member))
				people_[member].voicePending = false;
			next();
			return;
		}
		QJsonObject t;
		t["location"] = QStringLiteral("remote");
		t["sessionId"] = sessionId;
		t["trackName"] = QString::fromLatin1(kTrackViewerVoice);
		QJsonObject body;
		body["tracks"] = QJsonArray{ t };
		const quint32 gen = generation_;
		api(kSfuTracks, body, [this, gen, member, next](bool ok, int, const QJsonObject &o) {
			if(gen != generation_)
				return;
			const QJsonObject r = o.value(QStringLiteral("tracks")).toArray().at(0).toObject();
			const QString mid = r.value(QStringLiteral("mid")).toString();
			if(!ok || mid.isEmpty() || r.contains(QStringLiteral("errorCode")))
			{
				// не вийшло: спробуємо з наступним poll
				QTimer::singleShot(5000, this, [this, gen, member]() {
					if(gen == generation_ && people_.contains(member))
						people_[member].voicePending = false;
				});
				next();
				return;
			}
#ifdef ANYPLAY_HAVE_LIVE
			if(media_)
			{
				std::lock_guard<std::mutex> lock(media_->mid_mutex);
				media_->mid_owner[mid.toStdString()] = QString::number(member).toStdString();
			}
#endif
			answerSfuOffer(o, [this, gen, member, mid, next](bool answered) {
				if(gen != generation_)
					return;
				if(people_.contains(member))
				{
					people_[member].voicePending = false;
					people_[member].voiceMid = answered ? mid : QString();
				}
				if(answered)
					openVoiceOut();
				else
					qWarning().noquote() << "[anyplay-live] voice of" << member << "not negotiated";
				next();
			});
		});
	});
}

void AnyPlayLive::closeVoice(const QString &mid)
{
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
	{
		std::lock_guard<std::mutex> lock(media_->mid_mutex);
		media_->mid_owner.erase(mid.toStdString());
	}
#endif
	if(session_id_.isEmpty())
		return;
	QJsonObject t;
	t["mid"] = mid;
	QJsonObject body;
	body["tracks"] = QJsonArray{ t };
	body["force"] = true;
	enqueue([this, body](std::function<void()> next) {
		api(kSfuTracksClose, body, [next](bool, int, const QJsonObject &) { next(); });
	});
}

// ───────────────────────────── ввід помічника (контракт.md, п. 4.1) ─────────────────────────────

void AnyPlayLive::onInputPacket(const QByteArray &data)
{
	if(!control_member_ || data.size() != kInputPacketSize)
		return;
	const uchar *d = reinterpret_cast<const uchar *>(data.constData());
	if(d[0] != kInputMagic || d[1] != kInputVersion)
		return;
	const quint16 seq = qFromLittleEndian<quint16>(d + 2);
	const quint32 gen = qFromLittleEndian<quint32>(d + 4);
	if(gen != control_gen_)
		return;   // пакет від попередньої видачі керування
	if(remote_seq_valid_ && static_cast<qint16>(seq - remote_seq_) <= 0)
		return;   // старіший (канал без порядку)
	remote_seq_ = seq;
	remote_seq_valid_ = true;
	const quint16 flags = qFromLittleEndian<quint16>(d + 22);
	ChiakiControllerState st;
	chiaki_controller_state_set_idle(&st);
	if(!(flags & 1))   // біт 0 — «відпустити все»
	{
		st.buttons = qFromLittleEndian<quint32>(d + 8) & 0xffffu & ~uint32_t(CHIAKI_CONTROLLER_BUTTON_PS);
		st.left_x = qFromLittleEndian<qint16>(d + 12);
		st.left_y = qFromLittleEndian<qint16>(d + 14);
		st.right_x = qFromLittleEndian<qint16>(d + 16);
		st.right_y = qFromLittleEndian<qint16>(d + 18);
		st.l2_state = d[20];
		st.r2_state = d[21];
	}
	remote_last_.restart();
	if(!remote_active_)
	{
		remote_active_ = true;
		remote_watchdog_.start();
		emit controlChanged();
		qInfo().noquote() << "[anyplay-live] helper input flowing, member" << control_member_ << "gen" << gen;
	}
	if(memcmp(&st, &remote_state_, sizeof(st)) != 0)
	{
		remote_state_ = st;
		pokeSession();
	}
}

void AnyPlayLive::sendHello()
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!control_member_)
	{
		hello_timer_.stop();
		return;
	}
	if(!media_ || !media_->peer || input_channel_ < 0)
		return;
	QJsonObject h;
	h["t"] = QStringLiteral("hello");
	h["gen"] = static_cast<qint64>(control_gen_);
	media_->peer->send(input_channel_, compact(h).toStdString());
#endif
}

void AnyPlayLive::sendEvent(const QJsonObject &m)
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!media_ || !media_->peer || events_channel_ < 0)
		return;
	if(media_->peer->buffered(events_channel_) > 256 * 1024)
		return;   // глядачі не встигають читати: однаково звіряються з poll
	media_->peer->send(events_channel_, compact(m).toStdString());
#else
	Q_UNUSED(m);
#endif
}

void AnyPlayLive::pushState(const QJsonObject &fields)
{
	if(token_.isEmpty())
		return;
	api(kApiState, fields, nullptr);
}

void AnyPlayLive::releaseRemote(bool tellServer)
{
	const bool had = control_member_ || remote_active_;
	remote_active_ = false;
	remote_watchdog_.stop();
	hello_timer_.stop();
	chiaki_controller_state_set_idle(&remote_state_);
	pokeSession();
	if(tellServer && control_member_ && !token_.isEmpty())
	{
		QJsonObject body;
		body["on"] = false;
		api(kApiControl, body, [this](bool ok, int, const QJsonObject &o) {
			if(ok)
				applyRoomState(o);
		});
		QJsonObject ev;
		ev["t"] = QStringLiteral("control");
		ev["memberId"] = 0;
		ev["gen"] = static_cast<qint64>(control_gen_);
		sendEvent(ev);
		control_member_ = 0;
		control_name_.clear();
	}
	if(had)
	{
		rebuildViewers();
		emit controlChanged();
	}
}

void AnyPlayLive::takeControl()
{
	if(!control_member_ && !remote_active_)
		return;
	qInfo() << "[anyplay-live] player took the control back";
	releaseRemote(true);
	emit message(tr("Керування знову в тебе."));
}

void AnyPlayLive::grantControl(qint64 uid)
{
	if((state_ != QLatin1String("live") && state_ != QLatin1String("paused")) || !people_.contains(uid))
		return;
	if(control_member_ == uid)
		return;
	if(control_member_)
		releaseRemote(false);   // сервер передасть право новому сам
	QJsonObject body;
	body["memberId"] = uid;
	body["on"] = true;
	const quint32 gen = generation_;
	api(kApiControl, body, [this, gen, uid](bool ok, int status, const QJsonObject &o) {
		if(gen != generation_)
			return;
		if(!ok)
		{
			emit message(errorText(status, o, tr("Не вдалося передати керування. Спробуй ще раз.")));
			return;
		}
		applyRoomState(o);
		const QJsonObject sfu = o.value(QStringLiteral("sfu")).toObject();
		if(sfu.value(QStringLiteral("granted")).isBool() && !sfu.value(QStringLiteral("granted")).toBool())
			qWarning() << "[anyplay-live] SFU did not grant canReply yet (helper may not be subscribed)";
		if(control_member_ == uid)
			emit message(tr("Керування передано. Керує: %1. Забрати можна кнопкою PS або в меню.").arg(control_name_));
	});
}

// ───────────────────────────── чат (через сервер) ─────────────────────────────

void AnyPlayLive::addChat(const QJsonObject &c)
{
	const qint64 id = c.value(QStringLiteral("id")).toVariant().toLongLong();
	if(id && id <= last_chat_id_)
		return;
	if(id)
		last_chat_id_ = id;
	QVariantMap m;
	m["id"] = id;
	m["uid"] = c.value(QStringLiteral("memberId")).toVariant().toLongLong();
	m["name"] = c.value(QStringLiteral("name")).toString();
	m["text"] = c.value(QStringLiteral("text")).toString();
	m["ts"] = c.value(QStringLiteral("at")).toVariant().toLongLong() * 1000;
	m["role"] = c.value(QStringLiteral("role")).toString();
	const bool mine = my_member_ && m["uid"].toLongLong() == my_member_;
	const bool system = c.value(QStringLiteral("kind")).toString() == QLatin1String("system");
	m["mine"] = mine;
	m["system"] = system;
	chat_.append(m);
	while(chat_.size() > kChatMax)
		chat_.removeFirst();
	if(!mine && !system)
		chat_unread_++;
	emit chatChanged();
	emit chatMessage(m);
}

void AnyPlayLive::sendChat(const QString &text)
{
	const QString t = text.trimmed().left(300);
	if(t.isEmpty() || token_.isEmpty())
		return;
	QJsonObject body;
	body["text"] = t;
	api(kApiChat, body, [this](bool ok, int status, const QJsonObject &o) {
		if(!ok)
		{
			emit message(status == 429 ? tr("Не так швидко: зачекай секунду.") : errorText(status, o, tr("Повідомлення не надіслано.")));
			return;
		}
		if(o.value(QStringLiteral("message")).isObject())
			addChat(o.value(QStringLiteral("message")).toObject());
	});
}

void AnyPlayLive::markChatRead()
{
	if(!chat_unread_)
		return;
	chat_unread_ = 0;
	emit chatChanged();
}

// ───────────────────────────── глядачі ─────────────────────────────

void AnyPlayLive::kick(qint64 uid)
{
	if(token_.isEmpty() || !people_.contains(uid))
		return;
	QJsonObject body;
	body["memberId"] = uid;
	api(kApiKick, body, [this](bool ok, int status, const QJsonObject &o) {
		if(ok)
			applyRoomState(o);
		else
			emit message(errorText(status, o, tr("Не вдалося прибрати глядача.")));
	});
}

void AnyPlayLive::muteViewer(qint64 uid, bool muted)
{
	if(muted)
		muted_.insert(uid);
	else
		muted_.remove(uid);
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
		media_->mixer.setMuted(QString::number(uid).toStdString(), muted);
#endif
	rebuildViewers();
}

void AnyPlayLive::invite(qint64 friendUserId)
{
	if(token_.isEmpty() || !friendUserId)
	{
		emit message(tr("Спершу ввімкни трансляцію, потім запрошуй друзів."));
		return;
	}
	QJsonObject body;
	body["friendIds"] = QJsonArray{ friendUserId };
	api(kApiInvite, body, [this](bool ok, int status, const QJsonObject &o) {
		if(!ok)
		{
			emit message(errorText(status, o, tr("Не вдалося надіслати запрошення.")));
			return;
		}
		const QJsonArray skipped = o.value(QStringLiteral("skipped")).toArray();
		if(!o.value(QStringLiteral("sent")).toArray().isEmpty())
			emit message(tr("Запрошення надіслано в Telegram."));
		else if(!skipped.isEmpty() && skipped.at(0).toObject().value(QStringLiteral("error")).toString() == QLatin1String("rate"))
			emit message(tr("Цьому другові вже надіслано запрошення. Повторити можна за 2 хвилини."));
		else
			emit message(tr("Запросити можна лише друзів."));
	});
}

// ───────────────────────────── «Передати повністю» (контракт.md, п. 5) ─────────────────────────────

void AnyPlayLive::applyHandoff(const QJsonObject &h)
{
	const QString role = h.value(QStringLiteral("role")).toString();
	const QString st = h.value(QStringLiteral("state")).toString();
	const qint64 id = h.value(QStringLiteral("id")).toVariant().toLongLong();
	if(role == QLatin1String("friend"))
	{
		// я — друг: пропозиція або вже передано
		QVariantMap next;
		if(st == QLatin1String("ready") || st == QLatin1String("active"))
		{
			next["id"] = id;
			next["from"] = h.value(QStringLiteral("owner")).toObject().value(QStringLiteral("name")).toString();
			next["state"] = st;
			next["until"] = h.value(QStringLiteral("readyUntil")).toVariant().toLongLong();
			next["waiting"] = accept_waiting_;
			next["roomId"] = watching_code_;   // код кімнати, яку друг зараз дивиться (може бути порожнім)
		}
		if(next != offer_)
		{
			offer_ = next;
			emit controlChanged();
		}
		if(st == QLatin1String("ready") && !handoff_timer_.isActive())
			handoff_timer_.start();   // чекаємо старту: раз на 1,5 с
		if(st == QLatin1String("active") && accept_waiting_)
		{
			accept_waiting_ = false;
			handoff_timer_.stop();
			qInfo() << "[anyplay-live] handoff started by the owner: connecting";
			emit message(tr("Друг передав тобі гру. Підключаємось до приставки…"));
			cloud_->takeover();   // ключі вже в сервера для нас; повтори, поки приставка зайнята, як у «Грати тут»
		}
		if(st != QLatin1String("ready") && !(st == QLatin1String("active") && accept_waiting_))
			handoff_timer_.stop();
		return;
	}
	// я — власник броні
	const QString was = handoff_state_;
	handoff_id_ = id;
	handoff_name_ = h.value(QStringLiteral("friend")).toObject().value(QStringLiteral("name")).toString();
	handoff_state_ = (st == QLatin1String("ready") || st == QLatin1String("active")) ? st : QString();
	const bool active = st == QLatin1String("active");
	if(active != handed_over_)
		handed_over_ = active;
	if(was != handoff_state_)
	{
		updateStatusText();
		emit controlChanged();
		emit changed();
	}
	if(handed_over_ && !handoff_timer_.isActive())
		handoff_timer_.start();
	if(!handed_over_ && handoff_state_.isEmpty())
		handoff_timer_.stop();
}

void AnyPlayLive::pollHandoff()
{
	apiGet(kApiHandoff, [this](bool ok, int status, const QJsonObject &o) {
		if(status == 404)
		{
			handoff_timer_.stop();   // старий сервер
			return;
		}
		if(!ok)
			return;
		const QJsonValue h = o.value(QStringLiteral("handoff"));
		if(h.isObject())
			applyHandoff(h.toObject());
		else
		{
			handoff_timer_.stop();
			if(!offer_.isEmpty())
			{
				offer_.clear();
				emit controlChanged();
			}
			if(handed_over_ || !handoff_state_.isEmpty())
			{
				handed_over_ = false;
				handoff_state_.clear();
				updateStatusText();
				emit controlChanged();
			}
		}
	});
}

void AnyPlayLive::prepareHandover(qint64 uid)
{
	if(!people_.contains(uid) || handed_over_)
		return;
	const Member p = people_.value(uid);
	if(!p.userId || !p.isFriend)
	{
		emit message(tr("Передати гру можна лише другові, що увійшов через Telegram або програму."));
		return;
	}
	QJsonObject body;
	body["friendId"] = p.userId;
	handoff_member_ = uid;
	api(kApiHandoffPrepare, QJsonObject(body), [this](bool ok, int status, const QJsonObject &o) {
		if(!ok)
		{
			handoff_start_pending_ = false;
			emit message(errorText(status, o, tr("Не вдалося підготувати передачу гри. Спробуй ще раз.")));
			return;
		}
		const QJsonObject h = o.value(QStringLiteral("handoff")).toObject();
		applyHandoff(h);
		if(handoff_start_pending_)
		{
			handoff_start_pending_ = false;
			startHandoff(h.value(QStringLiteral("id")).toVariant().toLongLong());
		}
	});
}

void AnyPlayLive::handoverFull(qint64 uid)
{
	if(handed_over_)
		return;
	if(handoff_state_ == QLatin1String("ready") && handoff_member_ == uid && handoff_id_)
	{
		startHandoff(handoff_id_);
		return;
	}
	handoff_start_pending_ = true;
	prepareHandover(uid);
}

void AnyPlayLive::startHandoff(qint64 handoffId)
{
	QJsonObject body;
	if(handoffId)
		body["id"] = handoffId;
	QPointer<AnyPlayLive> self(this);
	cloud_->apiRequest(QStringLiteral("POST"), QString::fromLatin1(kApiHandoffStart), body, [self](int status, const QJsonObject &o) {
		if(!self)
			return;
		if(status != 200 || !o.value(QStringLiteral("ok")).toBool())
		{
			emit self->message(self->errorText(status, o, tr("Не вдалося передати гру. Спробуй ще раз.")));
			return;
		}
		self->applyHandoff(o.value(QStringLiteral("handoff")).toObject());
		self->handed_over_ = true;
		qInfo().noquote() << "[anyplay-live] handoff active, friend" << self->handoff_name_;
		// друг підключається сам; ми відпускаємо приставку без присипляння і вимикаємо свою трансляцію
		self->teardown(true);
		self->handed_over_ = true;
		self->handoff_state_ = QStringLiteral("active");
		self->backend_->stopSession(false);
		self->handoff_timer_.start();
		self->updateStatusText();
		emit self->controlChanged();
		emit self->changed();
		emit self->message(tr("Гру передано. Тепер грає: %1. Повернути собі можна будь-коли.").arg(self->handoff_name_));
	});
}

void AnyPlayLive::cancelHandover()
{
	if(handed_over_ || handoff_state_.isEmpty())
		return;
	handoff_start_pending_ = false;
	api(kApiHandoffReturn, QJsonObject(), [this](bool ok, int, const QJsonObject &o) {
		if(ok && o.value(QStringLiteral("handoff")).isObject())
			applyHandoff(o.value(QStringLiteral("handoff")).toObject());
		handoff_state_.clear();
		emit controlChanged();
	});
}

void AnyPlayLive::returnFull()
{
	if(!handed_over_)
		return;
	// як «Грати тут»: сервер завершує передачу (POST /api/app/session {"takeover":true}) і дає ключі власникові,
	// програма підключається з повторами, поки програма друга не відпустить приставку
	handed_over_ = false;
	handoff_state_.clear();
	handoff_timer_.stop();
	updateStatusText();
	emit controlChanged();
	emit changed();
	emit message(tr("Повертаємо гру тобі…"));
	qInfo() << "[anyplay-live] handoff: owner takes the game back";
	cloud_->takeover();
}

void AnyPlayLive::acceptHandover(const QString &id)
{
	Q_UNUSED(id);
	const QString st = offer_.value(QStringLiteral("state")).toString();
	if(st == QLatin1String("active"))
	{
		accept_waiting_ = false;
		emit message(tr("Підключаємось до приставки…"));
		cloud_->takeover();
		return;
	}
	// ще не передано: чекаємо старту (раз на 1,5 с), далі підключаємось самі
	accept_waiting_ = true;
	offer_["waiting"] = true;
	emit controlChanged();
	handoff_timer_.start();
	pollHandoff();
}

void AnyPlayLive::setWatching(const QString &code)
{
	watching_code_ = code;
	// дивлячись трансляцію друга, дізнаємось про «передати повністю» без чекання на /api/app/session
	if(!code.isEmpty())
		pollHandoff();
}

void AnyPlayLive::applyServerHint(const QJsonObject &o)
{
	// /api/app/session і heartbeat: handoffOffer (другові підготували передачу), handoff (власник або друг)
	if(o.value(QStringLiteral("handoffOffer")).isObject())
		applyHandoff(o.value(QStringLiteral("handoffOffer")).toObject());
	else if(o.value(QStringLiteral("handoff")).isObject())
		applyHandoff(o.value(QStringLiteral("handoff")).toObject());
	else if(o.contains(QStringLiteral("state")) && !offer_.isEmpty() && !accept_waiting_)
	{
		// відповідь /api/app/session без пропозиції: її скасували або час минув
		offer_.clear();
		emit controlChanged();
	}
}

// ───────────────────────────── налаштування ─────────────────────────────

void AnyPlayLive::setQuality(const QString &quality)
{
	const QString q = quality == QLatin1String("540p") ? QStringLiteral("540p") : QStringLiteral("720p");
	if(q == quality_)
		return;
	quality_ = q;
	QSettings().setValue(QStringLiteral("anyplay/live_quality"), quality_);
	start_level_ = quality_ == QLatin1String("540p") ? 2 : 0;
	if(state_ == QLatin1String("live"))
	{
		applyLevel(qMax(start_level_, level_ <= 1 ? start_level_ : level_), "quality");
		QJsonObject st;
		st["quality"] = quality_;
		pushState(st);
		QJsonObject ev;
		ev["t"] = QStringLiteral("quality");
		ev["value"] = quality_;
		sendEvent(ev);
	}
	emit changed();
}

void AnyPlayLive::setGameAudio(bool on)
{
	if(on == game_audio_)
		return;
	game_audio_ = on;
	QSettings().setValue(QStringLiteral("anyplay/live_game_audio"), on);
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
		media_->game_on.store(on && !paused_);
#endif
	QJsonObject st;
	st["gameAudio"] = on;
	pushState(st);
	emit changed();
}

void AnyPlayLive::setMicOn(bool on)
{
	if(on == mic_on_)
		return;
	mic_on_ = on;
	QSettings().setValue(QStringLiteral("anyplay/live_mic"), on);
	if(state_ == QLatin1String("live") || state_ == QLatin1String("paused"))
	{
		if(on)
			openMic();
		else
			closeMic();
		QJsonObject st;
		st["muted"] = !mic_on_;
		pushState(st);
	}
	emit changed();
}

void AnyPlayLive::setVoicesOn(bool on)
{
	if(on == voices_on_)
		return;
	voices_on_ = on;
	QSettings().setValue(QStringLiteral("anyplay/live_voices"), on);
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
		media_->mixer.setEnabled(on);
#endif
	if(on)
		reconcileVoices();
	emit changed();
}

void AnyPlayLive::setVoiceVolume(int volume)
{
	volume = qBound(0, volume, 100);
	if(volume == voice_volume_)
		return;
	voice_volume_ = volume;
	QSettings().setValue(QStringLiteral("anyplay/live_voice_volume"), volume);
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
		media_->mixer.setVolume(volume / 100.0f);
#endif
	emit changed();
}

void AnyPlayLive::setMicVolume(int volume)
{
	volume = qBound(0, volume, 200);
	if(volume == mic_volume_)
		return;
	mic_volume_ = volume;
	QSettings().setValue(QStringLiteral("anyplay/live_mic_volume"), volume);
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
		media_->mic_opus.setGain(volume / 100.0f);
#endif
	emit changed();
}

// ───────────────────────────── звук (SDL) ─────────────────────────────

void AnyPlayLive::openMic()
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!media_ || media_->mic_dev)
		return;
#ifdef Q_OS_MACOS
	static bool asked = false;
	if(!asked)
	{
		asked = true;
		QPointer<AnyPlayLive> self(this);
		macMicPermission([](Authorization a, void *user) {
			Q_UNUSED(user);
			const bool ok = a == AUTHORIZED;
			QMetaObject::invokeMethod(QCoreApplication::instance(), [ok]() {
				AnyPlayLive *me = AnyPlayLive::instance();
				if(!me)
					return;
				if(ok)
					me->openMic();
				else
				{
					me->mic_on_ = false;
					emit me->changed();
					emit me->message(tr("Немає дозволу на мікрофон. Увімкни його: Системні параметри → Приватність і безпека → Мікрофон."));
				}
			}, Qt::QueuedConnection);
		}, nullptr);
		return;
	}
#endif
	SDL_InitSubSystem(SDL_INIT_AUDIO);
	if(!media_->mic_opus.open(1, 32, true))
		return;
	media_->mic_opus.setGain(mic_volume_ / 100.0f);
	SDL_AudioSpec want = {}, have = {};
	want.freq = 48000;
	want.format = AUDIO_S16SYS;
	want.channels = 1;
	want.samples = 960;
	want.callback = liveMicCb;
	want.userdata = media_.get();
	media_->mic_dev = SDL_OpenAudioDevice(nullptr, 1, &want, &have, 0);
	if(!media_->mic_dev)
	{
		qWarning().noquote() << "[anyplay-live] microphone:" << SDL_GetError();
		mic_on_ = false;
		emit changed();
		emit message(tr("Мікрофон не вдалося відкрити. Перевір, чи він під'єднаний."));
		return;
	}
	SDL_PauseAudioDevice(media_->mic_dev, 0);
	qInfo() << "[anyplay-live] microphone on";
#endif
}

void AnyPlayLive::closeMic()
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!media_ || !media_->mic_dev)
		return;
	SDL_CloseAudioDevice(media_->mic_dev);   // чекає, поки колбек закінчиться
	media_->mic_dev = 0;
	media_->mic_opus.close();
#endif
}

void AnyPlayLive::openVoiceOut()
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!media_ || media_->voice_dev)
		return;
	SDL_InitSubSystem(SDL_INIT_AUDIO);
	SDL_AudioSpec want = {}, have = {};
	want.freq = 48000;
	want.format = AUDIO_S16SYS;
	want.channels = 2;
	want.samples = 960;
	want.callback = liveVoiceCb;
	want.userdata = media_.get();
	media_->voice_dev = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
	if(!media_->voice_dev)
	{
		qWarning().noquote() << "[anyplay-live] voice output:" << SDL_GetError();
		return;
	}
	SDL_PauseAudioDevice(media_->voice_dev, 0);
#endif
}

void AnyPlayLive::closeVoiceOut()
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!media_ || !media_->voice_dev)
		return;
	SDL_CloseAudioDevice(media_->voice_dev);
	media_->voice_dev = 0;
	media_->mixer.clear();
#endif
}

// ───────────────────────────── захист гравця: адаптація й пауза ─────────────────────────────

void AnyPlayLive::applyLevel(int level, const char *why)
{
#ifdef ANYPLAY_HAVE_LIVE
	level = qBound(0, level, kMaxLevel);
	if(!media_ || level == level_)
		return;
	if(level > level_)
		beat_.downs++;
	qInfo().noquote() << "[anyplay-live] quality level" << level_ << "->" << level << "reason" << why;
	level_ = level;
	const Level &l = kLevels[level];
	anyplaylive::VideoConfig cfg;
	cfg.width = l.w;
	cfg.height = l.h;
	cfg.fps = l.fps;
	cfg.kbps = l.kbps;
	media_->video.reconfigure(cfg);
	live_height_ = l.h;
	updateStatusText();
	emit changed();
#else
	Q_UNUSED(level);
	Q_UNUSED(why);
#endif
}

void AnyPlayLive::setPaused(bool paused, const QString &reason)
{
#ifdef ANYPLAY_HAVE_LIVE
	if(paused == paused_ || !media_)
		return;
	paused_ = paused;
	pause_reason_ = paused ? reason : QString();
	media_->video.setPaused(paused);
	media_->game_on.store(!paused && game_audio_);
	if(!paused)
		media_->video.requestKeyframe();
	qInfo().noquote() << "[anyplay-live]" << (paused ? "paused:" : "resumed") << reason;
	setState(paused ? QStringLiteral("paused") : QStringLiteral("live"));
	// сервер пише в чат «Трансляція на паузі: …», глядачі дізнаються одразу через events
	QJsonObject st;
	st["paused"] = paused;
	st["pauseText"] = pause_reason_;
	pushState(st);
	QJsonObject ev;
	ev["t"] = QStringLiteral("pause");
	ev["on"] = paused;
	ev["text"] = pause_reason_;
	sendEvent(ev);
	emit message(paused ? tr("Трансляцію призупинено, щоб гра не гальмувала. Вона відновиться сама.")
	                    : tr("Трансляцію відновлено."));
#else
	Q_UNUSED(paused);
	Q_UNUSED(reason);
#endif
}

void AnyPlayLive::adaptTick()
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!media_ || (state_ != QLatin1String("live") && state_ != QLatin1String("paused")))
		return;
	StreamSession *s = session_.data();
	QmlMainWindow *w = backend_->qmlWindow();
	const double loss = s ? s->GetAveragePacketLoss() * 100.0 : 0.0;
	const int stream_fps = w ? w->property("streamFps").toInt() : 0;
	const int shown_fps = w ? w->property("shownFps").toInt() : 0;
	const int dropped = w ? w->droppedFrames() : 0;   // за останню секунду

	// трансляція: кадри, байти, час кодування
	const int frames = media_->video.frames_encoded.load();
	const int pipe_dropped = media_->video.frames_dropped.load();
	const qint64 bytes = media_->peer ? media_->peer->videoBytesSent() : 0;
	const int fps = qMax(0, frames - last_frames_);
	const int kbps = static_cast<int>(qMax<qint64>(0, bytes - last_bytes_) * 8 / 1000);
	const int pipe_drop = qMax(0, pipe_dropped - last_pipe_dropped_);
	last_frames_ = frames;
	last_pipe_dropped_ = pipe_dropped;
	last_bytes_ = bytes;
	const int enc_us = media_->video.encode_us_avg.load();
	const unsigned remb = media_->remb_kbps.load();
	const Level &l = kLevels[level_];

	if(live_fps_ != fps || live_kbps_ != kbps)
	{
		live_fps_ = paused_ ? 0 : fps;
		live_kbps_ = paused_ ? 0 : kbps;
		emit changed();
	}
	beat_.seconds++;
	beat_.fps_sum += live_fps_;
	beat_.kbps_sum += live_kbps_;
	beat_.enc_us_max = qMax(beat_.enc_us_max, enc_us);
	beat_.level_max = qMax(beat_.level_max, level_);
	if(paused_)
		beat_.paused_s++;
	// показники для власника в CRM (контракт.md, п. 2.1: stats) раз на 10 с
	if(nowMs() - last_stats_ms_ > 10000)
	{
		last_stats_ms_ = nowMs();
		QJsonObject stats;
		stats["kbps"] = live_kbps_;
		stats["fps"] = live_fps_;
		stats["height"] = kLevels[level_].h;
		stats["level"] = level_;
		stats["encoder"] = encoder_name_;
		stats["encMs"] = qRound(enc_us / 100.0) / 10.0;
		stats["dropped"] = pipe_dropped;
		stats["helper"] = remote_active_;
		if(paused_)
			stats["reason"] = pause_reason_.left(60);
		QJsonObject st;
		st["stats"] = stats;
		pushState(st);
	}

	// базові втрати гравця: перші секунди трансляції (до неї ми про гру нічого не знали)
	if(base_samples_ < 5 && qIsFinite(loss))
	{
		base_loss_ = (base_loss_ * base_samples_ + loss) / (base_samples_ + 1);
		base_samples_++;
		return;
	}
	const double loss_limit = qMax(3.0, base_loss_ + 2.0);
	const bool player_bad = (qIsFinite(loss) && loss > loss_limit)
		|| (stream_fps >= 20 && shown_fps > 0 && shown_fps < stream_fps * 0.85 && dropped > 3);
	const int interval_us = 1000000 / qMax(1, l.fps);
	const bool encoder_bad = !paused_ && (enc_us > interval_us * 0.7 || pipe_drop > l.fps / 4);
	const bool uplink_bad = !paused_ && remb > 0 && remb < static_cast<unsigned>(l.kbps * 0.7);
	const qint64 now = nowMs();

	if(paused_)
	{
		if(player_bad)
		{
			good_streak_ = 0;
			return;
		}
		// 20 с спокою — пробуємо знову з найлегшої якості
		if(++good_streak_ >= 20)
		{
			good_streak_ = 0;
			applyLevel(kMaxLevel, "resume");
			setPaused(false, QString());
		}
		return;
	}
	if(player_bad || encoder_bad || uplink_bad)
	{
		good_streak_ = 0;
		bad_streak_++;
		const char *why = player_bad ? "player" : encoder_bad ? "encoder" : "uplink";
		if(bad_streak_ >= 2 && level_ < kMaxLevel)
		{
			if(last_up_ms_ && now - last_up_ms_ < 15000)
				up_blocked_until_ms_ = now + 5 * 60 * 1000;   // щойно піднялись і знову погано: вгору не раніше ніж за 5 хв
			// канал не тягне — одразу на сходинку, що вміщається в оцінку SFU
			int next = level_ + 1;
			if(uplink_bad)
				while(next < kMaxLevel && static_cast<unsigned>(kLevels[next].kbps) > remb * 0.8)
					next++;
			applyLevel(next, why);
			bad_streak_ = 0;
			qInfo().noquote() << "[anyplay-live] adapt" << why << "loss" << loss << "base" << base_loss_ << "fps" << stream_fps
			                  << "/" << shown_fps << "dropped" << dropped << "enc_us" << enc_us << "pipe_drop" << pipe_drop << "remb" << remb;
		}
		else if(bad_streak_ >= 4 && level_ >= kMaxLevel)
		{
			bad_streak_ = 0;
			setPaused(true, player_bad ? tr("Трансляцію призупинено, щоб гра в гравця не гальмувала. Скоро продовжимо.")
			                           : tr("Трансляцію призупинено: інтернет гравця не встигає. Скоро продовжимо."));
		}
		return;
	}
	bad_streak_ = 0;
	if(++good_streak_ >= 30 && level_ > start_level_ && now >= up_blocked_until_ms_)
	{
		good_streak_ = 0;
		last_up_ms_ = now;
		applyLevel(level_ - 1, "recovered");
	}
	// «хто говорить» у списку глядачів
	if(!people_.isEmpty())
		rebuildViewers();
#endif
}

QJsonObject AnyPlayLive::takeHeartbeatStats()
{
	QJsonObject o;
	if(beat_.seconds == 0 && state_ == QLatin1String("off"))
		return o;
	const int n = qMax(1, beat_.seconds);
	o["liveOn"] = state_ == QLatin1String("live") || state_ == QLatin1String("paused");
	o["liveState"] = state_;
	o["liveViewers"] = viewers_.size();
	o["liveFps"] = beat_.fps_sum / n;
	o["liveKbps"] = beat_.kbps_sum / n;
	o["liveHeight"] = kLevels[level_].h;
	o["liveLevel"] = beat_.level_max;
	o["liveDowns"] = beat_.downs;
	o["livePausedS"] = beat_.paused_s;
	o["liveEncMs"] = qRound(beat_.enc_us_max / 100.0) / 10.0;
	if(!encoder_name_.isEmpty())
		o["liveEncoder"] = encoder_name_;
	if(control_member_)
		o["liveCtl"] = remote_active_;
	if(handed_over_)
		o["liveHandedOver"] = true;
	beat_ = Beat();
	return o;
}
