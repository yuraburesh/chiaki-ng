// AnyPlay 118: трансляція для друзів — медіа без Qt.
// Нуль навантаження на гравця: відео й звук гри НЕ розкодовуються й НЕ кодуються заново. Програма пересилає
// глядачам ті самі NAL-одиниці H.264/H.265, що прийшли з PS5 і йдуть у декодер гравця, і ті самі пакети Opus
// (RTP-пакетування libdatachannel). Жодного копіювання кадрів з відеокарти, жодного кодувальника відео.
// Потоки chiaki лише копіюють стиснені байти в чергу (кілька мікросекунд), усе інше — в окремому потоці.
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

// ───────────────────────────── потік відео з PS5 (Annex-B) ─────────────────────────────

enum class Codec { Unknown = 0, H264 = 1, H265 = 2 };
const char *codecName(Codec c);   // "H.264" | "H.265" | ""

struct NalView
{
	const uint8_t *data = nullptr;   // без стартового коду, кінцеві нулі (вирівнювання chiaki) відкинуто
	size_t size = 0;
	int type = -1;
};

// NAL-одиниці кадру; якщо кодек невідомий — тип не рахується (-1)
std::vector<NalView> splitAnnexB(const uint8_t *d, size_t n, Codec codec);
// кодек за першою NAL-одиницею заголовка chiaki (SPS для H.264, VPS/SPS для H.265); Unknown — не заголовок
Codec detectCodec(const uint8_t *d, size_t n);
// те саме для однієї NAL (без стартового коду): дешево, для гачка в потоці chiaki
Codec headerCodec(const uint8_t *nal, size_t n);
bool isParameterSet(Codec c, int type);   // SPS/PPS (H.264), VPS/SPS/PPS (H.265)
bool isKeyNal(Codec c, int type);         // IDR (H.264: 5), IRAP (H.265: 16…21)
bool isSliceNal(Codec c, int type);
// параметри для SDP (a=fmtp) із SPS: profile-level-id для H.264, profile-id/tier-flag/level-id для H.265
std::string sdpFmtp(Codec c, const std::vector<uint8_t> &paramSetsAnnexB);

// Заголовок потоку гри (SPS/PPS або VPS/SPS/PPS), як його дала приставка
struct StreamHeader
{
	Codec codec = Codec::Unknown;
	std::vector<uint8_t> annexB;   // нормалізовано: стартові коди 00 00 00 01, без кінцевих нулів
	bool valid() const { return codec != Codec::Unknown && !annexB.empty(); }
};
// true, якщо зразок — заголовок (лише параметри, без зрізів кадру); тоді заповнює out
bool parseHeaderSample(const uint8_t *d, size_t n, StreamHeader *out);

// ───────────────────────────── пересилання (окремий потік) ─────────────────────────────

// Черга стиснених кадрів і пакетів звуку → потік пересилання → WebRTC. Нічого не кодує.
// Захист гравця від забитого вихідного каналу: пересилання ніколи не шле швидше за paceKbps (оцінка «віртуальної
// черги» пейсера). Якщо глядачам не встигаємо — кадри для ГЛЯДАЧІВ пропускаються до наступного ключового, а ефір
// не зупиняється й гра гравця нічого не помічає.
class Forwarder
{
public:
	// au — кадр із 4-байтовими довжинами NAL (Separator::Length); key — ключовий (параметри вже додано)
	using VideoOut = std::function<void(const std::vector<uint8_t> &au, bool key, int64_t captureUs)>;
	// samples — тривалість пакета (48 кГц); size 0 — пропуск (втрачений у PS5 пакет: лише зсуваємо час)
	using AudioOut = std::function<void(const uint8_t *data, size_t size, uint32_t samples)>;
	using KeyRequest = std::function<void(const char *why)>;

	Forwarder();
	~Forwarder();
	void start(Codec codec, const StreamHeader &header, VideoOut video, AudioOut audio, KeyRequest key);
	void stop();
	bool running() const { return running_.load(); }

	void setPaceKbps(int kbps);           // межа швидкості відправлення (з перевірки інтернету)
	void setVideoOn(bool on);             // false — кадри не беремо (перепідключення)
	void setAudioOn(bool on) { audio_on_.store(on); }
	void waitKey(const char *why);        // далі лише з ключового кадру (новий з'єднання, обрив)

	// з потоків chiaki: дешево (копія байтів у чергу)
	void pushVideo(const uint8_t *data, size_t size, int64_t us);
	void pushAudio(const uint8_t *data, size_t size, uint32_t samples);

	// показники (з будь-якого потоку)
	std::atomic<int> frames_in{0};
	std::atomic<int> frames_sent{0};
	std::atomic<int> frames_skipped{0};   // пропущено для глядачів (чекали ключовий / канал не встигав)
	std::atomic<int> keyframes{0};
	std::atomic<int> overflows{0};        // скільки разів вихідний канал не встигав
	std::atomic<int64_t> bytes_sent{0};
	std::atomic<int> audio_sent{0};
	std::atomic<int> backlog_ms{0};       // оцінка черги пейсера
	std::atomic<bool> waiting_key{true};

private:
	struct Item
	{
		bool video = true;
		std::vector<uint8_t> data;
		int64_t us = 0;
		uint32_t samples = 0;
	};
	void run();
	void handleVideo(Item &it);

	Codec codec_ = Codec::Unknown;
	StreamHeader header_;                 // лише потік пересилання
	VideoOut video_;
	AudioOut audio_;
	KeyRequest key_;
	std::mutex mutex_;
	std::condition_variable cv_;
	std::deque<Item> queue_;
	int queued_video_ = 0;
	bool quit_ = false;
	bool queue_dropped_ = false;
	std::thread thread_;
	std::atomic<bool> running_{false};
	std::atomic<bool> video_on_{true};
	std::atomic<bool> audio_on_{true};
	std::atomic<int> pace_kbps_{20000};
	std::atomic<bool> want_wait_key_{false};
	// віртуальна черга пейсера (байти), лише потік пересилання
	double vq_bytes_ = 0;
	int64_t vq_us_ = 0;
	std::vector<uint8_t> out_;
};

// ───────────────────────────── звук ─────────────────────────────

// Кодувальник Opus 48 кГц (лише мікрофон гравця; звук гри йде з PS5 як є): кадри по 20 мс.
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
	// заповнює stereo int16 48 кГц
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
		std::function<void(const std::string &mid, const uint8_t *, size_t)> remoteAudio;   // пакет Opus від глядача
		std::function<void(int id, const std::string &text)> message;   // текст із каналу даних
		std::function<void(int id, const uint8_t *, size_t)> binary;   // двійкове повідомлення (ввід помічника)
		std::function<void(int id, bool open)> channelState;
	};
	explicit Peer(Callbacks cb);
	~Peer();
	bool create(const std::vector<std::string> &iceUrls, std::string *err);
	void close();
	// треки гравця (до першого offer). Відео — у кодеку гри (H.264 або H.265) з fmtp із SPS приставки.
	void addVideo(const std::string &mid, Codec codec, const std::string &fmtp, double paceKbps);
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
	// медіа: кадр з 4-байтовими довжинами NAL; звук — готовий пакет Opus (size 0 — лише зсув часу)
	void sendVideo(const std::vector<uint8_t> &au, int64_t captureUs);
	void sendAudio(const std::string &mid, const uint8_t *data, size_t size, int samples);
	bool connected() const { return connected_.load(); }
	int64_t videoBytesSent() const { return video_bytes_.load(); }
	// звіти SFU про наше відео (RTCP RR): втрати (0…255 / 256) і час туди-назад
	int rttMs() const { return rtt_ms_.load(); }
	int lossPercent() const { return (loss_frac_.load() * 100) / 256; }

private:
	Callbacks cb_;
	std::shared_ptr<rtc::PeerConnection> pc_;
	struct Out
	{
		std::shared_ptr<rtc::Track> track;
		std::shared_ptr<rtc::RtpPacketizationConfig> cfg;
		uint32_t ts = 0;
	};
	std::map<std::string, Out> out_;
	mutable std::mutex mutex_;
	std::map<int, std::shared_ptr<rtc::DataChannel>> channels_;
	std::vector<std::shared_ptr<rtc::Track>> remote_;
	std::shared_ptr<rtc::DataChannel> bootstrap_;   // тимчасовий канал лише для m=application у першому offer
	std::atomic<bool> connected_{false};
	std::atomic<int64_t> video_bytes_{0};
	std::atomic<int> rtt_ms_{0};
	std::atomic<int> loss_frac_{0};
	int64_t video_start_us_ = 0;
	friend class RtcpWatch;
};

} // namespace anyplaylive
