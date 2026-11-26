// AnyPlay 124: трансляція друзям з телефона — як на комп'ютері (gui/src/anyplaylive.cpp), без перекодування.
// Відео (ті самі NAL-одиниці H.264/H.265, що йдуть у декодер телефона) і звук гри (ті самі пакети Opus з PS5)
// пересилаються в Cloudflare SFU через WebRTC (libdatachannel). Телефон нічого не кодує й не розкодовує вдруге:
// потоки гри лише копіюють стиснені байти в чергу (мікросекунди), решта — в окремому потоці з нижчим пріоритетом.
// Медіа-частина спільна з комп'ютером: gui/src/anyplaylivemedia.cpp (тут без Opus: мікрофона й голосів поки немає).
// Сигналізацію (наш сервер /api/live/*) робить Kotlin (AnyPlayLive.kt); тут — лише WebRTC і гачки потоків гри.

#include "anyplay-live.h"

#include <jni.h>
#include <android/log.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "anyplaylivemedia.h"

#define LIVE_FCN(name) Java_com_metallic_chiaki_lib_LiveNative_##name

namespace {

const char *const kTrackVideo = "video";
const char *const kTrackGame = "game";
const char *const kTrackMic = "mic";

struct Live
{
	std::mutex peer_mutex;
	std::unique_ptr<anyplaylive::Peer> peer;
	anyplaylive::Forwarder fwd;
	std::atomic<bool> game_on{true};
	std::atomic<int> key_wanted{0};   // скільки разів просили ключовий кадр (PLI від глядачів), забирає Kotlin
	std::mutex state_mutex;
	std::string state = "new";
	std::atomic<bool> gathered{false};
};

std::mutex g_header_mutex;
anyplaylive::StreamHeader g_header;
std::atomic<int> g_header_gen{0};
std::atomic<unsigned> g_audio_frame{480};
std::atomic<int64_t> g_game_bytes{0};
std::atomic<int> g_game_frames{0};

std::mutex g_live_mutex;            // створення/знищення Live (лише потоки Kotlin)
std::unique_ptr<Live> g_live_owner;
std::atomic<Live *> g_fwd{nullptr};   // гачки потоків гри дивляться сюди
std::atomic<int> g_inflight{0};

// сесія гри для запиту ключового кадру (chiaki-jni.c)
std::mutex g_session_mutex;
void *g_session = nullptr;

anyplaylive::StreamHeader currentHeader()
{
	std::lock_guard<std::mutex> lock(g_header_mutex);
	return g_header;
}

std::string jstr(JNIEnv *env, jstring s)
{
	if(!s)
		return std::string();
	const char *c = env->GetStringUTFChars(s, nullptr);
	std::string r(c ? c : "");
	if(c)
		env->ReleaseStringUTFChars(s, c);
	return r;
}

jstring jout(JNIEnv *env, const std::string &s)
{
	return env->NewStringUTF(s.c_str());
}

Live *live()
{
	return g_live_owner.get();
}

void requestIdr()
{
	std::lock_guard<std::mutex> lock(g_session_mutex);
	if(g_session)
		anyplay_live_request_idr(g_session);
}

} // namespace

// ───────────────────────────── гачки потоків гри (C) ─────────────────────────────

extern "C" void anyplay_live_set_session(void *session)
{
	std::lock_guard<std::mutex> lock(g_session_mutex);
	g_session = session;
}

extern "C" void anyplay_live_unset_session(void *session)
{
	std::lock_guard<std::mutex> lock(g_session_mutex);
	if(g_session == session)
		g_session = nullptr;
}

extern "C" void anyplay_live_tap_video(const uint8_t *data, size_t size)
{
	if(!data || size < 5)
		return;
	g_game_bytes.fetch_add(static_cast<int64_t>(size), std::memory_order_relaxed);
	// заголовок (рідко: початок гри, зміна роздільності) — запам'ятовуємо завжди, щоб трансляцію можна було
	// ввімкнути будь-коли під час гри. Дивимось лише перші байти першої NAL.
	size_t at = data[2] == 1 ? 3 : (data[2] == 0 && data[3] == 1 ? 4 : 0);
	bool header = false;
	if(at && at + 1 < size && anyplaylive::headerCodec(data + at, size - at) != anyplaylive::Codec::Unknown)
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
	if(!header)
		g_game_frames.fetch_add(1, std::memory_order_relaxed);
	if(!g_fwd.load(std::memory_order_relaxed))
		return;
	g_inflight.fetch_add(1);
	if(Live *l = g_fwd.load())
		l->fwd.pushVideo(data, size, anyplaylive::nowUs());
	g_inflight.fetch_sub(1);
}

extern "C" void anyplay_live_tap_audio_header(unsigned channels, unsigned rate, unsigned frame_size)
{
	(void)channels;
	// Opus у WebRTC завжди з часом 48 кГц; PS5 шле 48 кГц стерео, пакети по 480 (10 мс)
	if(frame_size && rate)
		g_audio_frame.store(static_cast<unsigned>(static_cast<uint64_t>(frame_size) * 48000 / rate));
}

extern "C" void anyplay_live_tap_opus(const uint8_t *data, size_t size)
{
	g_game_bytes.fetch_add(static_cast<int64_t>(size), std::memory_order_relaxed);
	if(!g_fwd.load(std::memory_order_relaxed))
		return;
	g_inflight.fetch_add(1);
	Live *l = g_fwd.load();
	if(l && l->game_on.load(std::memory_order_relaxed))
		l->fwd.pushAudio(data, size, g_audio_frame.load(std::memory_order_relaxed));
	g_inflight.fetch_sub(1);
}

// ───────────────────────────── JNI (com.metallic.chiaki.lib.LiveNative) ─────────────────────────────

extern "C" {

JNIEXPORT jboolean JNICALL LIVE_FCN(headerReady)(JNIEnv *, jclass)
{
	return currentHeader().valid() ? JNI_TRUE : JNI_FALSE;
}

/** "H.264" | "H.265" | "" */
JNIEXPORT jstring JNICALL LIVE_FCN(codec)(JNIEnv *env, jclass)
{
	return jout(env, anyplaylive::codecName(currentHeader().codec));
}

/** Скільки байтів гри прийшло від приставки (відео + звук), для оцінки потрібного вихідного каналу */
JNIEXPORT jlong JNICALL LIVE_FCN(gameBytes)(JNIEnv *, jclass)
{
	return static_cast<jlong>(g_game_bytes.load());
}

/** Підготувати з'єднання: iceUrls — STUN від сервера. Повертає "" або текст помилки */
JNIEXPORT jstring JNICALL LIVE_FCN(create)(JNIEnv *env, jclass, jobjectArray ice, jint paceKbps)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	static bool logger = false;
	if(!logger)
	{
		logger = true;
		anyplaylive::setLogger([](const std::string &s) {
			__android_log_print(ANDROID_LOG_INFO, "AnyPlayLive", "%s", s.c_str());
		});
	}
	const anyplaylive::StreamHeader header = currentHeader();
	if(!header.valid())
		return jout(env, "no_header");
	if(g_live_owner)
		return jout(env, "busy");
	auto l = std::make_unique<Live>();
	Live *lp = l.get();
	anyplaylive::Peer::Callbacks cb;
	cb.state = [lp](const std::string &s) {
		std::lock_guard<std::mutex> lk(lp->state_mutex);
		lp->state = s;
	};
	cb.gathered = [lp]() { lp->gathered.store(true); };
	cb.keyframe = [lp]() { lp->key_wanted.fetch_add(1); };
	auto peer = std::make_unique<anyplaylive::Peer>(cb);
	std::vector<std::string> urls;
	const jsize n = ice ? env->GetArrayLength(ice) : 0;
	for(jsize i = 0; i < n; i++)
	{
		jstring s = static_cast<jstring>(env->GetObjectArrayElement(ice, i));
		urls.push_back(jstr(env, s));
		env->DeleteLocalRef(s);
	}
	if(urls.empty())
		urls.push_back("stun:stun.cloudflare.com:3478");
	std::string err;
	if(!peer->create(urls, &err))
		return jout(env, err.empty() ? "create" : err);
	const std::string fmtp = anyplaylive::sdpFmtp(header.codec, header.annexB);
	peer->addVideo(kTrackVideo, header.codec, fmtp, paceKbps);
	peer->addAudio(kTrackGame, 2);   // трек є завжди; коли звук гри вимкнено, по ньому нічого не йде
	peer->addAudio(kTrackMic, 1);    // як на комп'ютері (сторінка глядача чекає ці три треки); з телефона мікрофона поки немає
	anyplaylive::logf("publish %s %s pace %d kbps", anyplaylive::codecName(header.codec), fmtp.c_str(), (int)paceKbps);
	l->peer = std::move(peer);
	l->fwd.setPaceKbps(paceKbps);
	l->fwd.start(header.codec, header,
		[lp](const std::vector<uint8_t> &au, bool, int64_t us) {
			std::lock_guard<std::mutex> lk(lp->peer_mutex);
			if(lp->peer)
				lp->peer->sendVideo(au, us);
		},
		[lp](const uint8_t *d, size_t sz, uint32_t samples) {
			std::lock_guard<std::mutex> lk(lp->peer_mutex);
			if(lp->peer)
				lp->peer->sendAudio(kTrackGame, d, sz, static_cast<int>(samples));
		},
		[lp](const char *) { lp->key_wanted.fetch_add(1); });
	l->fwd.setVideoOn(false);   // до з'єднання кадри не беремо
	l->peer->makeOffer(true);   // m=application одразу в першому offer
	g_live_owner = std::move(l);
	return jout(env, "");
}

JNIEXPORT jboolean JNICALL LIVE_FCN(gathered)(JNIEnv *, jclass)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return JNI_FALSE;
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	return (l->gathered.load() || (l->peer && l->peer->gatheringComplete())) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jstring JNICALL LIVE_FCN(localSdp)(JNIEnv *env, jclass)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return jout(env, "");
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	return jout(env, l->peer ? l->peer->localSdp() : std::string());
}

/** Відповідь SFU на наш offer. "" — добре, інакше текст помилки */
JNIEXPORT jstring JNICALL LIVE_FCN(applyAnswer)(JNIEnv *env, jclass, jstring sdp)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return jout(env, "closed");
	std::string err;
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	if(!l->peer || !l->peer->applyAnswer(jstr(env, sdp), &err))
		return jout(env, err.empty() ? "answer" : err);
	return jout(env, "");
}

/** Стан з'єднання: new|connecting|connected|disconnected|failed|closed, або "off" */
JNIEXPORT jstring JNICALL LIVE_FCN(state)(JNIEnv *env, jclass)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return jout(env, "off");
	std::lock_guard<std::mutex> lk(l->state_mutex);
	return jout(env, l->state);
}

JNIEXPORT jboolean JNICALL LIVE_FCN(openChannel)(JNIEnv *env, jclass, jint id, jstring label, jboolean ordered, jint maxRetransmits)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return JNI_FALSE;
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	return (l->peer && l->peer->openChannel(id, jstr(env, label), ordered, maxRetransmits)) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL LIVE_FCN(send)(JNIEnv *env, jclass, jint id, jstring text)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return JNI_FALSE;
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	return (l->peer && l->peer->send(id, jstr(env, text))) ? JNI_TRUE : JNI_FALSE;
}

/** В ефір: гачки потоків гри починають класти кадри в чергу; відео з наступного ключового кадру */
JNIEXPORT void JNICALL LIVE_FCN(goLive)(JNIEnv *, jclass, jboolean gameAudio)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return;
	l->game_on.store(gameAudio);
	l->fwd.setAudioOn(true);
	l->fwd.waitKey("live");
	l->fwd.setVideoOn(true);
	g_fwd.store(l);
	requestIdr();
}

JNIEXPORT void JNICALL LIVE_FCN(setGameAudio)(JNIEnv *, jclass, jboolean on)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	if(Live *l = live())
		l->game_on.store(on);
}

/** Пауза пересилання (перепідключення до SFU): кадри не беремо; після — з ключового */
JNIEXPORT void JNICALL LIVE_FCN(setVideoOn)(JNIEnv *, jclass, jboolean on)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return;
	if(on)
		l->fwd.waitKey("resume");
	l->fwd.setVideoOn(on);
}

/** Попросити в приставки ключовий кадр (новий глядач, PLI). Частоту обмежує Kotlin */
JNIEXPORT void JNICALL LIVE_FCN(requestKeyframe)(JNIEnv *, jclass)
{
	requestIdr();
}

/** Скільки разів глядачі/пересилання просили ключовий кадр з минулого виклику */
JNIEXPORT jint JNICALL LIVE_FCN(takeKeyWanted)(JNIEnv *, jclass)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	return l ? l->key_wanted.exchange(0) : 0;
}

/** Показники: [кадрів прийшло, надіслано, пропущено, ключових, байтів надіслано, черга мс, rtt мс, втрати %, переповнень] */
JNIEXPORT jlongArray JNICALL LIVE_FCN(stats)(JNIEnv *env, jclass)
{
	jlong v[9] = {0};
	{
		std::lock_guard<std::mutex> lock(g_live_mutex);
		if(Live *l = live())
		{
			v[0] = l->fwd.frames_in.load();
			v[1] = l->fwd.frames_sent.load();
			v[2] = l->fwd.frames_skipped.load();
			v[3] = l->fwd.keyframes.load();
			v[4] = l->fwd.bytes_sent.load();
			v[5] = l->fwd.backlog_ms.load();
			std::lock_guard<std::mutex> lk(l->peer_mutex);
			if(l->peer)
			{
				v[6] = l->peer->rttMs();
				v[7] = l->peer->lossPercent();
			}
			v[8] = l->fwd.overflows.load();
		}
	}
	jlongArray r = env->NewLongArray(9);
	if(r)
		env->SetLongArrayRegion(r, 0, 9, v);
	return r;
}

/** Закрити з'єднання й зупинити пересилання (гачки гри від'єднуються першими) */
JNIEXPORT void JNICALL LIVE_FCN(close)(JNIEnv *env, jclass, jint eventsChannel)
{
	std::unique_ptr<Live> l;
	{
		std::lock_guard<std::mutex> lock(g_live_mutex);
		l = std::move(g_live_owner);
	}
	if(!l)
		return;
	g_fwd.store(nullptr);
	while(g_inflight.load())
		std::this_thread::yield();
	if(eventsChannel >= 0)
	{
		std::lock_guard<std::mutex> lk(l->peer_mutex);
		if(l->peer)
			l->peer->send(eventsChannel, "{\"t\":\"bye\"}");
	}
	l->fwd.stop();
	std::unique_ptr<anyplaylive::Peer> peer;
	{
		std::lock_guard<std::mutex> lk(l->peer_mutex);
		peer = std::move(l->peer);
	}
	if(peer)
		peer->close();
	peer.reset();
	l.reset();
	(void)env;
}

} // extern "C"
