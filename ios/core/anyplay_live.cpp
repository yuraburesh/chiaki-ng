// AnyPlay 157: трансляція друзям з iPhone та iPad — та сама медіа-частина, що на Android і комп'ютері
// (gui/src/anyplaylivemedia.cpp, libdatachannel): відео й звук гри з PS5 пересилаються в Cloudflare SFU як є, без
// перекодування. Тут — C-інтерфейс для Swift (AnyPlayLive.swift робить сигналізацію через наш сервер) і гачки потоків гри.
// Портовано з android/app/src/main/cpp/anyplay-live.cpp (JNI → прості C-функції).
#include "anyplay_core.h"
#include "anyplay_live_hooks.h"

#include <cstdio>
#include <cstring>
#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "anyplaylivemedia.h"


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

Live *live()
{
	return g_live_owner.get();
}

void requestIdr()
{
	std::lock_guard<std::mutex> lock(g_session_mutex);
	if(g_session)
		anyplay_core_request_idr(static_cast<AnyPlayCore *>(g_session));
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


// ───────────────────────────── C-інтерфейс для Swift ─────────────────────────────

namespace {
void (*g_log_cb)(const char *) = nullptr;

void copyOut(const std::string &s, char *out, size_t n)
{
	if(!out || !n)
		return;
	const size_t k = std::min(s.size(), n - 1);
	memcpy(out, s.data(), k);
	out[k] = '\0';
}
} // namespace

extern "C" {

int anyplay_live_available(void) { return 1; }

void anyplay_live_set_log(void (*cb)(const char *line))
{
	g_log_cb = cb;
	anyplaylive::setLogger([](const std::string &s) {
		if(g_log_cb)
			g_log_cb(s.c_str());
	});
}

int anyplay_live_header_ready(void)
{
	return currentHeader().valid() ? 1 : 0;
}

void anyplay_live_codec(char *out, size_t n)
{
	copyOut(anyplaylive::codecName(currentHeader().codec), out, n);
}

int64_t anyplay_live_game_bytes(void)
{
	return g_game_bytes.load();
}

int anyplay_live_create(const char *ice_urls, int pace_kbps, char *err_out, size_t err_n)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	const anyplaylive::StreamHeader header = currentHeader();
	if(!header.valid()) { copyOut("no_header", err_out, err_n); return -1; }
	if(g_live_owner) { copyOut("busy", err_out, err_n); return -1; }
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
	{
		std::string all = ice_urls ? ice_urls : "";
		size_t at = 0;
		while(at <= all.size())
		{
			size_t e = all.find('\n', at);
			if(e == std::string::npos) e = all.size();
			if(e > at) urls.push_back(all.substr(at, e - at));
			at = e + 1;
		}
	}
	if(urls.empty())
		urls.push_back("stun:stun.cloudflare.com:3478");
	std::string err;
	if(!peer->create(urls, &err)) { copyOut(err.empty() ? "create" : err, err_out, err_n); return -1; }
	const std::string fmtp = anyplaylive::sdpFmtp(header.codec, header.annexB);
	peer->addVideo(kTrackVideo, header.codec, fmtp, pace_kbps);
	peer->addAudio(kTrackGame, 2);
	peer->addAudio(kTrackMic, 1);   // сторінка глядача чекає три треки; мікрофона з iPhone поки немає
	anyplaylive::logf("publish %s %s pace %d kbps", anyplaylive::codecName(header.codec), fmtp.c_str(), pace_kbps);
	l->peer = std::move(peer);
	l->fwd.setPaceKbps(pace_kbps);
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
	l->fwd.setVideoOn(false);
	l->peer->makeOffer(true);
	g_live_owner = std::move(l);
	copyOut("", err_out, err_n);
	return 0;
}

int anyplay_live_gathered(void)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return 0;
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	return (l->gathered.load() || (l->peer && l->peer->gatheringComplete())) ? 1 : 0;
}

size_t anyplay_live_local_sdp(char *out, size_t n)
{
	std::string sdp;
	{
		std::lock_guard<std::mutex> lock(g_live_mutex);
		Live *l = live();
		if(l)
		{
			std::lock_guard<std::mutex> lk(l->peer_mutex);
			if(l->peer)
				sdp = l->peer->localSdp();
		}
	}
	copyOut(sdp, out, n);
	return sdp.size() + 1;
}

int anyplay_live_apply_answer(const char *sdp, char *err_out, size_t err_n)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l) { copyOut("closed", err_out, err_n); return -1; }
	std::string err;
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	if(!l->peer || !l->peer->applyAnswer(sdp ? sdp : "", &err)) { copyOut(err.empty() ? "answer" : err, err_out, err_n); return -1; }
	copyOut("", err_out, err_n);
	return 0;
}

void anyplay_live_state(char *out, size_t n)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l) { copyOut("off", out, n); return; }
	std::lock_guard<std::mutex> lk(l->state_mutex);
	copyOut(l->state, out, n);
}

int anyplay_live_open_channel(int id, const char *label, int ordered, int max_retransmits)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return 0;
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	return (l->peer && l->peer->openChannel(id, label ? label : "", ordered != 0, max_retransmits)) ? 1 : 0;
}

int anyplay_live_send(int id, const char *text)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return 0;
	std::lock_guard<std::mutex> lk(l->peer_mutex);
	return (l->peer && l->peer->send(id, text ? text : "")) ? 1 : 0;
}

void anyplay_live_go_live(int game_audio)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return;
	l->game_on.store(game_audio != 0);
	l->fwd.setAudioOn(true);
	l->fwd.waitKey("live");
	l->fwd.setVideoOn(true);
	g_fwd.store(l);
	requestIdr();
}

void anyplay_live_set_game_audio(int on)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	if(Live *l = live())
		l->game_on.store(on != 0);
}

void anyplay_live_set_video_on(int on)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	if(!l)
		return;
	if(on)
		l->fwd.waitKey("resume");
	l->fwd.setVideoOn(on != 0);
}

void anyplay_live_request_keyframe(void)
{
	requestIdr();
}

int anyplay_live_take_key_wanted(void)
{
	std::lock_guard<std::mutex> lock(g_live_mutex);
	Live *l = live();
	return l ? l->key_wanted.exchange(0) : 0;
}

void anyplay_live_stats(int64_t *v)
{
	if(!v)
		return;
	for(int i = 0; i < 9; i++)
		v[i] = 0;
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

void anyplay_live_close(int events_channel)
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
	if(events_channel >= 0)
	{
		std::lock_guard<std::mutex> lk(l->peer_mutex);
		if(l->peer)
			l->peer->send(events_channel, "{\"t\":\"bye\"}");
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
}

} // extern "C"
