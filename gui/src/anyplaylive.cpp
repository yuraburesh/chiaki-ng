// AnyPlay 116–118: трансляція гри друзям. Див. anyplaylive.h, scratchpad/team7/контракт.md (сервер)
// і scratchpad/team8/контракт-трансляція.md (методи для QML).
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
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRandomGenerator>
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
const int kKeyMinGapMs = 3000;     // ключовий кадр у приставки — не частіше разу на 3 с
const int kHoldGameMs = 180000;    // гра перепідключається: ефір чекає її до 3 хв
const qint64 kUplinkCacheMs = 10 * 60 * 1000;   // перевірку інтернету не повторюємо 10 хв
// перевірка вихідного інтернету: той самий сервіс, що на екрані «Якість» (AnyPlaySpeedTest)
const char *const kUplinkUrl = "https://speed.cloudflare.com/__up";

// пакет вводу помічника (контракт.md, п. 4.1): 28 байтів, little-endian
const int kInputPacketSize = 28;
const uint8_t kInputMagic = 0xA7;
const uint8_t kInputVersion = 1;

qint64 nowMs() { return QDateTime::currentMSecsSinceEpoch(); }

QString compact(const QJsonObject &o) { return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)); }
}

static AnyPlayLive *g_instance = nullptr;

#ifdef ANYPLAY_HAVE_LIVE
// Усе, що живе в інших потоках. Знищується лише після того, як усі потоки зупинено.
struct AnyPlayLiveMedia
{
	anyplaylive::Forwarder fwd;                  // стиснене відео й Opus гри → WebRTC (без перекодування)
	std::mutex peer_mutex;                       // пересилання й мікрофон шлють у peer зі своїх потоків
	std::unique_ptr<anyplaylive::Peer> peer;
	anyplaylive::VoiceMixer mixer;
	std::mutex mid_mutex;
	std::map<std::string, std::string> mid_owner;   // mid треку голосу → memberId глядача
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

// що бачать потоки chiaki
static std::atomic<anyplaylive::Forwarder *> g_fwd{ nullptr };
static std::atomic<int> g_fwd_inflight{ 0 };
static std::atomic<AnyPlayLiveMedia *> g_game_audio{ nullptr };
static std::atomic<unsigned> g_audio_frame{ 480 };     // тривалість пакета Opus з PS5 (48 кГц), із заголовка звуку
static std::atomic<int64_t> g_game_bytes{ 0 };          // усі байти відео й звуку гри (для оцінки потоку до старту)
static std::atomic<int> g_game_frames{ 0 };
// заголовок потоку (SPS/PPS або VPS/SPS/PPS): приходить на початку гри й при зміні роздільності
static std::mutex g_header_mutex;
static anyplaylive::StreamHeader g_header;
static std::atomic<quint32> g_header_gen{ 0 };

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

static anyplaylive::StreamHeader currentHeader()
{
	std::lock_guard<std::mutex> lock(g_header_mutex);
	return g_header;
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
	quality_ = QStringLiteral("game");
	compat_video_ = st.value(QStringLiteral("anyplay/live_compat_h264"), false).toBool();
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
	stats_timer_.setInterval(1000);
	connect(&stats_timer_, &QTimer::timeout, this, &AnyPlayLive::statsTick);
	// потік гри (кодек, Мбіт/с, кадри) — раз на секунду, поки йде гра: одне читання двох лічильників
	game_timer_.setInterval(1000);
	connect(&game_timer_, &QTimer::timeout, this, &AnyPlayLive::gameTick);
	connect_timer_.setSingleShot(true);
	republish_timer_.setSingleShot(true);
	connect(&republish_timer_, &QTimer::timeout, this, &AnyPlayLive::republish);
	// libdatachannel каже «disconnected», коли кілька секунд немає відповіді; часто з'єднання вертається само
	disconnect_timer_.setSingleShot(true);
	disconnect_timer_.setInterval(5000);
	connect(&disconnect_timer_, &QTimer::timeout, this, [this]() {
		if(state_ != QLatin1String("live"))
			return;
		enterReconnecting(tr("Зник інтернет. Ефір повернеться сам, щойно зв'язок з'явиться."));
		scheduleRepublish(5000);   // з'єднання не повернулось саме: нове, щойно буде інтернет
	});
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

	connect(backend, &QmlBackend::sessionError, this, [this]() { session_error_ms_ = nowMs(); });
	connect(backend, &QmlBackend::sessionChanged, this, [this](StreamSession *s) {
		session_ = s;
		if(s)
		{
			if(!game_timer_.isActive())
				game_timer_.start();
			return;
		}
		game_timer_.stop();
		game_kbps_ = game_fps_ = game_peak_kbps_ = 0;
		game_bytes_hist_.clear();
		emit gameChanged();
		if(state_ == QLatin1String("off") || state_ == QLatin1String("error"))
			return;
		// гра перепідключається (зміна якості чи «Відео для всіх браузерів» за згодою гравця, або обірвався зв'язок
		// з приставкою): ефір не вимикаємо, глядачі чекають, кімната лишається, посилання те саме
		const bool reconnecting_game = (cloud_ && cloud_->property("reconnectOnce").toBool())
			|| (session_error_ms_ && nowMs() - session_error_ms_ < 5000) || nowMs() < hold_until_ms_;
		if(reconnecting_game && ever_live_)
		{
			hold_until_ms_ = qMax(hold_until_ms_, nowMs() + kHoldGameMs);
			header_gen_seen_ = 0;
#ifdef ANYPLAY_HAVE_LIVE
			header_gen_seen_ = g_header_gen.load();
#endif
			enterReconnecting(tr("Гра перепідключається. Ефір продовжиться сам, глядачі зачекають."));
			return;
		}
		// гра закінчилась (бронь, вихід, передали другові): трансляцію вимикаємо
		teardown(true);
		emit message(tr("Гра закінчилась, трансляцію вимкнено."));
	});
	session_ = backend->qmlSession();
	if(session_)
		game_timer_.start();
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

void AnyPlayLive::tapVideoSample(const uint8_t *data, size_t size)
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!data || size < 5)
		return;
	g_game_bytes.fetch_add(static_cast<int64_t>(size), std::memory_order_relaxed);
	// заголовок (рідко: початок гри, зміна роздільності) — запам'ятовуємо завжди, навіть без трансляції, щоб
	// знати кодек і мати SPS/PPS для глядачів. Дешево: дивимось лише перші два байти першої NAL.
	size_t at = data[2] == 1 ? 3 : (data[2] == 0 && data[3] == 1 ? 4 : 0);
	bool header = false;
	if(at && at + 1 < size)
	{
		if(anyplaylive::headerCodec(data + at, size - at) != anyplaylive::Codec::Unknown)
		{
			anyplaylive::StreamHeader h;
			if(anyplaylive::parseHeaderSample(data, size, &h))
			{
				header = true;
				{
					std::lock_guard<std::mutex> lock(g_header_mutex);
					g_header = std::move(h);
				}
				g_header_gen.fetch_add(1);
			}
		}
	}
	if(!header)
		g_game_frames.fetch_add(1, std::memory_order_relaxed);
	if(!g_fwd.load(std::memory_order_relaxed))
		return;
	g_fwd_inflight.fetch_add(1);
	if(anyplaylive::Forwarder *f = g_fwd.load())
		f->pushVideo(data, size, anyplaylive::nowUs());
	g_fwd_inflight.fetch_sub(1);
#else
	Q_UNUSED(data);
	Q_UNUSED(size);
#endif
}

void AnyPlayLive::tapGameAudioHeader(unsigned channels, unsigned rate, unsigned frameSize)
{
#ifdef ANYPLAY_HAVE_LIVE
	// Opus у WebRTC завжди з часом 48 кГц; PS5 шле 48 кГц стерео, пакети по 480 (10 мс)
	if(frameSize && rate)
		g_audio_frame.store(static_cast<unsigned>(static_cast<uint64_t>(frameSize) * 48000 / rate));
	anyplaylive::logf("game audio: %u ch, %u Hz, %u samples per packet", channels, rate, frameSize);
#else
	Q_UNUSED(channels);
	Q_UNUSED(rate);
	Q_UNUSED(frameSize);
#endif
}

void AnyPlayLive::tapGameOpus(const uint8_t *data, size_t size)
{
#ifdef ANYPLAY_HAVE_LIVE
	g_game_bytes.fetch_add(static_cast<int64_t>(size), std::memory_order_relaxed);
	if(!g_game_audio.load(std::memory_order_relaxed))
		return;
	g_fwd_inflight.fetch_add(1);
	AnyPlayLiveMedia *m = g_game_audio.load();
	if(m && m->game_on.load(std::memory_order_relaxed))
		m->fwd.pushAudio(data, size, g_audio_frame.load(std::memory_order_relaxed));
	g_fwd_inflight.fetch_sub(1);
#else
	Q_UNUSED(data);
	Q_UNUSED(size);
#endif
}

bool AnyPlayLive::compatVideoWanted()
{
#ifdef ANYPLAY_HAVE_LIVE
	return QSettings().value(QStringLiteral("anyplay/live_compat_h264"), false).toBool();
#else
	return false;
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
	}
	else if(state_ == QLatin1String("off"))
		status_text_ = handed_over_ ? tr("Гру передано. Тепер грає: %1").arg(handoff_name_) : QString();
}

void AnyPlayLive::fail(const QString &text)
{
	teardown(!token_.isEmpty());
	setState(QStringLiteral("error"), text);
	emit message(text);
}

// ───────────────────────────── гра: кодек, потік, кадри ─────────────────────────────

void AnyPlayLive::gameTick()
{
#ifdef ANYPLAY_HAVE_LIVE
	const qint64 bytes = g_game_bytes.load();
	const int frames = g_game_frames.load();
	const qint64 db = game_bytes_last_ ? qMax<qint64>(0, bytes - game_bytes_last_) : 0;
	const int df = game_frames_last_ ? qMax(0, frames - game_frames_last_) : 0;
	const bool first = !game_bytes_last_;
	game_bytes_last_ = bytes;
	game_frames_last_ = frames;
	if(first)
		return;
	game_bytes_hist_.append(db);
	while(game_bytes_hist_.size() > 10)
		game_bytes_hist_.removeFirst();
	qint64 sum = 0, peak = 0;
	for(qint64 b : std::as_const(game_bytes_hist_))
	{
		sum += b;
		peak = qMax(peak, b);
	}
	const int kbps = static_cast<int>(sum * 8 / 1000 / qMax(1, int(game_bytes_hist_.size())));
	const int peak_kbps = static_cast<int>(peak * 8 / 1000);
	const anyplaylive::Codec c = currentHeader().codec;
	const QString codec = QString::fromLatin1(anyplaylive::codecName(c));
	// QML оновлюємо лише на помітні зміни: меню закрите — нічого не перемальовується
	const bool notable = codec != game_codec_ || qAbs(kbps - game_kbps_) > qMax(300, game_kbps_ / 10)
		|| qAbs(df - game_fps_) > 3;
	game_peak_kbps_ = peak_kbps;
	if(notable)
	{
		game_codec_ = codec;
		game_kbps_ = kbps;
		game_fps_ = df;
		emit gameChanged();
	}
	// гра перепідключилась, поки ефір чекав: щойно прийшов новий заголовок — знову в ефір (кодек міг змінитись)
	if(state_ == QLatin1String("reconnecting") && hold_until_ms_ && session_ && g_header_gen.load() != header_gen_seen_)
	{
		hold_until_ms_ = 0;
		qInfo() << "[anyplay-live] game is back: publishing again";
		scheduleRepublish(0);
	}
	else if(state_ == QLatin1String("reconnecting") && hold_until_ms_ && nowMs() > hold_until_ms_)
	{
		hold_until_ms_ = 0;
		teardown(true);
		emit message(tr("Гра не повернулась за 3 хвилини, трансляцію вимкнено."));
	}
#endif
}

QString AnyPlayLive::gameCodec() const
{
	return game_codec_;
}

int AnyPlayLive::needKbps() const
{
	// пересилання = потік гри як є (відео + звук) + заголовки RTP/SRTP і запас на ключові кадри
	const int base = qMax(game_kbps_, game_peak_kbps_ * 8 / 10);
	return base > 0 ? base * 125 / 100 + 300 : 0;
}

bool AnyPlayLive::compatPending() const
{
	return compat_video_ && game_codec_ == QLatin1String("H.265");
}

QString AnyPlayLive::browserNote() const
{
	if(game_codec_ == QLatin1String("H.265"))
		return tr("Відео йде у форматі H.265, як його дає приставка. Його показують Safari (iPhone, iPad, Mac) і Chrome від версії 136 "
		          "на Android, Windows і Mac. У Firefox і старих браузерах буде лише звук і чат. Щоб відео відкривалось будь-де, "
		          "увімкни «Відео для всіх браузерів».");
	if(game_codec_ == QLatin1String("H.264"))
		return tr("Відео йде у форматі H.264: його показує будь-який сучасний браузер на телефоні, комп'ютері чи телевізорі.");
	return QString();
}

void AnyPlayLive::setCompatVideo(bool on)
{
	if(on == compat_video_)
		return;
	compat_video_ = on;
	QSettings().setValue(QStringLiteral("anyplay/live_compat_h264"), on);
	qInfo().noquote() << "[anyplay-live] compatible video (H.264 game stream):" << on;
	emit gameChanged();
}

void AnyPlayLive::holdForReconnect(int seconds)
{
	hold_until_ms_ = nowMs() + qBound(10, seconds, 600) * 1000LL;
}

// ───────────────────────────── старт: перевірка вихідного інтернету ─────────────────────────────

void AnyPlayLive::start(const QString &quality, bool gameAudio)
{
	Q_UNUSED(quality);   // глядачі бачать гру такою ж, як гравець: якості для трансляції окремо немає
#ifndef ANYPLAY_HAVE_LIVE
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
	if(!currentHeader().valid())
	{
		emit message(tr("Зачекай кілька секунд, поки з'явиться картинка гри, і спробуй ще раз."));
		return;
	}
	game_audio_ = gameAudio;
	QSettings().setValue(QStringLiteral("anyplay/live_game_audio"), game_audio_);

	generation_++;
	ever_live_ = false;
	republish_tries_ = 0;
	hold_until_ms_ = 0;
	last_chat_id_ = -1;
	last_frames_ = 0;
	last_bytes_ = 0;
	last_overflows_ = 0;
	overflow_times_.clear();
	viewers_lag_ = false;
	key_requests_ = 0;
	beat_.skipped = beat_.overflows = 0;
	media_ = std::make_unique<AnyPlayLiveMedia>();

	// весь запуск не довше 40 с (перевірка інтернету до 8 с)
	const quint32 gen = generation_;
	connect_timer_.disconnect();
	connect(&connect_timer_, &QTimer::timeout, this, [this, gen]() {
		if(generation_ == gen && (state_ == QLatin1String("starting") || state_ == QLatin1String("checking")))
			fail(tr("Трансляція не запустилась: сервер трансляцій не відповів вчасно. Спробуй ще раз."));
	});
	connect_timer_.start(40000);
	qInfo().noquote() << "[anyplay-live] start: game" << game_codec_ << game_kbps_ << "kbps, need" << needKbps()
	                  << "kbps, gameAudio" << game_audio_;
	checkUplink();
#endif
}

void AnyPlayLive::checkUplink()
{
	const int need = needKbps();
	// свіжа перевірка (до 10 хв) — не повторюємо: друга спроба поспіль не має знову забивати канал
	if(uplink_kbps_ > 0 && nowMs() - uplink_at_ms_ < kUplinkCacheMs && uplink_kbps_ >= need)
	{
		uplinkResult(uplink_kbps_, QStringLiteral("cached"));
		return;
	}
	setState(QStringLiteral("checking"), tr("Перевіряю інтернет на відправлення (кілька секунд)…"));
	if(!nam_)
		nam_ = new QNetworkAccessManager(this);
	// ~2,5 с потоку з потрібною швидкістю, від 1,5 до 12 МБ. Гравець у цей час у меню, гра на паузі.
	const qint64 bytes = qBound<qint64>(qint64(1500000), static_cast<qint64>(qMax(need, 8000)) * 1000 / 8 * 5 / 2, qint64(12000000));
	QByteArray payload(static_cast<int>(bytes), Qt::Uninitialized);
	QRandomGenerator *rnd = QRandomGenerator::global();
	for(int i = 0; i + 4 <= payload.size(); i += 4)
	{
		const quint32 x = rnd->generate();
		memcpy(payload.data() + i, &x, 4);
	}
	QNetworkRequest req{QUrl(QString::fromLatin1(kUplinkUrl))};
	req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/octet-stream"));
	req.setTransferTimeout(10000);
	const quint32 gen = generation_;
	auto clock = std::make_shared<QElapsedTimer>();
	auto first = std::make_shared<qint64>(-1);
	auto sent = std::make_shared<qint64>(0);
	auto done = std::make_shared<bool>(false);
	QNetworkReply *reply = nam_->post(req, payload);
	clock->start();
	auto finish = [this, gen, reply, clock, first, sent, done, bytes](bool complete) {
		if(*done)
			return;
		*done = true;
		const qint64 t0 = *first >= 0 ? *first : 0;
		const qint64 ms = clock->elapsed() - t0;
		const qint64 b = complete ? bytes : *sent;
		reply->abort();
		reply->deleteLater();
		if(gen != generation_)
			return;
		int kbps = -1;
		if(ms > 200 && b >= 500000)
			kbps = static_cast<int>(b * 8 / ms);   // біт/мс = кбіт/с
		uplinkResult(kbps, complete ? QStringLiteral("measured") : QStringLiteral("partial"));
	};
	connect(reply, &QNetworkReply::uploadProgress, this, [clock, first, sent, finish](qint64 s, qint64) {
		if(s > 0 && *first < 0)
			*first = clock->elapsed();
		*sent = s;
		if(clock->elapsed() > 8000)
			finish(false);
	});
	connect(reply, &QNetworkReply::finished, this, [reply, finish]() {
		finish(reply->error() == QNetworkReply::NoError);
	});
	QTimer::singleShot(9000, this, [finish]() { finish(false); });
}

void AnyPlayLive::uplinkResult(int kbps, const QString &why)
{
	const int need = needKbps();
	if(kbps > 0)
	{
		uplink_kbps_ = kbps;
		uplink_at_ms_ = nowMs();
	}
	qInfo().noquote() << "[anyplay-live] uplink" << kbps << "kbps (" << why << "), game" << game_kbps_ << "kbps, need" << need;
	auto mbps = [](int k) { return QString::number(k / 1000.0, 'f', 1).replace(QLatin1Char('.'), QLatin1Char(',')); };
	if(kbps > 0 && need > 0 && kbps < need)
	{
		// чесно й до старту: трансляція пересилає гру як є, тому знизити її якість окремо для глядачів не можна
		uplink_kbps_ = kbps;
		fail(tr("Трансляцію не ввімкнути: інтернет на відправлення зараз %1 Мбіт/с, а трансляції треба щонайменше %2 Мбіт/с "
		        "(гра йде %3 Мбіт/с, і глядачі отримують її як є, без перекодування). Що можна зробити: у меню «Зображення» "
		        "обери якість нижче (гра піде меншим потоком) або під'єднай комп'ютер кабелем і спробуй ще раз.")
			.arg(mbps(kbps), mbps(need), mbps(game_kbps_)));
		return;
	}
	// межа швидкості відправлення: не більше 90 % виміряного (щоб не забити канал гравця), але з запасом на ключові кадри
	const int base = qMax(need, 4000);
	pace_kbps_ = kbps > 0 ? qMax(qMin(kbps * 9 / 10, qMax(base * 5 / 2, base + 8000)), base * 11 / 10)
	                      : qMax(base * 2, base + 8000);
	if(kbps <= 0)
		qWarning() << "[anyplay-live] uplink check failed, pacing at" << pace_kbps_ << "kbps";
	setState(QStringLiteral("starting"), tr("Готуємо трансляцію…"));
	beginServer();
}

void AnyPlayLive::beginServer()
{
	QJsonObject body;
	// сервер знає лише 720p/540p (контракт.md, п. 2.1); глядачі однаково отримують гру як є
	body["quality"] = QStringLiteral("720p");
	body["gameAudio"] = game_audio_;
	body["access"] = QStringLiteral("link");
	const quint32 gen = generation_;
	api(kApiStart, body, [this, gen](bool ok, int status, const QJsonObject &o) {
		if(gen != generation_)
			return;
		const QString token = o.value(QStringLiteral("token")).toString();
		if(!ok || token.isEmpty())
		{
			if(ever_live_)
			{
				scheduleRepublish(5000);   // ефір уже йшов: інтернет чи сервер повернуться — спробуємо знову
				return;
			}
			token_.clear();
			fail(errorText(status, o, tr("Не вдалося почати трансляцію. Спробуй ще раз.")));
			return;
		}
		const QString old_code = code_;
		token_ = token;
		last_poll_ok_ms_ = nowMs();
		applyRoomState(o);
		if(ever_live_ && !old_code.isEmpty() && code_ != old_code)
			emit message(tr("Інтернету не було довго, тож кімната трансляції нова: надішли друзям нове посилання."));
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
	const quint32 pub = ++pub_gen_;
	republish_busy_ = true;
	// помилка до першого ефіру — чесна помилка; після — чекаємо й пробуємо знову (інтернет зник ненадовго)
	auto failed = [this](const QString &text) {
		republish_busy_ = false;
		if(ever_live_)
		{
			qWarning().noquote() << "[anyplay-live] publish failed, retrying:" << text;
			scheduleRepublish(qMin(15000, 3000 * (1 + republish_tries_++)));
		}
		else
			fail(text);
	};
	api(kSfuSession, QJsonObject(), [this, gen, pub, failed](bool ok, int status, const QJsonObject &o) {
		if(gen != generation_ || pub != pub_gen_)
			return;
		session_id_ = o.value(QStringLiteral("sessionId")).toString();
		if(!ok || session_id_.isEmpty())
		{
			if(ever_live_ && (status == 401 || status == 403 || status == 404 || status == 410))
			{
				// кімнату закрито, поки не було інтернету: відкриваємо знову
				republish_busy_ = false;
				token_.clear();
				beginServer();
				return;
			}
			failed(errorText(status, o, tr("Сервер трансляцій не відповів. Спробуй ще раз.")));
			return;
		}
		ice_urls_ = iceUrls(o.value(QStringLiteral("iceServers")).toArray());
		if(ice_urls_.isEmpty())
			ice_urls_ << QStringLiteral("stun:stun.cloudflare.com:3478");

		const anyplaylive::StreamHeader header = currentHeader();
		if(!header.valid())
		{
			failed(tr("Немає картинки гри, трансляції нічого показувати."));
			return;
		}
		AnyPlayLiveMedia *m = media_.get();
		QPointer<AnyPlayLive> self(this);
		auto post = [self, gen, pub](std::function<void(AnyPlayLive *)> f) {
			QMetaObject::invokeMethod(QCoreApplication::instance(), [self, gen, pub, f]() {
				if(self && self->generation_ == gen && self->pub_gen_ == pub)
					f(self.data());
			}, Qt::QueuedConnection);
		};
		anyplaylive::Peer::Callbacks cb;
		cb.state = [post](const std::string &s) {
			const QString st = QString::fromStdString(s);
			post([st](AnyPlayLive *me) {
				qInfo().noquote() << "[anyplay-live] peer" << st;
				if(st == QLatin1String("connected"))
				{
					me->disconnect_timer_.stop();
					if(me->state_ == QLatin1String("reconnecting") && me->input_channel_ >= 0 && me->session_)
					{
						me->setState(QStringLiteral("live"));
						if(me->media_)
							me->media_->fwd.setVideoOn(true);
						me->requestKeyframe("reconnected");
					}
				}
				else if(st == QLatin1String("disconnected"))
				{
					if(!me->disconnect_timer_.isActive())
						me->disconnect_timer_.start();
				}
				else if(st == QLatin1String("failed") || st == QLatin1String("closed"))
				{
					if(me->ever_live_)
					{
						me->enterReconnecting(tr("Зник інтернет. Ефір повернеться сам, щойно зв'язок з'явиться."));
						me->scheduleRepublish(2000);
					}
					else
						me->fail(tr("Не вдалося з'єднатися з сервером трансляцій. Спробуй ще раз."));
				}
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
		cb.keyframe = [post]() { post([](AnyPlayLive *me) { me->requestKeyframe("pli"); }); };
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
			failed(tr("Не вдалося підготувати з'єднання трансляції (%1).").arg(QString::fromStdString(err)));
			return;
		}
		const std::string fmtp = anyplaylive::sdpFmtp(header.codec, header.annexB);
		peer->addVideo(kTrackVideo, header.codec, fmtp, pace_kbps_);
		peer->addAudio(kTrackGame, 2);   // трек є завжди; коли звук гри вимкнено, по ньому просто нічого не йде
		peer->addAudio(kTrackMic, 1);
		qInfo().noquote() << "[anyplay-live] publish" << anyplaylive::codecName(header.codec) << QString::fromStdString(fmtp)
		                  << "pace" << pace_kbps_ << "kbps";
		std::unique_ptr<anyplaylive::Peer> old;
		{
			std::lock_guard<std::mutex> lock(m->peer_mutex);
			old = std::move(m->peer);
			m->peer = std::move(peer);
		}
		if(old)
			old->close();
		input_channel_ = events_channel_ = -1;
		// пересилання: той самий кодек, що й гра; кадри підуть, щойно з'єднаємось і буде ключовий
		m->fwd.setPaceKbps(pace_kbps_);
		if(!m->fwd.running())
		{
			m->fwd.start(header.codec, header,
				[m](const std::vector<uint8_t> &au, bool, int64_t us) {
					std::lock_guard<std::mutex> lock(m->peer_mutex);
					if(m->peer)
						m->peer->sendVideo(au, us);
				},
				[m](const uint8_t *d, size_t n, uint32_t samples) { m->sendAudio(kTrackGame, d, n, static_cast<int>(samples)); },
				[self](const char *why) {
					const QByteArray w(why);
					QMetaObject::invokeMethod(QCoreApplication::instance(), [self, w]() {
						if(self)
							self->requestKeyframe(w.constData());
					}, Qt::QueuedConnection);
				});
		}
		m->fwd.setVideoOn(false);   // до з'єднання кадри не беремо
		// m=application одразу в першому offer: datachannels/establish не потрібен (контракт.md, п. 3.1)
		m->peer->makeOffer(true);
		whenGathered([this, gen, pub, failed]() {
			if(gen != generation_ || pub != pub_gen_ || !media_ || !media_->peer)
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
			api(kSfuTracks, body, [this, gen, pub, failed](bool ok, int status, const QJsonObject &o) {
				if(gen != generation_ || pub != pub_gen_)
					return;
				const QJsonObject answer = o.value(QStringLiteral("sessionDescription")).toObject();
				std::string err;
				if(!ok || answer.value(QStringLiteral("type")).toString() != QLatin1String("answer")
					|| !media_->peer->applyAnswer(answer.value(QStringLiteral("sdp")).toString().toStdString(), &err))
				{
					qWarning().noquote() << "[anyplay-live] publish failed:" << QString::fromStdString(err);
					failed(errorText(status, o, tr("Сервер трансляцій не прийняв відео. Спробуй ще раз.")));
					return;
				}
				for(const QJsonValue &v : o.value(QStringLiteral("tracks")).toArray())
					if(v.toObject().contains(QStringLiteral("errorCode")))
						qWarning().noquote() << "[anyplay-live] track error" << compact(v.toObject());
				// чекаємо з'єднання з SFU (ICE + DTLS), далі канали даних
				waitFor([this]() { return media_ && media_->peer && media_->peer->connected(); }, 15000, [this, gen, pub, failed](bool connected) {
					if(gen != generation_ || pub != pub_gen_)
						return;
					if(connected)
						openChannels();
					else
						failed(tr("Не вдалося з'єднатися з сервером трансляцій. Можливо, мережа блокує WebRTC."));
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
	const quint32 pub = pub_gen_;
	QJsonObject input, events;
	input["location"] = QStringLiteral("local");
	input["dataChannelName"] = QString::fromLatin1(kChannelInput);
	events["location"] = QStringLiteral("local");
	events["dataChannelName"] = QString::fromLatin1(kChannelEvents);
	QJsonObject body;
	body["dataChannels"] = QJsonArray{ input, events };
	api(kSfuChannels, body, [this, gen, pub](bool ok, int status, const QJsonObject &o) {
		if(gen != generation_ || pub != pub_gen_)
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
			const QString text = errorText(status, o, tr("Сервер трансляцій не відкрив канал керування. Спробуй ще раз."));
			if(ever_live_)
			{
				republish_busy_ = false;
				scheduleRepublish(qMin(15000, 3000 * (1 + republish_tries_++)));
			}
			else
				fail(text);
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
	republish_busy_ = false;
	republish_tries_ = 0;
	AnyPlayLiveMedia *m = media_.get();
	const bool again = ever_live_;
	ever_live_ = true;
	if(!again)
	{
		m->mixer.setEnabled(voices_on_);
		m->mixer.setVolume(voice_volume_ / 100.0f);
		for(const qint64 id : std::as_const(muted_))
			m->mixer.setMuted(QString::number(id).toStdString(), true);
	}
	// звук гри: пакети Opus з PS5 як є (без розкодування й кодування)
	m->game_on.store(game_audio_);
	g_game_audio.store(m);
	m->fwd.setAudioOn(true);
	// відео: від наступного ключового кадру, який просимо в приставки зараз
	g_fwd.store(&m->fwd);
	m->fwd.waitKey("live");
	m->fwd.setVideoOn(true);
	requestKeyframe(again ? "republished" : "start");
	if(mic_on_ && !m->mic_dev)
		openMic();
	poll_timer_.start();
	stats_timer_.start();
	setState(QStringLiteral("live"));
	QJsonObject st;
	st["paused"] = false;
	st["muted"] = !mic_on_;
	pushState(st);
	poll();
	// голоси: після нового з'єднання підписки на голоси глядачів треба зробити знову
	for(auto it = people_.begin(); it != people_.end(); ++it)
	{
		it.value().voiceMid.clear();
		it.value().voicePending = false;
	}
	reconcileVoices();
	if(again)
		emit message(tr("Трансляція знову в ефірі."));
	else
		emit message(tr("Трансляцію ввімкнено. Надішли друзям посилання."));
	qInfo().noquote() << "[anyplay-live]" << (again ? "back live" : "live") << "room" << room_id_ << "code" << code_
	                  << "codec" << game_codec_ << "session" << session_id_;
#endif
}

void AnyPlayLive::enterReconnecting(const QString &text)
{
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
		media_->fwd.setVideoOn(false);
#endif
	disconnect_timer_.stop();
	if(state_ != QLatin1String("reconnecting"))
		qInfo().noquote() << "[anyplay-live] reconnecting:" << text;
	setState(QStringLiteral("reconnecting"), text);
}

void AnyPlayLive::scheduleRepublish(int delayMs)
{
	if(token_.isEmpty() && !ever_live_)
		return;
	republish_timer_.start(qMax(0, delayMs));
}

void AnyPlayLive::republish()
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!media_ || !ever_live_ || state_ == QLatin1String("off") || state_ == QLatin1String("error"))
		return;
	if(!session_ || nowMs() < hold_until_ms_)
	{
		// гра ще не повернулась: чекаємо (gameTick запустить, щойно буде новий заголовок)
		if(!hold_until_ms_)
			scheduleRepublish(3000);
		return;
	}
	if(republish_busy_)
	{
		scheduleRepublish(3000);
		return;
	}
	enterReconnecting(status_text_.isEmpty() ? tr("Відновлюю ефір…") : status_text_);
	// заголовок і кодек могли змінитись (гра перепідключилась): пересилання — наново
	media_->fwd.stop();
	g_fwd.store(nullptr);
	while(g_fwd_inflight.load())
		std::this_thread::yield();
	if(token_.isEmpty())
		beginServer();
	else
		negotiatePublish();
#endif
}

void AnyPlayLive::requestKeyframe(const char *why)
{
	// ключовий кадр від PS5: новий глядач, PLI, після обриву. Не частіше разу на 3 с; запит у проміжку — один
	// відкладений повтор. Просимо напряму (chiaki_session_request_idr), БЕЗ «чекати ключовий кадр» у приймачі
	// гравця: його картинка не зупиняється й нічого не помічає.
	if(!session_)
		return;
	const qint64 now = nowMs();
	if(last_key_ms_ && now - last_key_ms_ < kKeyMinGapMs)
	{
		if(!key_pending_)
		{
			key_pending_ = true;
			const quint32 gen = generation_;
			const QByteArray w(why);
			QTimer::singleShot(static_cast<int>(kKeyMinGapMs - (now - last_key_ms_)) + 10, this, [this, gen, w]() {
				key_pending_ = false;
				if(gen == generation_ && (state_ == QLatin1String("live") || state_ == QLatin1String("reconnecting")))
					requestKeyframe(w.constData());
			});
		}
		return;
	}
	last_key_ms_ = now;
	key_requests_++;
	beat_.keys++;
	qInfo().noquote() << "[anyplay-live] key frame request:" << why;
	QMetaObject::invokeMethod(session_.data(), "RequestLiveKeyframe", Qt::QueuedConnection);
}

void AnyPlayLive::teardown(bool tellServer)
{
	generation_++;
	pub_gen_++;
	poll_timer_.stop();
	stats_timer_.stop();
	connect_timer_.stop();
	hello_timer_.stop();
	republish_timer_.stop();
	disconnect_timer_.stop();
	republish_busy_ = false;
	ever_live_ = false;
	hold_until_ms_ = 0;
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
		g_fwd.store(nullptr);
		g_game_audio.store(nullptr);
		while(g_fwd_inflight.load())
			std::this_thread::yield();
		m->fwd.stop();
		closeMic();
		closeVoiceOut();
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
	live_fps_ = live_kbps_ = 0;
	viewers_lag_ = false;
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
			// інтернету довго не було і сервер закрив кімнату (гравець мовчав > 90 с): відкриваємо нову сам
			if(ever_live_ && (state_ == QLatin1String("reconnecting") || nowMs() - last_poll_ok_ms_ > 20000))
			{
				qInfo() << "[anyplay-live] room closed while offline: opening again";
				token_.clear();
				enterReconnecting(tr("Зник інтернет. Ефір повернеться сам, щойно зв'язок з'явиться."));
				scheduleRepublish(0);
				return;
			}
			teardown(false);
			emit message(errorText(status, o, tr("Трансляцію завершено.")));
			return;
		}
		if(!ok)
			return;   // тимчасові збої зв'язку трансляцію не зупиняють
		last_poll_ok_ms_ = nowMs();
		applyRoomState(o);
	});
}

void AnyPlayLive::applyRoomState(const QJsonObject &o)
{
	const QJsonObject room = o.value(QStringLiteral("room")).toObject();
	if(room.isEmpty())
		return;
	if(room.value(QStringLiteral("status")).toString() == QLatin1String("closed")
		&& (state_ == QLatin1String("live") || state_ == QLatin1String("reconnecting")))
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
	bool newcomer = false;
	for(const QJsonValue &v : o.value(QStringLiteral("members")).toArray())
	{
		const QJsonObject mo = v.toObject();
		if(mo.value(QStringLiteral("player")).toBool() || mo.value(QStringLiteral("me")).toBool())
			continue;
		const qint64 id = mo.value(QStringLiteral("memberId")).toVariant().toLongLong();
		if(!id)
			continue;
		seen.insert(id);
		if(!people_.contains(id))
			newcomer = true;
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
	// новий глядач: ключовий кадр зараз і ще раз за 3 с (поки він підключає відео, перший може проминути);
	// далі він сам попросить через PLI, якщо треба
	if(newcomer && state_ == QLatin1String("live"))
	{
		requestKeyframe("viewer");
		const quint32 kgen = generation_;
		QTimer::singleShot(kKeyMinGapMs + 100, this, [this, kgen]() {
			if(kgen == generation_ && state_ == QLatin1String("live"))
				requestKeyframe("viewer-repeat");
		});
	}

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
	if((state_ != QLatin1String("live") && state_ != QLatin1String("reconnecting")) || !people_.contains(uid))
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
	// 118: окремої якості для глядачів немає — вони отримують гру як є (лишено для старого QML)
	Q_UNUSED(quality);
}

void AnyPlayLive::setGameAudio(bool on)
{
	if(on == game_audio_)
		return;
	game_audio_ = on;
	QSettings().setValue(QStringLiteral("anyplay/live_game_audio"), on);
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
		media_->game_on.store(on);
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
	if(state_ == QLatin1String("live") || state_ == QLatin1String("reconnecting"))
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

// ───────────────────────────── показники (раз на секунду) ─────────────────────────────
// Лише рахуємо й показуємо. Нічого не вмикає, не вимикає й не знижує: ефір зупиняє тільки гравець.

void AnyPlayLive::statsTick()
{
#ifdef ANYPLAY_HAVE_LIVE
	if(!media_ || (state_ != QLatin1String("live") && state_ != QLatin1String("reconnecting")))
		return;
	anyplaylive::Forwarder &f = media_->fwd;
	const int frames = f.frames_sent.load();
	const qint64 bytes = f.bytes_sent.load();
	const int fps = qMax(0, frames - last_frames_);
	const int kbps = static_cast<int>(qMax<qint64>(0, bytes - last_bytes_) * 8 / 1000);
	last_frames_ = frames;
	last_bytes_ = bytes;
	const bool live = state_ == QLatin1String("live");
	int rtt = 0, loss = 0;
	{
		std::lock_guard<std::mutex> lock(media_->peer_mutex);
		if(media_->peer)
		{
			rtt = media_->peer->rttMs();
			loss = media_->peer->lossPercent();
		}
	}
	// вихідний канал не встигав (кадри глядачам пропущено до ключового) — за останню хвилину
	const int ov = f.overflows.load();
	const qint64 now = nowMs();
	for(int i = last_overflows_; i < ov; i++)
		overflow_times_.append(now);
	last_overflows_ = ov;
	while(!overflow_times_.isEmpty() && now - overflow_times_.first() > 60000)
		overflow_times_.removeFirst();
	const bool lag = overflow_times_.size() >= 2;
	if(lag != viewers_lag_)
	{
		viewers_lag_ = lag;
		qInfo().noquote() << "[anyplay-live] viewers lag" << lag << "backlog" << f.backlog_ms.load() << "ms, rtt" << rtt << "loss" << loss;
		emit changed();
	}
	// довго немає ключового кадру (запит загубився): просимо ще раз
	if(live && f.waiting_key.load() && f.frames_skipped.load() > 0)
		requestKeyframe("still-waiting");
	const int show_fps = live ? fps : 0, show_kbps = live ? kbps : 0;
	if(live_fps_ != show_fps || qAbs(live_kbps_ - show_kbps) > qMax(200, live_kbps_ / 10))
	{
		live_fps_ = show_fps;
		live_kbps_ = show_kbps;
		emit changed();
	}
	beat_.seconds++;
	beat_.fps_sum += show_fps;
	beat_.kbps_sum += show_kbps;
	beat_.rtt_max = qMax(beat_.rtt_max, rtt);
	if(!live)
		beat_.reconnect_s++;
	// показники для власника в CRM (контракт.md, п. 2.1: stats) раз на 10 с
	if(now - last_stats_ms_ > 10000)
	{
		last_stats_ms_ = now;
		QJsonObject stats;
		stats["kbps"] = live_kbps_;
		stats["fps"] = live_fps_;
		stats["codec"] = game_codec_;
		stats["encoder"] = QStringLiteral("passthrough");
		stats["gameKbps"] = game_kbps_;
		stats["uplinkKbps"] = uplink_kbps_;
		stats["paceKbps"] = pace_kbps_;
		stats["skipped"] = f.frames_skipped.load();
		stats["overflows"] = ov;
		stats["keyReq"] = key_requests_;
		stats["rttMs"] = rtt;
		stats["loss"] = loss;
		stats["helper"] = remote_active_;
		if(!live)
			stats["reason"] = QStringLiteral("reconnecting");
		QJsonObject st;
		st["stats"] = stats;
		pushState(st);
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
	o["liveOn"] = state_ == QLatin1String("live") || state_ == QLatin1String("reconnecting");
	o["liveState"] = state_;
	o["liveViewers"] = viewers_.size();
	o["liveFps"] = beat_.fps_sum / n;
	o["liveKbps"] = beat_.kbps_sum / n;
	o["liveHeight"] = live_height_;
	o["liveLevel"] = 0;                    // 118: сходинок якості немає
	o["liveDowns"] = 0;
	o["livePausedS"] = beat_.reconnect_s;  // секунди без зв'язку (перепідключення)
	o["liveEncMs"] = 0;                    // нічого не кодуємо
	o["liveEncoder"] = QStringLiteral("passthrough");
	o["liveCodec"] = game_codec_;
	o["liveUplink"] = uplink_kbps_;
	o["liveKeyReq"] = beat_.keys;
	o["liveRtt"] = beat_.rtt_max;
#ifdef ANYPLAY_HAVE_LIVE
	if(media_)
	{
		const int sk = media_->fwd.frames_skipped.load(), ov = media_->fwd.overflows.load();
		o["liveSkipped"] = sk - beat_.skipped;
		o["liveOverflows"] = ov - beat_.overflows;
		beat_.skipped = sk;
		beat_.overflows = ov;
	}
#endif
	if(control_member_)
		o["liveCtl"] = remote_active_;
	if(handed_over_)
		o["liveHandedOver"] = true;
	const int sk = beat_.skipped, ov = beat_.overflows;
	beat_ = Beat();
	beat_.skipped = sk;
	beat_.overflows = ov;
	return o;
}
