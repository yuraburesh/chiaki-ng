// AnyPlay 118: трансляція для друзів — медіа без Qt. Див. anyplaylivemedia.h.
#include "anyplaylivemedia.h"

#include <rtc/rtc.hpp>

// Android (AnyPlay 124): без Opus — звук гри йде з PS5 як є, мікрофона й голосів глядачів на телефоні поки немає
#ifndef ANYPLAY_LIVE_NO_OPUS
#include <opus/opus.h>
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <random>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#elif defined(__APPLE__)
#include <pthread.h>
#include <sys/qos.h>
#else
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace anyplaylive {

// ───────────────────────────── журнал ─────────────────────────────

static std::mutex g_log_mutex;
static LogFn g_log;

void setLogger(LogFn fn)
{
	std::lock_guard<std::mutex> lock(g_log_mutex);
	g_log = std::move(fn);
}

void logf(const char *fmt, ...)
{
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	std::lock_guard<std::mutex> lock(g_log_mutex);
	if(g_log)
		g_log(buf);
	else
		fprintf(stderr, "[anyplay-live] %s\n", buf);
}

int64_t nowUs()
{
	return std::chrono::duration_cast<std::chrono::microseconds>(
		std::chrono::steady_clock::now().time_since_epoch()).count();
}

// потік пересилання не має відбирати час у гри: нижчий пріоритет
static void lowerThreadPriority()
{
#if defined(_WIN32)
	SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#elif defined(__APPLE__)
	pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#else
	setpriority(PRIO_PROCESS, static_cast<id_t>(syscall(SYS_gettid)), 10);
#endif
}

// ───────────────────────────── потік відео з PS5 ─────────────────────────────

const char *codecName(Codec c)
{
	switch(c)
	{
		case Codec::H264: return "H.264";
		case Codec::H265: return "H.265";
		default: return "";
	}
}

static int nalType(Codec c, const uint8_t *p, size_t n)
{
	if(!n)
		return -1;
	if(c == Codec::H264)
		return p[0] & 0x1f;
	if(c == Codec::H265)
		return (p[0] >> 1) & 0x3f;
	return -1;
}

std::vector<NalView> splitAnnexB(const uint8_t *d, size_t n, Codec codec)
{
	std::vector<NalView> out;
	if(!d || n < 4)
		return out;
	// початок кожної NAL: після 00 00 01 (00 00 00 01 теж закінчується на 00 00 01)
	std::vector<size_t> starts;
	for(size_t k = 0; k + 3 <= n; k++)
	{
		if(d[k] == 0 && d[k + 1] == 0 && d[k + 2] == 1)
		{
			starts.push_back(k + 3);
			k += 2;
		}
	}
	for(size_t i = 0; i < starts.size(); i++)
	{
		const size_t from = starts[i];
		size_t to = i + 1 < starts.size() ? starts[i + 1] - 3 : n;
		// кінцеві нулі: нуль перед 00 00 00 01, вирівнювання chiaki (CHIAKI_VIDEO_BUFFER_PADDING_SIZE).
		// Справжня NAL-одиниця нулем не закінчується (rbsp_trailing_bits), тож відкидати їх безпечно.
		while(to > from && d[to - 1] == 0)
			to--;
		if(to <= from)
			continue;
		NalView v;
		v.data = d + from;
		v.size = to - from;
		v.type = nalType(codec, v.data, v.size);
		out.push_back(v);
	}
	return out;
}

Codec headerCodec(const uint8_t *nal, size_t n)
{
	if(!nal || n < 2 || (nal[0] & 0x80))
		return Codec::Unknown;   // forbidden_zero_bit
	// H.265 VPS/SPS: 2-байтовий заголовок 0x40 0x01 / 0x42 0x01 (шар 0, tid 1). Байт 0x41 сам по собі — це ще й
	// звичайний P-кадр H.264 (nal_ref_idc 2, тип 1), тому другий байт обов'язковий.
	if((nal[0] == 0x40 || nal[0] == 0x42) && nal[1] == 0x01)
		return Codec::H265;
	// H.264 SPS: тип 7 з будь-яким nal_ref_idc (0x67, 0x47, 0x27, 0x07)
	if((nal[0] & 0x1f) == 7)
		return Codec::H264;
	return Codec::Unknown;
}

Codec detectCodec(const uint8_t *d, size_t n)
{
	// перша NAL: H.264 SPS або H.265 VPS/SPS
	const auto nals = splitAnnexB(d, n, Codec::Unknown);
	if(nals.empty())
		return Codec::Unknown;
	return headerCodec(nals[0].data, nals[0].size);
}

bool isParameterSet(Codec c, int type)
{
	if(c == Codec::H264)
		return type == 7 || type == 8;
	if(c == Codec::H265)
		return type == 32 || type == 33 || type == 34;
	return false;
}

bool isKeyNal(Codec c, int type)
{
	if(c == Codec::H264)
		return type == 5;
	if(c == Codec::H265)
		return type >= 16 && type <= 21;
	return false;
}

bool isSliceNal(Codec c, int type)
{
	if(c == Codec::H264)
		return type >= 1 && type <= 5;
	if(c == Codec::H265)
		return type >= 0 && type <= 31;
	return false;
}

// перші байти RBSP без захисних 0x03 (00 00 03 → 00 00)
static std::vector<uint8_t> rbspHead(const uint8_t *p, size_t n, size_t want)
{
	std::vector<uint8_t> out;
	int zeros = 0;
	for(size_t i = 0; i < n && out.size() < want; i++)
	{
		if(zeros >= 2 && p[i] == 3)
		{
			zeros = 0;
			continue;
		}
		zeros = p[i] == 0 ? zeros + 1 : 0;
		out.push_back(p[i]);
	}
	return out;
}

std::string sdpFmtp(Codec c, const std::vector<uint8_t> &paramSets)
{
	const auto nals = splitAnnexB(paramSets.data(), paramSets.size(), c);
	char buf[160];
	if(c == Codec::H264)
	{
		// profile-level-id = profile_idc, constraint flags, level_idc із SPS
		for(const NalView &v : nals)
			if(v.type == 7 && v.size >= 4)
			{
				const auto r = rbspHead(v.data + 1, v.size - 1, 3);
				if(r.size() == 3)
				{
					snprintf(buf, sizeof(buf), "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=%02x%02x%02x",
						r[0], r[1], r[2]);
					return buf;
				}
			}
		return "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f";
	}
	if(c == Codec::H265)
	{
		// profile_tier_level у SPS: після NAL-заголовка (2 байти) і першого байта (vps id, sub_layers, nesting)
		for(const NalView &v : nals)
			if(v.type == 33 && v.size >= 16)
			{
				const auto r = rbspHead(v.data + 2, v.size - 2, 13);
				if(r.size() == 13)
				{
					const int tier = (r[1] >> 5) & 1;
					const int profile = r[1] & 0x1f;
					const int level = r[12];
					snprintf(buf, sizeof(buf), "level-id=%d;profile-id=%d;tier-flag=%d;tx-mode=SRST", level, profile ? profile : 1, tier);
					return buf;
				}
			}
		return "level-id=153;profile-id=1;tier-flag=0;tx-mode=SRST";
	}
	return std::string();
}

static void appendAnnexB(std::vector<uint8_t> &out, const NalView &v)
{
	static const uint8_t sc[4] = { 0, 0, 0, 1 };
	out.insert(out.end(), sc, sc + 4);
	out.insert(out.end(), v.data, v.data + v.size);
}

bool parseHeaderSample(const uint8_t *d, size_t n, StreamHeader *out)
{
	const Codec c = detectCodec(d, n);
	if(c == Codec::Unknown)
		return false;
	const auto nals = splitAnnexB(d, n, c);
	std::vector<uint8_t> sets;
	for(const NalView &v : nals)
	{
		if(isSliceNal(c, v.type))
			return false;   // це кадр (з параметрами всередині), а не окремий заголовок
		if(isParameterSet(c, v.type))
			appendAnnexB(sets, v);
	}
	if(sets.empty())
		return false;
	if(out)
	{
		out->codec = c;
		out->annexB = std::move(sets);
	}
	return true;
}

// ───────────────────────────── пересилання ─────────────────────────────

Forwarder::Forwarder() = default;

Forwarder::~Forwarder()
{
	stop();
}

void Forwarder::start(Codec codec, const StreamHeader &header, VideoOut video, AudioOut audio, KeyRequest key)
{
	stop();
	{
		std::lock_guard<std::mutex> lock(mutex_);
		codec_ = codec;
		header_ = header;
		video_ = std::move(video);
		audio_ = std::move(audio);
		key_ = std::move(key);
		queue_.clear();
		queued_video_ = 0;
		quit_ = false;
		queue_dropped_ = false;
	}
	vq_bytes_ = 0;
	vq_us_ = 0;
	// лічильники не обнуляємо: після обриву пересилання починається знову, а показники за ефір — спільні
	waiting_key.store(true);
	want_wait_key_.store(false);
	backlog_ms.store(0);
	running_.store(true);
	thread_ = std::thread([this]() { run(); });
}

void Forwarder::stop()
{
	running_.store(false);
	{
		std::lock_guard<std::mutex> lock(mutex_);
		quit_ = true;
	}
	cv_.notify_all();
	if(thread_.joinable())
		thread_.join();
	std::lock_guard<std::mutex> lock(mutex_);
	queue_.clear();
	queued_video_ = 0;
}

void Forwarder::setPaceKbps(int kbps)
{
	pace_kbps_.store((std::max)(2000, kbps));
}

void Forwarder::setVideoOn(bool on)
{
	video_on_.store(on);
	if(!on)
		want_wait_key_.store(true);
}

void Forwarder::waitKey(const char *why)
{
	logf("forward: wait for a key frame (%s)", why ? why : "");
	want_wait_key_.store(true);
}

void Forwarder::pushVideo(const uint8_t *data, size_t size, int64_t us)
{
	if(!running_.load(std::memory_order_relaxed) || !video_on_.load(std::memory_order_relaxed) || !data || !size)
		return;
	frames_in.fetch_add(1, std::memory_order_relaxed);
	Item it;
	it.video = true;
	it.data.assign(data, data + size);   // ~10–100 КБ стиснених байтів: мікросекунди
	it.us = us;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		// потік пересилання стоїть (не має бути): найстаріший кадр геть, далі лише з ключового
		if(queued_video_ >= 8)
		{
			for(auto i = queue_.begin(); i != queue_.end(); ++i)
				if(i->video)
				{
					queue_.erase(i);
					queued_video_--;
					break;
				}
			queue_dropped_ = true;
		}
		queue_.push_back(std::move(it));
		queued_video_++;
	}
	cv_.notify_one();
}

void Forwarder::pushAudio(const uint8_t *data, size_t size, uint32_t samples)
{
	if(!running_.load(std::memory_order_relaxed) || !audio_on_.load(std::memory_order_relaxed))
		return;
	Item it;
	it.video = false;
	if(data && size)
		it.data.assign(data, data + size);
	it.samples = samples;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		if(queue_.size() > 200)
			return;   // потік пересилання стоїть: старий звук не потрібен
		queue_.push_back(std::move(it));
	}
	cv_.notify_one();
}

void Forwarder::run()
{
	lowerThreadPriority();
	while(true)
	{
		Item it;
		bool dropped = false;
		{
			std::unique_lock<std::mutex> lock(mutex_);
			cv_.wait(lock, [this]() { return quit_ || !queue_.empty(); });
			if(quit_)
				break;
			it = std::move(queue_.front());
			queue_.pop_front();
			if(it.video)
				queued_video_--;
			dropped = queue_dropped_;
			queue_dropped_ = false;
		}
		if(dropped)
		{
			want_wait_key_.store(true);
			overflows.fetch_add(1);
		}
		if(it.video)
			handleVideo(it);
		else if(audio_)
		{
			audio_(it.data.data(), it.data.size(), it.samples);
			if(!it.data.empty())
				audio_sent.fetch_add(1, std::memory_order_relaxed);
		}
	}
}

void Forwarder::handleVideo(Item &it)
{
	if(want_wait_key_.exchange(false))
	{
		if(!waiting_key.exchange(true) && key_)
			key_("resume");
	}
	// заголовок, що прийшов у потоці (нова роздільність): запам'ятовуємо, далі він іде перед кожним ключовим
	StreamHeader hdr;
	if(parseHeaderSample(it.data.data(), it.data.size(), &hdr))
	{
		if(hdr.codec == codec_)
			header_ = std::move(hdr);
		return;
	}
	const auto nals = splitAnnexB(it.data.data(), it.data.size(), codec_);
	bool key = false, has_params = false, has_slice = false;
	for(const NalView &v : nals)
	{
		if(isKeyNal(codec_, v.type))
			key = true;
		if(isParameterSet(codec_, v.type))
			has_params = true;
		if(isSliceNal(codec_, v.type))
			has_slice = true;
	}
	if(!has_slice)
		return;
	const int64_t now = nowUs();
	// віртуальна черга пейсера: скільки ще не вийшло в мережу при нашій межі швидкості
	const double bytes_per_us = pace_kbps_.load(std::memory_order_relaxed) * 1000.0 / 8.0 / 1e6;
	if(vq_us_)
		vq_bytes_ = (std::max)(0.0, vq_bytes_ - (now - vq_us_) * bytes_per_us);
	vq_us_ = now;
	backlog_ms.store(static_cast<int>(vq_bytes_ / bytes_per_us / 1000.0), std::memory_order_relaxed);

	if(waiting_key.load())
	{
		if(!key)
		{
			frames_skipped.fetch_add(1, std::memory_order_relaxed);
			return;
		}
		waiting_key.store(false);
	}
	// канал не встигає (понад 0,6 с у черзі): цей і наступні кадри глядачам не шлемо до ключового.
	// Гравця це не стосується: його гра йде своїм шляхом, а ми не шлемо в мережу більше, ніж вона витримує.
	if(vq_bytes_ / bytes_per_us > 600000.0)
	{
		frames_skipped.fetch_add(1, std::memory_order_relaxed);
		overflows.fetch_add(1, std::memory_order_relaxed);
		waiting_key.store(true);
		if(key_)
			key_("uplink");
		return;
	}
	// кадр з 4-байтовими довжинами NAL; перед ключовим — параметри (новий глядач без них не покаже нічого)
	out_.clear();
	auto put = [this](const uint8_t *p, size_t n) {
		const uint32_t len = static_cast<uint32_t>(n);
		const uint8_t be[4] = { uint8_t(len >> 24), uint8_t(len >> 16), uint8_t(len >> 8), uint8_t(len) };
		out_.insert(out_.end(), be, be + 4);
		out_.insert(out_.end(), p, p + n);
	};
	if(key && !has_params && header_.valid())
		for(const NalView &v : splitAnnexB(header_.annexB.data(), header_.annexB.size(), codec_))
			put(v.data, v.size);
	for(const NalView &v : nals)
	{
		// AUD і SEI глядачам не потрібні; решту — як є
		if(codec_ == Codec::H264 && (v.type == 9 || v.type == 6))
			continue;
		if(codec_ == Codec::H265 && (v.type == 35 || v.type == 39 || v.type == 40))
			continue;
		put(v.data, v.size);
	}
	vq_bytes_ += out_.size() * 1.04;   // + заголовки RTP/SRTP
	if(key)
		keyframes.fetch_add(1, std::memory_order_relaxed);
	frames_sent.fetch_add(1, std::memory_order_relaxed);
	bytes_sent.fetch_add(static_cast<int64_t>(out_.size()), std::memory_order_relaxed);
	if(video_)
		video_(out_, key, it.us);
}

#ifndef ANYPLAY_LIVE_NO_OPUS
// ───────────────────────────── звук ─────────────────────────────

OpusPacker::~OpusPacker()
{
	close();
}

bool OpusPacker::open(int channels, int kbps, bool voice)
{
	close();
	int err = 0;
	enc_ = opus_encoder_create(48000, channels, voice ? OPUS_APPLICATION_VOIP : OPUS_APPLICATION_AUDIO, &err);
	if(!enc_ || err != OPUS_OK)
	{
		enc_ = nullptr;
		return false;
	}
	opus_encoder_ctl(enc_, OPUS_SET_BITRATE(kbps * 1000));
	opus_encoder_ctl(enc_, OPUS_SET_COMPLEXITY(5));   // мало процесора
	opus_encoder_ctl(enc_, OPUS_SET_INBAND_FEC(1));
	opus_encoder_ctl(enc_, OPUS_SET_PACKET_LOSS_PERC(5));
	channels_ = channels;
	buf_.clear();
	pkt_.resize(1500);
	return true;
}

void OpusPacker::close()
{
	if(enc_)
		opus_encoder_destroy(enc_);
	enc_ = nullptr;
	buf_.clear();
}

void OpusPacker::push(const int16_t *pcm, size_t frames, const std::function<void(const uint8_t *, size_t, int)> &out)
{
	if(!enc_)
		return;
	const size_t n = frames * static_cast<size_t>(channels_);
	const size_t at = buf_.size();
	buf_.insert(buf_.end(), pcm, pcm + n);
	const float gain = gain_.load();
	if(gain != 1.0f)
	{
		for(size_t i = at; i < buf_.size(); i++)
			buf_[i] = static_cast<int16_t>(std::clamp(static_cast<int>(buf_[i] * gain), -32768, 32767));
	}
	const size_t frame = 960 * static_cast<size_t>(channels_);   // 20 мс
	size_t pos = 0;
	while(buf_.size() - pos >= frame)
	{
		const int len = opus_encode(enc_, buf_.data() + pos, 960, pkt_.data(), static_cast<opus_int32>(pkt_.size()));
		pos += frame;
		if(len > 0 && out)
			out(pkt_.data(), static_cast<size_t>(len), 960);
	}
	if(pos)
		buf_.erase(buf_.begin(), buf_.begin() + static_cast<long>(pos));
	// гра може прислати звук ривком після паузи: довше 200 мс у черзі не тримаємо
	if(buf_.size() > frame * 10)
		buf_.erase(buf_.begin(), buf_.end() - static_cast<long>(frame));
}

VoiceMixer::~VoiceMixer()
{
	clear();
}

void VoiceMixer::pushOpus(const std::string &who, const uint8_t *data, size_t size)
{
	if(!enabled_.load())
		return;
	int16_t pcm[5760 * 2];
	std::lock_guard<std::mutex> lock(mutex_);
	if(muted_.count(who) && muted_[who])
		return;
	Voice &v = voices_[who];
	if(!v.dec)
	{
		int err = 0;
		v.dec = opus_decoder_create(48000, 2, &err);
		if(!v.dec || err != OPUS_OK)
		{
			v.dec = nullptr;
			return;
		}
	}
	const int n = opus_decode(v.dec, data, static_cast<opus_int32>(size), pcm, 5760, 0);
	if(n <= 0)
		return;
	int64_t sum = 0;
	for(int i = 0; i < n * 2; i++)
	{
		v.pcm.push_back(pcm[i]);
		sum += static_cast<int64_t>(pcm[i]) * pcm[i];
	}
	const double rms = std::sqrt(static_cast<double>(sum) / (n * 2));
	if(rms > 600.0)
		v.last_loud_us = nowUs();
	// черга не довша за 200 мс: голос має йти з малою затримкою
	const size_t max = 48000 / 5 * 2;
	while(v.pcm.size() > max)
		v.pcm.pop_front();
}

void VoiceMixer::pull(int16_t *out, size_t frames)
{
	std::vector<int32_t> acc(frames * 2, 0);
	{
		std::lock_guard<std::mutex> lock(mutex_);
		for(auto &it : voices_)
		{
			Voice &v = it.second;
			const size_t take = (std::min)(v.pcm.size(), frames * 2);
			for(size_t i = 0; i < take; i++)
			{
				acc[i] += v.pcm.front();
				v.pcm.pop_front();
			}
		}
	}
	const float vol = enabled_.load() ? volume_.load() : 0.0f;
	for(size_t i = 0; i < frames * 2; i++)
		out[i] = static_cast<int16_t>(std::clamp(static_cast<int>(acc[i] * vol), -32768, 32767));
}

void VoiceMixer::remove(const std::string &who)
{
	std::lock_guard<std::mutex> lock(mutex_);
	auto it = voices_.find(who);
	if(it == voices_.end())
		return;
	if(it->second.dec)
		opus_decoder_destroy(it->second.dec);
	voices_.erase(it);
}

void VoiceMixer::setMuted(const std::string &who, bool muted)
{
	std::lock_guard<std::mutex> lock(mutex_);
	muted_[who] = muted;
	if(muted)
	{
		auto it = voices_.find(who);
		if(it != voices_.end())
			it->second.pcm.clear();
	}
}

void VoiceMixer::clear()
{
	std::lock_guard<std::mutex> lock(mutex_);
	for(auto &it : voices_)
		if(it.second.dec)
			opus_decoder_destroy(it.second.dec);
	voices_.clear();
}

std::vector<std::string> VoiceMixer::speaking() const
{
	std::vector<std::string> list;
	const int64_t now = nowUs();
	std::lock_guard<std::mutex> lock(mutex_);
	for(const auto &it : voices_)
		if(it.second.last_loud_us && now - it.second.last_loud_us < 400000)
			list.push_back(it.first);
	return list;
}

#endif // ANYPLAY_LIVE_NO_OPUS

// ───────────────────────────── WebRTC ─────────────────────────────

static bool g_rtc_log_init = false;

Peer::Peer(Callbacks cb) : cb_(std::move(cb))
{
	if(!g_rtc_log_init)
	{
		g_rtc_log_init = true;
		rtc::InitLogger(rtc::LogLevel::Warning, [](rtc::LogLevel level, std::string message) {
			logf("rtc%s: %s", level <= rtc::LogLevel::Error ? " error" : "", message.c_str());
		});
	}
}

Peer::~Peer()
{
	close();
}

bool Peer::create(const std::vector<std::string> &iceUrls, std::string *err)
{
	try
	{
		rtc::Configuration c;
		for(const std::string &u : iceUrls)
			c.iceServers.emplace_back(u);
		c.disableAutoNegotiation = true;   // кожен offer/answer іде через наш сервер, по черзі
		c.mtu = 1200;
		pc_ = std::make_shared<rtc::PeerConnection>(c);
	}
	catch(const std::exception &e)
	{
		*err = e.what();
		return false;
	}
	pc_->onStateChange([this](rtc::PeerConnection::State s) {
		const char *name = "new";
		switch(s)
		{
			case rtc::PeerConnection::State::New: name = "new"; break;
			case rtc::PeerConnection::State::Connecting: name = "connecting"; break;
			case rtc::PeerConnection::State::Connected: name = "connected"; break;
			case rtc::PeerConnection::State::Disconnected: name = "disconnected"; break;
			case rtc::PeerConnection::State::Failed: name = "failed"; break;
			case rtc::PeerConnection::State::Closed: name = "closed"; break;
		}
		connected_.store(s == rtc::PeerConnection::State::Connected);
		if(cb_.state)
			cb_.state(name);
	});
	pc_->onGatheringStateChange([this](rtc::PeerConnection::GatheringState s) {
		if(s == rtc::PeerConnection::GatheringState::Complete && cb_.gathered)
			cb_.gathered();
	});
	pc_->onTrack([this](std::shared_ptr<rtc::Track> track) {
		// голос глядача (SFU прислав у своєму offer)
		const std::string mid = track->mid();
		auto depack = std::make_shared<rtc::OpusRtpDepacketizer>();
		depack->addToChain(std::make_shared<rtc::RtcpReceivingSession>());
		track->setMediaHandler(depack);
		track->onFrame([this, mid](rtc::binary data, rtc::FrameInfo) {
			if(cb_.remoteAudio)
				cb_.remoteAudio(mid, reinterpret_cast<const uint8_t *>(data.data()), data.size());
		});
		std::lock_guard<std::mutex> lock(mutex_);
		remote_.push_back(track);
	});
	pc_->onDataChannel([this](std::shared_ptr<rtc::DataChannel> dc) {
		// «server-events» від SFU: службовий, лише тримаємо
		std::lock_guard<std::mutex> lock(mutex_);
		channels_[-1 - static_cast<int>(channels_.size())] = dc;
	});
	return true;
}

void Peer::close()
{
	std::shared_ptr<rtc::PeerConnection> pc;
	std::map<int, std::shared_ptr<rtc::DataChannel>> channels;
	std::vector<std::shared_ptr<rtc::Track>> remote;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		pc = std::move(pc_);
		channels.swap(channels_);
		remote.swap(remote_);
	}
	for(auto &it : channels)
		if(it.second)
		{
			it.second->resetCallbacks();
			it.second->close();
		}
	for(auto &t : remote)
		t->resetCallbacks();
	if(bootstrap_)
	{
		bootstrap_->close();
		bootstrap_.reset();
	}
	if(pc)
	{
		pc->resetCallbacks();
		pc->close();
	}
	out_.clear();
	connected_.store(false);
}

static uint32_t randomSsrc()
{
	std::random_device rd;
	return static_cast<uint32_t>(rd()) | 1u;
}

// Звіти SFU про наше відео (RTCP RR, а також блоки звітів усередині SR): втрати й час туди-назад — для журналу й
// К14. Нічого не змінює сам: трансляція не стає на паузу й не знижує якість гри.
class RtcpWatch final : public rtc::MediaHandler
{
public:
	explicit RtcpWatch(Peer *peer) : peer_(peer) {}
	void incoming(rtc::message_vector &messages, const rtc::message_callback &) override
	{
		for(const auto &m : messages)
			if(m && m->type == rtc::Message::Control)
				parse(reinterpret_cast<const uint8_t *>(m->data()), m->size());
	}

private:
	static uint32_t be32(const uint8_t *p) { return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3]; }
	void parse(const uint8_t *d, size_t n)
	{
		size_t off = 0;
		while(off + 8 <= n)
		{
			const uint8_t *h = d + off;
			const int count = h[0] & 0x1f;
			const int pt = h[1];
			const size_t len = (size_t(h[2]) << 8 | h[3]) * 4 + 4;
			if(len < 8 || off + len > n)
				break;
			size_t blocks = 0;
			if(pt == 201)
				blocks = 8;           // RR: заголовок + SSRC відправника
			else if(pt == 200)
				blocks = 28;          // SR: + відомості відправника
			if(blocks)
				for(int i = 0; i < count && blocks + 24 <= len; i++, blocks += 24)
				{
					const uint8_t *b = h + blocks;
					peer_->loss_frac_.store(b[4]);
					const uint32_t lsr = be32(b + 16), dlsr = be32(b + 20);
					if(lsr)
					{
						// той самий годинник, що в RtcpSrReporter (system_clock у NTP), середні 32 біти
						const double secs = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
						const uint64_t ntp = uint64_t(std::floor((secs + 2208988800.) * double(uint64_t(1) << 32)));
						const uint32_t mid = uint32_t(ntp >> 16);
						const uint32_t rtt = mid - lsr - dlsr;   // одиниці 1/65536 с
						if(rtt < 65536u * 5)
							peer_->rtt_ms_.store(static_cast<int>(rtt * 1000.0 / 65536.0));
					}
				}
			off += len;
		}
	}
	Peer *peer_;
};

void Peer::addVideo(const std::string &mid, Codec codec, const std::string &fmtp, double paceKbps)
{
	if(!pc_)
		return;
	const uint32_t ssrc = randomSsrc();
	rtc::Description::Video media(mid, rtc::Description::Direction::SendOnly);
	// той самий кодек і профіль, що прийшов з PS5 (fmtp з її SPS): браузер глядача розкодовує те саме, що й гравець
	if(codec == Codec::H265)
		media.addH265Codec(98, fmtp);
	else
		media.addH264Codec(96, fmtp);
	media.addSSRC(ssrc, std::string("anyplay-") + mid, std::string("anyplay"), mid);
	auto track = pc_->addTrack(media);
	const int pt = codec == Codec::H265 ? 98 : 96;
	auto cfg = std::make_shared<rtc::RtpPacketizationConfig>(ssrc, "anyplay-" + mid, static_cast<uint8_t>(pt), rtc::H264RtpPacketizer::ClockRate);
	std::shared_ptr<rtc::RtpPacketizer> pack;
	// кадри приходять з 4-байтовими довжинами NAL (Forwarder): без пошуку стартових кодів наново
	if(codec == Codec::H265)
		pack = std::make_shared<rtc::H265RtpPacketizer>(rtc::NalUnit::Separator::Length, cfg, 1100);
	else
		pack = std::make_shared<rtc::H264RtpPacketizer>(rtc::NalUnit::Separator::Length, cfg, 1100);
	pack->addToChain(std::make_shared<rtc::RtcpSrReporter>(cfg));
	pack->addToChain(std::make_shared<rtc::RtcpNackResponder>(2048));
	pack->addToChain(std::make_shared<rtc::PliHandler>([this]() {
		if(cb_.keyframe)
			cb_.keyframe();
	}));
	pack->addToChain(std::make_shared<RtcpWatch>(this));
	// ключовий кадр не вилітає одним шматком: рівно, не швидше межі з перевірки інтернету (Forwarder рахує ту саму чергу)
	pack->addToChain(std::make_shared<rtc::PacingHandler>(paceKbps * 1000.0, std::chrono::milliseconds(5)));
	track->setMediaHandler(pack);
	Out o;
	o.track = track;
	o.cfg = cfg;
	out_[mid] = o;
}

void Peer::addAudio(const std::string &mid, int channels)
{
	if(!pc_)
		return;
	const uint32_t ssrc = randomSsrc();
	rtc::Description::Audio media(mid, rtc::Description::Direction::SendOnly);
	media.addOpusCodec(111, channels == 2 ? std::string("minptime=10;maxaveragebitrate=128000;stereo=1;sprop-stereo=1;useinbandfec=1")
		: std::string("minptime=10;useinbandfec=1"));
	media.addSSRC(ssrc, std::string("anyplay-") + mid, std::string("anyplay"), mid);
	auto track = pc_->addTrack(media);
	auto cfg = std::make_shared<rtc::RtpPacketizationConfig>(ssrc, "anyplay-" + mid, 111, rtc::OpusRtpPacketizer::DefaultClockRate);
	auto pack = std::make_shared<rtc::OpusRtpPacketizer>(cfg);
	pack->addToChain(std::make_shared<rtc::RtcpSrReporter>(cfg));
	track->setMediaHandler(pack);
	Out o;
	o.track = track;
	o.cfg = cfg;
	out_[mid] = o;
}

// id тимчасового каналу: останній із 1024 потоків SCTP, які домовляє libdatachannel; SFU роздає id з початку
static const uint16_t kBootstrapChannelId = 1023;

void Peer::makeOffer(bool withData)
{
	if(!pc_)
		return;
	if(withData && !bootstrap_)
	{
		rtc::DataChannelInit init;
		init.negotiated = true;
		init.id = kBootstrapChannelId;
		try
		{
			bootstrap_ = pc_->createDataChannel("anyplay-sctp", init);
		}
		catch(const std::exception &e)
		{
			logf("bootstrap channel: %s", e.what());
		}
	}
	pc_->setLocalDescription(rtc::Description::Type::Offer);
}

bool Peer::applyAnswer(const std::string &sdp, std::string *err)
{
	try
	{
		pc_->setRemoteDescription(rtc::Description(sdp, rtc::Description::Type::Answer));
	}
	catch(const std::exception &e)
	{
		*err = e.what();
		return false;
	}
	// m=application уже домовлено: тимчасовий канал більше не потрібен (id 1023 звільняється)
	if(bootstrap_)
	{
		bootstrap_->close();
		bootstrap_.reset();
	}
	return true;
}

bool Peer::applyOffer(const std::string &sdp, std::string *err)
{
	try
	{
		pc_->setRemoteDescription(rtc::Description(sdp, rtc::Description::Type::Offer));
		pc_->setLocalDescription(rtc::Description::Type::Answer);
	}
	catch(const std::exception &e)
	{
		*err = e.what();
		return false;
	}
	return true;
}

std::string Peer::localSdp() const
{
	if(!pc_)
		return std::string();
	auto d = pc_->localDescription();
	return d ? std::string(*d) : std::string();
}

bool Peer::gatheringComplete() const
{
	return pc_ && pc_->gatheringState() == rtc::PeerConnection::GatheringState::Complete;
}

bool Peer::openChannel(int id, const std::string &label, bool ordered, int maxRetransmits)
{
	if(!pc_ || id < 0)
		return false;
	rtc::DataChannelInit init;
	init.negotiated = true;
	init.id = static_cast<uint16_t>(id);
	init.reliability.unordered = !ordered;
	if(maxRetransmits >= 0)
		init.reliability.maxRetransmits = static_cast<unsigned int>(maxRetransmits);
	std::shared_ptr<rtc::DataChannel> dc;
	try
	{
		dc = pc_->createDataChannel(label, init);
	}
	catch(const std::exception &e)
	{
		logf("data channel %s/%d: %s", label.c_str(), id, e.what());
		return false;
	}
	dc->onOpen([this, id]() {
		if(cb_.channelState)
			cb_.channelState(id, true);
	});
	dc->onClosed([this, id]() {
		if(cb_.channelState)
			cb_.channelState(id, false);
	});
	dc->onMessage([this, id](rtc::binary data) {
		if(cb_.binary)
			cb_.binary(id, reinterpret_cast<const uint8_t *>(data.data()), data.size());
	}, [this, id](rtc::string text) {
		if(cb_.message)
			cb_.message(id, text);
	});
	std::lock_guard<std::mutex> lock(mutex_);
	channels_[id] = dc;
	return true;
}

void Peer::closeChannel(int id)
{
	std::shared_ptr<rtc::DataChannel> dc;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		auto it = channels_.find(id);
		if(it == channels_.end())
			return;
		dc = it->second;
		channels_.erase(it);
	}
	dc->resetCallbacks();
	dc->close();
}

bool Peer::send(int id, const std::string &text)
{
	std::shared_ptr<rtc::DataChannel> dc;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		auto it = channels_.find(id);
		if(it == channels_.end())
			return false;
		dc = it->second;
	}
	if(!dc->isOpen())
		return false;
	try
	{
		return dc->send(text);
	}
	catch(const std::exception &)
	{
		return false;
	}
}

size_t Peer::buffered(int id) const
{
	std::lock_guard<std::mutex> lock(mutex_);
	auto it = channels_.find(id);
	return it == channels_.end() ? 0 : it->second->bufferedAmount();
}

void Peer::sendVideo(const std::vector<uint8_t> &au, int64_t captureUs)
{
	auto it = out_.find("video");
	if(it == out_.end() || !it->second.track || !it->second.track->isOpen())
		return;
	if(!video_start_us_ || captureUs < video_start_us_)
		video_start_us_ = captureUs;
	const double sec = static_cast<double>(captureUs - video_start_us_) / 1e6;
	try
	{
		it->second.track->sendFrame(reinterpret_cast<const rtc::byte *>(au.data()), au.size(),
			rtc::FrameInfo(std::chrono::duration<double>(sec)));
		video_bytes_.fetch_add(static_cast<int64_t>(au.size()), std::memory_order_relaxed);
	}
	catch(const std::exception &e)
	{
		logf("video send: %s", e.what());
	}
}

void Peer::sendAudio(const std::string &mid, const uint8_t *data, size_t size, int samples)
{
	auto it = out_.find(mid);
	if(it == out_.end() || !it->second.track || !it->second.track->isOpen())
		return;
	Out &o = it->second;
	const double sec = static_cast<double>(o.ts) / 48000.0;
	o.ts += static_cast<uint32_t>(samples);
	if(!data || !size)
		return;   // PS5 загубила пакет: час іде далі, браузер сам заповнить тишею
	try
	{
		o.track->sendFrame(reinterpret_cast<const rtc::byte *>(data), size, rtc::FrameInfo(std::chrono::duration<double>(sec)));
	}
	catch(const std::exception &e)
	{
		logf("audio send %s: %s", mid.c_str(), e.what());
	}
}

} // namespace anyplaylive
