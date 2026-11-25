// AnyPlay 116: трансляція для друзів — медіа без Qt (кодування відео й звуку, WebRTC через libdatachannel).
// Усе тут працює у своїх потоках і не торкається з'єднання з PS5: кадри приходять копією-посиланням
// (av_frame_clone), звук — копією, а вихід іде лише в SFU Cloudflare.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct AVFrame;
struct AVCodecContext;
struct SwsContext;
struct OpusEncoder;
struct OpusDecoder;

namespace rtc {
class PeerConnection;
class Track;
class DataChannel;
class RtpPacketizationConfig;
}

namespace anyplaylive {

// журнал: рядки без префікса, AnyPlayLive додає «[anyplay-live]»
using LogFn = std::function<void(const std::string &)>;
void setLogger(LogFn fn);
void logf(const char *fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
	__attribute__((format(printf, 1, 2)))
#endif
	;

int64_t nowUs();

// ───────────────────────────── відео ─────────────────────────────

struct VideoConfig
{
	int width = 1280;
	int height = 720;
	int fps = 30;
	int kbps = 2500;
};

// Апаратний кодувальник H.264 через FFmpeg. Не потокобезпечний: живе в потоці кодування.
class VideoEncoder
{
public:
	~VideoEncoder();
	// пробує апаратні кодувальники цієї системи по черзі; allowSoftware — лише для тестів (libx264)
	bool open(const VideoConfig &cfg, bool allowSoftware, std::string *err);
	void close();
	bool isOpen() const { return ctx_ != nullptr; }
	// src — розкодований кадр гри (апаратний чи звичайний). out — один кадр H.264 Annex-B (із SPS/PPS перед ключовим)
	bool encode(const AVFrame *src, bool forceKey, std::vector<uint8_t> *out, bool *isKey, std::string *err);
	const std::string &name() const { return name_; }
	const VideoConfig &config() const { return cfg_; }
	double lastTransferMs() const { return transfer_ms_; }
	double lastScaleMs() const { return scale_ms_; }
	double lastEncodeMs() const { return encode_ms_; }
	// які кодувальники пробувати на цій системі (у порядку)
	static std::vector<std::string> candidates(bool allowSoftware);

private:
	bool openNamed(const std::string &codec_name, const VideoConfig &cfg, std::string *err);
	bool prepareInput(const AVFrame *src, std::string *err);
	void rememberParameterSets(const uint8_t *data, size_t size);

	VideoConfig cfg_;
	std::string name_;
	AVCodecContext *ctx_ = nullptr;
	SwsContext *sws_ = nullptr;
	AVFrame *sw_ = nullptr;       // копія з відеокарти (якщо кадр апаратний)
	AVFrame *scaled_ = nullptr;   // NV12 потрібного розміру
	int sws_src_w_ = 0, sws_src_h_ = 0, sws_src_fmt_ = -1;
	int64_t pts_ = 0;
	std::vector<uint8_t> sps_pps_;   // останні SPS/PPS (для ключових кадрів, де кодувальник їх не повторив)
	double transfer_ms_ = 0, scale_ms_ = 0, encode_ms_ = 0;
};

// Потік кодування: приймає кадри (замінює непрочитаний новим), кодує з низьким пріоритетом, віддає готові кадри.
class VideoPipeline
{
public:
	using Output = std::function<void(const std::vector<uint8_t> &au, bool key, int64_t captureUs)>;
	using Status = std::function<void(bool ok, const std::string &encoder, const std::string &err)>;
	VideoPipeline();
	~VideoPipeline();
	void start(const VideoConfig &cfg, bool allowSoftware, Output out, Status status);
	void stop();
	void reconfigure(const VideoConfig &cfg);   // нова якість: кодувальник відкривається заново в потоці
	void requestKeyframe() { want_key_.store(true); }
	void setPaused(bool paused) { paused_.store(paused); if(!paused) next_due_us_.store(0); }
	// з потоку показу кадрів (QmlMainWindow::presentFrame): дешево; кадр береться лише коли настав час
	bool wantsFrame(int64_t now_us) const;
	void offer(const AVFrame *frame);
	VideoConfig config() const;
	// для К14 і адаптації (з будь-якого потоку)
	std::atomic<int> frames_encoded{0};
	std::atomic<int> frames_dropped{0};     // кадр прийшов, поки попередній ще кодувався
	std::atomic<int64_t> bytes_out{0};
	std::atomic<int> encode_us_avg{0};      // ковзне середнє часу на кадр (копія+масштаб+кодування)
	std::atomic<int> errors{0};

private:
	void run(bool allowSoftware);
	mutable std::mutex mutex_;
	std::condition_variable cv_;
	AVFrame *pending_ = nullptr;
	int64_t pending_us_ = 0;
	VideoConfig cfg_;
	bool reconfig_ = false;
	bool quit_ = false;
	std::thread thread_;
	Output out_;
	Status status_;
	std::atomic<bool> running_{false};
	std::atomic<bool> paused_{false};
	std::atomic<bool> want_key_{true};
	std::atomic<int64_t> next_due_us_{0};
	std::atomic<int> interval_us_{33333};
};

// ───────────────────────────── звук ─────────────────────────────

// Кодувальник Opus 48 кГц: кадри по 20 мс.
class OpusPacker
{
public:
	~OpusPacker();
	bool open(int channels, int kbps, bool voice);
	void close();
	// додати PCM (int16, перемежовано); готові пакети віддаються в out
	void push(const int16_t *pcm, size_t frames, const std::function<void(const uint8_t *, size_t, int samples)> &out);
	void setGain(float g) { gain_.store(g); }
	int channels() const { return channels_; }

private:
	OpusEncoder *enc_ = nullptr;
	int channels_ = 0;
	std::vector<int16_t> buf_;
	std::vector<uint8_t> pkt_;
	std::atomic<float> gain_{ 1.0f };
};

// Голоси глядачів: кожен — свій декодер Opus, у виході змішано, з гучністю. Читає звукова картка (SDL).
class VoiceMixer
{
public:
	~VoiceMixer();
	void pushOpus(const std::string &who, const uint8_t *data, size_t size);
	// заповнює stereo int16 48 кГц; повертає true, якщо хтось говорив
	void pull(int16_t *out, size_t frames);
	void setVolume(float v) { volume_.store(v); }
	void setEnabled(bool on) { enabled_.store(on); }
	void remove(const std::string &who);
	void setMuted(const std::string &who, bool muted);   // гравець вимкнув голос одного глядача
	void clear();
	std::vector<std::string> speaking() const;   // хто говорив останні ~400 мс

private:
	struct Voice
	{
		OpusDecoder *dec = nullptr;
		std::deque<int16_t> pcm;   // стерео, перемежовано
		int64_t last_loud_us = 0;
	};
	mutable std::mutex mutex_;
	std::map<std::string, Voice> voices_;
	std::map<std::string, bool> muted_;
	std::atomic<float> volume_{0.8f};
	std::atomic<bool> enabled_{true};
};

// ───────────────────────────── WebRTC ─────────────────────────────

// Одне з'єднання з SFU (одна сесія Cloudflare): треки гравця на відправлення, голоси глядачів на прийом, канали даних.
// Колбеки приходять у потоках libdatachannel.
class Peer
{
public:
	struct Callbacks
	{
		std::function<void(const std::string &state)> state;         // new|connecting|connected|disconnected|failed|closed
		std::function<void()> gathered;                              // кандидати зібрано (можна брати localSdp)
		std::function<void()> keyframe;                              // глядач просить ключовий кадр (PLI/FIR)
		std::function<void(unsigned kbps)> remb;                     // оцінка каналу від SFU
		std::function<void(const std::string &mid, const uint8_t *, size_t)> remoteAudio;   // пакет Opus від глядача
		std::function<void(int id, const std::string &text)> message;   // текст із каналу даних
		std::function<void(int id, const uint8_t *, size_t)> binary;   // двійкове повідомлення (ввід помічника)
		std::function<void(int id, bool open)> channelState;
	};
	explicit Peer(Callbacks cb);
	~Peer();
	bool create(const std::vector<std::string> &iceUrls, std::string *err);
	void close();
	// треки гравця (до першого offer)
	void addVideo(const std::string &mid, double paceKbps);
	void addAudio(const std::string &mid, int channels);
	// offer → sdp (після gathered) | застосувати answer.
	// withData: у першому offer одразу є m=application (канали даних) — так радить Cloudflare
	// («Media and DataChannels in the first offer»), і так обходимо обмеження libdatachannel: SCTP, доданий
	// пізнішим offer від SFU, вона пробує запустити ще до нашого answer і падає.
	void makeOffer(bool withData = true);
	bool applyAnswer(const std::string &sdp, std::string *err);
	// SFU прислав offer (нові треки/канали): застосувати й зробити answer (sdp — після gathered)
	bool applyOffer(const std::string &sdp, std::string *err);
	std::string localSdp() const;
	bool gatheringComplete() const;
	// канали даних з id від SFU (negotiated)
	bool openChannel(int id, const std::string &label, bool ordered, int maxRetransmits);
	void closeChannel(int id);
	bool send(int id, const std::string &text);
	size_t buffered(int id) const;
	// медіа
	void sendVideo(const std::vector<uint8_t> &au, int64_t captureUs);
	void sendAudio(const std::string &mid, const uint8_t *data, size_t size, int samples);
	bool connected() const { return connected_.load(); }
	int64_t videoBytesSent() const { return video_bytes_.load(); }

private:
	Callbacks cb_;
	std::shared_ptr<rtc::PeerConnection> pc_;
	struct Out
	{
		std::shared_ptr<rtc::Track> track;
		std::shared_ptr<rtc::RtpPacketizationConfig> cfg;
		int64_t start_us = 0;
		uint32_t ts = 0;
	};
	std::map<std::string, Out> out_;
	mutable std::mutex mutex_;
	std::map<int, std::shared_ptr<rtc::DataChannel>> channels_;
	std::vector<std::shared_ptr<rtc::Track>> remote_;
	std::shared_ptr<rtc::DataChannel> bootstrap_;   // тимчасовий канал лише для m=application у першому offer
	std::atomic<bool> connected_{false};
	std::atomic<int64_t> video_bytes_{0};
	int64_t video_start_us_ = 0;
};

} // namespace anyplaylive
