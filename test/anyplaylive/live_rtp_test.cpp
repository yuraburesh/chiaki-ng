// AnyPlay 118: перевірка медіа трансляції на цьому комп'ютері — пересилання БЕЗ перекодування.
// «PS5» тут — libx264/libx265 (лише в тесті): дає заголовок окремо (як chiaki: SPS/PPS або VPS/SPS/PPS з нулями
// вирівнювання), далі кадри без параметрів, нескінченний GOP і ключовий кадр лише на запит — як справжня приставка.
// Кадри йдуть у Forwarder (як із колбека chiaki) → Peer (RTP H.264/H.265, NACK, PLI, пейсинг) → справжнє
// з'єднання WebRTC на localhost → приймач libdatachannel (розпакування RTP) → декодер FFmpeg. Перевіряємо, що
// зрізи кадрів у глядача байт у байт ті самі, що прийшли з «PS5». Плюс Opus як є, захист вихідного каналу,
// канали даних з id «від SFU» і голос глядача.
#include "anyplaylivemedia.h"

#include <rtc/rtc.hpp>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/opt.h>
}
#include <opus/opus.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace anyplaylive;
using namespace std::chrono_literals;

static int g_fail = 0;
#define CHECK(cond, ...)                                       \
	do                                                         \
	{                                                          \
		if(cond)                                               \
			printf("  ok   " __VA_ARGS__);                     \
		else                                                   \
		{                                                      \
			printf("  FAIL " __VA_ARGS__);                     \
			g_fail++;                                          \
		}                                                      \
		printf("\n");                                          \
	} while(0)

template<typename F> static bool waitUntil(F f, int ms)
{
	for(int i = 0; i < ms / 10; i++)
	{
		if(f())
			return true;
		std::this_thread::sleep_for(10ms);
	}
	return f();
}

static const size_t kPad = 64;   // CHIAKI_VIDEO_BUFFER_PADDING_SIZE: нулі після заголовка й кадрів

// «PS5»: кодувальник лише в тесті
struct FakePs5
{
	AVCodecContext *ctx = nullptr;
	Codec codec = Codec::Unknown;
	std::vector<uint8_t> header;
	int i = 0;
	int w = 1280, h = 720;
	bool open(Codec c)
	{
		codec = c;
		const AVCodec *enc = avcodec_find_encoder_by_name(c == Codec::H265 ? "libx265" : "libx264");
		if(!enc)
			return false;
		ctx = avcodec_alloc_context3(enc);
		ctx->width = w;
		ctx->height = h;
		ctx->time_base = AVRational{ 1, 60 };
		ctx->framerate = AVRational{ 60, 1 };
		ctx->pix_fmt = AV_PIX_FMT_YUV420P;
		ctx->bit_rate = 6000000;
		ctx->gop_size = 100000;   // як PS5: ключовий кадр лише на початку й на запит
		ctx->max_b_frames = 0;
		ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;   // параметри окремо, у кадрах їх немає
		AVDictionary *o = nullptr;
		av_dict_set(&o, "preset", "ultrafast", 0);
		av_dict_set(&o, "tune", "zerolatency", 0);
		av_dict_set(&o, "forced-idr", "1", 0);
		if(c == Codec::H265)
			av_dict_set(&o, "x265-params", "log-level=error:repeat-headers=0", 0);
		const int r = avcodec_open2(ctx, enc, &o);
		av_dict_free(&o);
		if(r < 0 || !ctx->extradata_size)
			return false;
		header.assign(ctx->extradata, ctx->extradata + ctx->extradata_size);
		header.resize(header.size() + kPad, 0);
		return true;
	}
	std::vector<uint8_t> next(bool key)
	{
		AVFrame *f = av_frame_alloc();
		f->format = AV_PIX_FMT_YUV420P;
		f->width = w;
		f->height = h;
		av_frame_get_buffer(f, 0);
		for(int y = 0; y < h; y++)
			for(int x = 0; x < w; x++)
				f->data[0][y * f->linesize[0] + x] = static_cast<uint8_t>((x / 4 + i * 3 + (y / 64) * 8) & 255);
		for(int p = 1; p <= 2; p++)
			for(int y = 0; y < h / 2; y++)
				memset(f->data[p] + y * f->linesize[p], 128, static_cast<size_t>(w / 2));
		f->pts = i++;
		f->pict_type = key ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
		std::vector<uint8_t> au;
		if(avcodec_send_frame(ctx, f) >= 0)
		{
			AVPacket *pkt = av_packet_alloc();
			while(avcodec_receive_packet(ctx, pkt) == 0)
			{
				au.insert(au.end(), pkt->data, pkt->data + pkt->size);
				av_packet_unref(pkt);
			}
			av_packet_free(&pkt);
		}
		av_frame_free(&f);
		if(!au.empty())
			au.resize(au.size() + kPad, 0);
		return au;
	}
	~FakePs5() { avcodec_free_context(&ctx); }
};

// NAL-одиниці кадру з 4-байтовими довжинами (що віддає Forwarder)
static std::vector<std::vector<uint8_t>> lengthNals(const std::vector<uint8_t> &au)
{
	std::vector<std::vector<uint8_t>> out;
	size_t i = 0;
	while(i + 4 <= au.size())
	{
		const size_t n = (size_t(au[i]) << 24) | (size_t(au[i + 1]) << 16) | (size_t(au[i + 2]) << 8) | au[i + 3];
		i += 4;
		if(i + n > au.size())
			break;
		out.emplace_back(au.begin() + long(i), au.begin() + long(i + n));
		i += n;
	}
	return out;
}

static std::vector<std::vector<uint8_t>> annexNals(const std::vector<uint8_t> &au, Codec c)
{
	std::vector<std::vector<uint8_t>> out;
	for(const NalView &v : splitAnnexB(au.data(), au.size(), c))
		out.emplace_back(v.data, v.data + v.size);
	return out;
}

static void sectionCodec(Codec codec)
{
	const bool hevc = codec == Codec::H265;
	printf("%s. Відео %s: «PS5» → Forwarder → RTP → WebRTC → декодер, без перекодування\n", hevc ? "3" : "2", codecName(codec));
	FakePs5 ps5;
	if(!ps5.open(codec))
	{
		CHECK(false, "кодувальник «PS5» (%s) не відкрився — у FFmpeg цього комп'ютера немає libx264/libx265", codecName(codec));
		return;
	}
	StreamHeader hdr;
	CHECK(parseHeaderSample(ps5.header.data(), ps5.header.size(), &hdr) && hdr.codec == codec,
		"заголовок «PS5» (%zu байт + %zu нулів) розпізнано: %s", ps5.header.size() - kPad, kPad, codecName(hdr.codec));
	const std::string fmtp = sdpFmtp(codec, hdr.annexB);
	CHECK(hevc ? fmtp.find("profile-id=1") != std::string::npos && fmtp.find("level-id=") != std::string::npos
	           : fmtp.find("profile-level-id=") != std::string::npos && fmtp.find("packetization-mode=1") != std::string::npos,
		"fmtp з SPS: %s", fmtp.c_str());

	std::atomic<bool> gathered{ false }, pli{ false };
	Peer::Callbacks cb;
	cb.gathered = [&]() { gathered = true; };
	cb.keyframe = [&]() { pli = true; };
	Peer pub(cb);
	std::string err;
	pub.create({}, &err);
	pub.addVideo("video", codec, fmtp, 30000);
	pub.addAudio("game", 2);
	pub.addAudio("mic", 1);
	pub.makeOffer(true);
	waitUntil([&]() { return gathered.load(); }, 3000);
	const std::string offer = pub.localSdp();
	CHECK(offer.find(hevc ? "H265/90000" : "H264/90000") != std::string::npos && offer.find(fmtp) != std::string::npos
		&& offer.find("opus/48000/2") != std::string::npos,
		"offer: %s з тим самим fmtp + Opus стерео", codecName(codec));

	rtc::Configuration rc;
	rc.disableAutoNegotiation = true;
	auto rx = std::make_shared<rtc::PeerConnection>(rc);
	std::mutex au_mutex;
	std::vector<std::vector<uint8_t>> received;
	std::shared_ptr<rtc::Track> rx_video;
	std::vector<std::shared_ptr<rtc::Track>> rx_tracks;
	std::vector<std::vector<uint8_t>> audio_rx;
	rx->onTrack([&](std::shared_ptr<rtc::Track> t) {
		rx_tracks.push_back(t);
		if(t->mid() == "video")
		{
			rx_video = t;
			std::shared_ptr<rtc::MediaHandler> depack;
			if(hevc)
				depack = std::make_shared<rtc::H265RtpDepacketizer>(rtc::NalUnit::Separator::LongStartSequence);
			else
				depack = std::make_shared<rtc::H264RtpDepacketizer>(rtc::NalUnit::Separator::LongStartSequence);
			depack->addToChain(std::make_shared<rtc::RtcpReceivingSession>());
			t->setMediaHandler(depack);
			t->onFrame([&](rtc::binary data, rtc::FrameInfo) {
				std::lock_guard<std::mutex> l(au_mutex);
				received.emplace_back(reinterpret_cast<const uint8_t *>(data.data()), reinterpret_cast<const uint8_t *>(data.data()) + data.size());
			});
		}
		else if(t->mid() == "game")
		{
			auto depack = std::make_shared<rtc::OpusRtpDepacketizer>();
			depack->addToChain(std::make_shared<rtc::RtcpReceivingSession>());
			t->setMediaHandler(depack);
			t->onFrame([&](rtc::binary data, rtc::FrameInfo) {
				std::lock_guard<std::mutex> l(au_mutex);
				audio_rx.emplace_back(reinterpret_cast<const uint8_t *>(data.data()), reinterpret_cast<const uint8_t *>(data.data()) + data.size());
			});
		}
	});
	std::atomic<bool> rx_gathered{ false };
	rx->onGatheringStateChange([&](rtc::PeerConnection::GatheringState s) {
		if(s == rtc::PeerConnection::GatheringState::Complete)
			rx_gathered = true;
	});
	try
	{
		rx->setRemoteDescription(rtc::Description(offer, rtc::Description::Type::Offer));
		rx->setLocalDescription(rtc::Description::Type::Answer);
	}
	catch(const std::exception &e)
	{
		CHECK(false, "приймач не прийняв offer: %s", e.what());
		return;
	}
	waitUntil([&]() { return rx_gathered.load(); }, 3000);
	CHECK(pub.applyAnswer(std::string(*rx->localDescription()), &err), "answer застосовано %s", err.c_str());
	CHECK(waitUntil([&]() { return pub.connected(); }, 10000), "з'єднання встановлено (ICE + DTLS-SRTP)");
	waitUntil([&]() { return rx_video && rx_video->isOpen(); }, 3000);

	// пересилання: як у програмі (кадри з потоку «chiaki», ключові на запит, звук гри як є)
	Forwarder fwd;
	std::mutex sent_mutex;
	std::vector<std::vector<uint8_t>> sent;
	std::atomic<int> key_req{ 0 };
	std::atomic<bool> want_key{ false };
	fwd.start(codec, hdr,
		[&](const std::vector<uint8_t> &au, bool, int64_t us) {
			{
				std::lock_guard<std::mutex> l(sent_mutex);
				sent.push_back(au);
			}
			pub.sendVideo(au, us);
		},
		[&](const uint8_t *d, size_t n, uint32_t samples) { pub.sendAudio("game", d, n, static_cast<int>(samples)); },
		[&](const char *) { key_req++; want_key = true; });
	fwd.setPaceKbps(30000);

	// «гра» вже йде: перші 12 кадрів (з ключовим на самому початку) — до ввімкнення трансляції
	std::vector<std::vector<uint8_t>> originals;   // що «PS5» дала після ввімкнення, по порядку
	for(int k = 0; k < 12; k++)
		ps5.next(k == 0);
	int64_t push_us = 0, pushes = 0;
	bool key_next = false;
	const int64_t t0 = nowUs();
	for(int k = 0; k < 150; k++)
	{
		const int64_t due = t0 + static_cast<int64_t>(k) * 16667;
		while(nowUs() < due)
			std::this_thread::sleep_for(1ms);
		if(k == 10)
			key_next = true;                       // як goLive: просимо ключовий у приставки
		if(k == 80 && rx_video)
			rx_video->requestKeyframe();            // новий глядач: PLI → ключовий кадр
		if(pli.exchange(false) || want_key.exchange(false))
			key_next = true;
		std::vector<uint8_t> au = ps5.next(key_next);
		key_next = false;
		if(au.empty())
			continue;
		originals.push_back(au);
		const int64_t a = nowUs();
		fwd.pushVideo(au.data(), au.size(), a);   // те, що робить колбек chiaki: копія в чергу
		push_us += nowUs() - a;
		pushes++;
	}
	std::this_thread::sleep_for(800ms);
	CHECK(fwd.frames_skipped.load() >= 9 && fwd.frames_skipped.load() <= 12,
		"до першого ключового кадру глядачам не йшло нічого: пропущено %d P-кадрів", fwd.frames_skipped.load());
	CHECK(pushes > 0 && push_us / pushes < 300, "колбек «chiaki» віддає кадр за %.1f мкс у середньому (лише копія байтів)",
		pushes ? double(push_us) / pushes : 0.0);

	std::vector<std::vector<uint8_t>> aus, sent_copy;
	{
		std::lock_guard<std::mutex> l(au_mutex);
		aus = received;
	}
	{
		std::lock_guard<std::mutex> l(sent_mutex);
		sent_copy = sent;
	}
	CHECK(sent_copy.size() >= 130 && aus.size() >= sent_copy.size() - 2, "переслано кадрів %zu, отримано через RTP %zu, ключових %d",
		sent_copy.size(), aus.size(), fwd.keyframes.load());

	// байт у байт: зрізи кадрів у глядача — ті самі, що дала «PS5» (жодного перекодування)
	size_t same = 0, compared = 0, with_params = 0, keys = 0;
	const size_t base = originals.size() >= sent_copy.size() ? originals.size() - sent_copy.size() : 0;
	for(size_t k = 0; k < aus.size() && k < sent_copy.size() && base + k < originals.size(); k++)
	{
		std::vector<std::vector<uint8_t>> orig_slices, rx_slices;
		for(auto &n : annexNals(originals[base + k], codec))
			if(isSliceNal(codec, hevc ? ((n[0] >> 1) & 0x3f) : (n[0] & 0x1f)))
				orig_slices.push_back(n);
		bool params = false, key = false;
		for(auto &n : annexNals(aus[k], codec))
		{
			const int t = hevc ? ((n[0] >> 1) & 0x3f) : (n[0] & 0x1f);
			if(isParameterSet(codec, t))
				params = true;
			if(isKeyNal(codec, t))
				key = true;
			if(isSliceNal(codec, t))
				rx_slices.push_back(n);
		}
		if(key)
		{
			keys++;
			if(params)
				with_params++;
		}
		compared++;
		if(orig_slices == rx_slices)
			same++;
	}
	CHECK(compared > 100 && same == compared, "зрізи кадрів у глядача збігаються з «PS5» байт у байт: %zu з %zu", same, compared);
	CHECK(keys >= 2 && with_params == keys, "ключових кадрів у глядача %zu (старт + на PLI), перед кожним параметри %s", keys,
		hevc ? "VPS/SPS/PPS" : "SPS/PPS");
	CHECK(key_req.load() == 0, "Forwarder сам не смикав приставку без потреби (запитів %d)", key_req.load());

	const AVCodec *dec_codec = avcodec_find_decoder(hevc ? AV_CODEC_ID_HEVC : AV_CODEC_ID_H264);
	AVCodecContext *dec = avcodec_alloc_context3(dec_codec);
	avcodec_open2(dec, dec_codec, nullptr);
	AVPacket *pkt = av_packet_alloc();
	AVFrame *out = av_frame_alloc();
	int decoded = 0, bad_size = 0, errors = 0;
	for(const auto &au : aus)
	{
		pkt->data = const_cast<uint8_t *>(au.data());
		pkt->size = static_cast<int>(au.size());
		if(avcodec_send_packet(dec, pkt) < 0)
		{
			errors++;
			continue;
		}
		while(avcodec_receive_frame(dec, out) == 0)
		{
			decoded++;
			if(out->width != ps5.w || out->height != ps5.h)
				bad_size++;
			if(out->decode_error_flags)
				errors++;
		}
	}
	avcodec_send_packet(dec, nullptr);
	while(avcodec_receive_frame(dec, out) == 0)
		decoded++;
	CHECK(decoded >= static_cast<int>(aus.size()) - 1 && bad_size == 0 && errors == 0,
		"глядач розкодував %d кадрів %dx%d (помилок %d) — та сама роздільність і кадри, що в гравця", decoded, ps5.w, ps5.h, errors);
	av_frame_free(&out);
	av_packet_free(&pkt);
	avcodec_free_context(&dec);

	if(!hevc)
	{
		printf("2б. Звук гри: пакети Opus «PS5» (10 мс) → глядачам як є\n");
		int e = 0;
		OpusEncoder *oe = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &e);
		std::vector<std::vector<uint8_t>> sent_audio;
		std::vector<int16_t> pcm(480 * 2);
		uint8_t buf[1500];
		for(int chunk = 0; chunk < 100; chunk++)
		{
			for(int i = 0; i < 480; i++)
			{
				const int16_t v = static_cast<int16_t>(8000 * std::sin(2 * M_PI * 440 * (chunk * 480 + i) / 48000.0));
				pcm[i * 2] = pcm[i * 2 + 1] = v;
			}
			const int n = opus_encode(oe, pcm.data(), 480, buf, sizeof(buf));
			if(chunk == 50)
				fwd.pushAudio(nullptr, 0, 480);   // PS5 загубила пакет: лише зсув часу
			else if(n > 0)
			{
				sent_audio.emplace_back(buf, buf + n);
				fwd.pushAudio(buf, static_cast<size_t>(n), 480);
			}
			std::this_thread::sleep_for(10ms);
		}
		opus_encoder_destroy(oe);
		std::this_thread::sleep_for(300ms);
		std::vector<std::vector<uint8_t>> got;
		{
			std::lock_guard<std::mutex> l(au_mutex);
			got = audio_rx;
		}
		size_t eq = 0;
		for(size_t k = 0; k < got.size() && k < sent_audio.size(); k++)
			if(got[k] == sent_audio[k])
				eq++;
		CHECK(got.size() >= 95 && eq == got.size(), "пакетів Opus отримано %zu з %zu, байт у байт однакових %zu (без перекодування)",
			got.size(), sent_audio.size(), eq);
		OpusDecoder *od = opus_decoder_create(48000, 2, &e);
		double energy = 0;
		size_t samples = 0;
		std::vector<int16_t> o(5760 * 2);
		for(auto &p : got)
		{
			const int n = opus_decode(od, p.data(), static_cast<opus_int32>(p.size()), o.data(), 5760, 0);
			for(int i = 0; i < n * 2; i++)
				energy += double(o[i]) * o[i];
			samples += n > 0 ? size_t(n) * 2 : 0;
		}
		opus_decoder_destroy(od);
		const double rms = samples ? std::sqrt(energy / samples) : 0;
		CHECK(rms > 3000, "звук гри дійшов (RMS %.0f)", rms);
		CHECK(fwd.audio_sent.load() == static_cast<int>(sent_audio.size()), "Forwarder переслав %d пакетів звуку", fwd.audio_sent.load());
	}
	fwd.stop();
	pub.close();
	rx->close();
}

int main()
{
	setvbuf(stdout, nullptr, _IONBF, 0);
	setLogger([](const std::string &s) { printf("    [anyplay-live] %s\n", s.c_str()); });

	printf("1. Розбір потоку PS5: NAL-одиниці, кодек, заголовок, нулі вирівнювання\n");
	{
		// H.264: SPS (High 4.2), PPS — як заголовок chiaki: стартові коди + 64 нулі
		const uint8_t h264hdr[] = { 0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2a, 0xac, 0x2b, 0x40, 0, 0, 0, 1, 0x68, 0xee, 0x3c, 0x80,
		                            0, 0, 0, 0, 0, 0, 0, 0 };
		StreamHeader h;
		CHECK(detectCodec(h264hdr, sizeof(h264hdr)) == Codec::H264 && parseHeaderSample(h264hdr, sizeof(h264hdr), &h)
			&& splitAnnexB(h.annexB.data(), h.annexB.size(), Codec::H264).size() == 2,
			"H.264: заголовок SPS+PPS розпізнано, нулі відкинуто");
		CHECK(sdpFmtp(Codec::H264, h.annexB).find("profile-level-id=64002a") != std::string::npos, "H.264: profile-level-id=64002a (High 4.2)");
		const uint8_t frame[] = { 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21, 0, 0, 1, 0x65, 0x11, 0x22, 0, 0, 0, 0, 0, 0 };
		const auto nals = splitAnnexB(frame, sizeof(frame), Codec::H264);
		CHECK(nals.size() == 2 && nals[0].size == 4 && nals[1].size == 3 && isKeyNal(Codec::H264, nals[0].type)
			&& !parseHeaderSample(frame, sizeof(frame), nullptr),
			"H.264: кадр IDR з двох зрізів, кінцеві нулі відкинуто, не заголовок");
		// H.265: VPS/SPS/PPS — перші байти NAL 0x40 0x01, 0x42 0x01, 0x44 0x01; SPS: Main, рівень 5.1 (153)
		const uint8_t hevchdr[] = { 0, 0, 0, 1, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff,
		                            0, 0, 0, 1, 0x42, 0x01, 0x01, 0x01, 0x60, 0, 0, 0x03, 0, 0x90, 0, 0, 0x03, 0, 0, 0x03, 0, 0x99, 0xa0, 0x01,
		                            0, 0, 0, 1, 0x44, 0x01, 0xc1, 0x72, 0xb4, 0x62, 0x40, 0, 0, 0, 0 };
		StreamHeader hh;
		CHECK(detectCodec(hevchdr, sizeof(hevchdr)) == Codec::H265 && parseHeaderSample(hevchdr, sizeof(hevchdr), &hh),
			"H.265: заголовок VPS+SPS+PPS розпізнано");
		const std::string f = sdpFmtp(Codec::H265, hh.annexB);
		CHECK(f.find("profile-id=1") != std::string::npos && f.find("level-id=153") != std::string::npos && f.find("tier-flag=0") != std::string::npos,
			"H.265: %s (захисні байти 0x03 враховано)", f.c_str());
		const uint8_t p264[] = { 0x41, 0x9a, 0x02 }, vps[] = { 0x40, 0x01, 0x0c }, sps264[] = { 0x67, 0x64, 0x00 };
		CHECK(headerCodec(p264, 3) == Codec::Unknown && headerCodec(vps, 3) == Codec::H265 && headerCodec(sps264, 3) == Codec::H264,
			"P-кадр H.264 (0x41) не плутається з VPS H.265 (0x40 0x01)");
		CHECK(isKeyNal(Codec::H265, 19) && isKeyNal(Codec::H265, 20) && !isKeyNal(Codec::H265, 1) && isSliceNal(Codec::H265, 1)
			&& !isSliceNal(Codec::H265, 39), "H.265: IDR/CRA ключові, SEI — не зріз");
	}

	sectionCodec(Codec::H264);
	sectionCodec(Codec::H265);

	printf("4. Слабкий вихідний інтернет: глядачам пропускаємо кадри, гравцеві нічого не міняється, ефір не зупиняється\n");
	{
		Forwarder fwd;
		StreamHeader hdr;
		const uint8_t h264hdr[] = { 0, 0, 0, 1, 0x67, 0x64, 0x00, 0x2a, 0xac, 0, 0, 0, 1, 0x68, 0xee, 0x3c, 0x80 };
		parseHeaderSample(h264hdr, sizeof(h264hdr), &hdr);
		std::atomic<int64_t> bytes{ 0 };
		std::atomic<int> uplink_req{ 0 };
		fwd.start(Codec::H264, hdr, [&](const std::vector<uint8_t> &au, bool, int64_t) { bytes += static_cast<int64_t>(au.size()); },
			[](const uint8_t *, size_t, uint32_t) {}, [&](const char *why) { if(std::string(why) == "uplink") uplink_req++; });
		fwd.setPaceKbps(4000);   // перевірка показала 4 Мбіт/с, а гра йде ~19 Мбіт/с
		std::vector<uint8_t> key(40000, 0x55), p(40000, 0x33);
		key[0] = key[1] = key[2] = 0; key[3] = 1; key[4] = 0x65;
		p[0] = p[1] = p[2] = 0; p[3] = 1; p[4] = 0x41;
		const int64_t t0 = nowUs();
		for(int k = 0; k < 120; k++)
		{
			while(nowUs() < t0 + k * 16667)
				std::this_thread::sleep_for(1ms);
			const auto &f = (k % 30 == 0) ? key : p;
			fwd.pushVideo(f.data(), f.size(), nowUs());
		}
		std::this_thread::sleep_for(200ms);
		const double secs = (nowUs() - t0) / 1e6;
		const double kbps = bytes.load() * 8 / 1000.0 / secs;
		CHECK(fwd.overflows.load() > 0 && fwd.frames_skipped.load() > 0 && uplink_req.load() > 0,
			"канал не встигав %d раз, глядачам пропущено %d кадрів, ключовий після пропуску просили %d раз",
			fwd.overflows.load(), fwd.frames_skipped.load(), uplink_req.load());
		CHECK(kbps < 4000 * 1.35, "у мережу пішло %.0f кбіт/с при межі 4000 (гра давала ~19000): канал гравця не забито", kbps);
		CHECK(fwd.running(), "пересилання й далі працює (ефір не на паузі)");
		fwd.stop();
	}

	printf("5. Канали даних з id «від SFU» і голос глядача\n");
	{
		std::atomic<bool> gathered{ false };
		std::mutex msg_mutex;
		std::vector<std::pair<int, std::string>> pub_msgs;
		std::atomic<int> pub_open{ 0 }, bin_size{ 0 }, bin_magic{ 0 }, remote_audio{ 0 };
		Peer::Callbacks cb;
		cb.gathered = [&]() { gathered = true; };
		cb.message = [&](int id, const std::string &t) {
			std::lock_guard<std::mutex> l(msg_mutex);
			pub_msgs.emplace_back(id, t);
		};
		cb.binary = [&](int id, const uint8_t *d, size_t n) {
			if(id == 4)
			{
				bin_size = static_cast<int>(n);
				bin_magic = n ? d[0] : 0;
			}
		};
		cb.remoteAudio = [&](const std::string &, const uint8_t *, size_t) { remote_audio++; };
		cb.channelState = [&](int, bool open) {
			if(open)
				pub_open++;
		};
		Peer pub(cb);
		std::string err;
		pub.create({}, &err);
		pub.addVideo("video", Codec::H264, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=64002a", 20000);
		pub.addAudio("game", 2);
		pub.addAudio("mic", 1);
		pub.makeOffer(true);
		waitUntil([&]() { return gathered.load(); }, 3000);
		rtc::Configuration rc;
		rc.disableAutoNegotiation = true;
		auto rx = std::make_shared<rtc::PeerConnection>(rc);
		std::atomic<bool> rx_gathered{ false };
		rx->onGatheringStateChange([&](rtc::PeerConnection::GatheringState s) {
			if(s == rtc::PeerConnection::GatheringState::Complete)
				rx_gathered = true;
		});
		std::vector<std::shared_ptr<rtc::Track>> keep;
		rx->onTrack([&](std::shared_ptr<rtc::Track> t) { keep.push_back(t); });
		rx->setRemoteDescription(rtc::Description(pub.localSdp(), rtc::Description::Type::Offer));
		rx->setLocalDescription(rtc::Description::Type::Answer);
		waitUntil([&]() { return rx_gathered.load(); }, 3000);
		pub.applyAnswer(std::string(*rx->localDescription()), &err);
		CHECK(waitUntil([&]() { return pub.connected(); }, 10000), "з'єднання встановлено");
		rtc::DataChannelInit ev_init;
		ev_init.negotiated = true;
		ev_init.id = 2;
		auto rx_ev = rx->createDataChannel("events", ev_init);
		rtc::DataChannelInit input_init;
		input_init.negotiated = true;
		input_init.id = 4;
		input_init.reliability.unordered = true;
		input_init.reliability.maxRetransmits = 0;
		auto rx_input = rx->createDataChannel("input", input_init);
		std::vector<std::string> rx_msgs;
		rx_ev->onMessage([](rtc::binary) {}, [&](rtc::string s) {
			std::lock_guard<std::mutex> l(msg_mutex);
			rx_msgs.push_back(s);
		});
		CHECK(pub.openChannel(2, "events", true, -1) && pub.openChannel(4, "input", false, 0), "канали events/2 і input/4 (negotiated)");
		CHECK(waitUntil([&]() { return pub_open.load() >= 2 && rx_ev->isOpen() && rx_input->isOpen(); }, 5000), "канали відкрито з обох боків");
		pub.send(2, "{\"t\":\"bye\"}");
		{
			rtc::binary pkt(28, std::byte{ 0 });
			pkt[0] = std::byte{ 0xA7 };
			pkt[1] = std::byte{ 1 };
			pkt[8] = std::byte{ 1 };
			rx_input->send(pkt);
		}
		waitUntil([&]() {
			std::lock_guard<std::mutex> l(msg_mutex);
			return !rx_msgs.empty();
		}, 3000);
		{
			std::lock_guard<std::mutex> l(msg_mutex);
			CHECK(!rx_msgs.empty() && rx_msgs[0] == "{\"t\":\"bye\"}", "events: гравець → глядач");
		}
		CHECK(waitUntil([&]() { return bin_size.load() == 28; }, 2000) && bin_magic == 0xA7, "input: двійковий пакет 28 байтів (0xA7) дійшов до гравця");

		rtc::Description::Audio va("v1", rtc::Description::Direction::SendOnly);
		va.addOpusCodec(111);
		va.addSSRC(4242, std::string("viewer-voice"));
		auto vt = rx->addTrack(va);
		auto vcfg = std::make_shared<rtc::RtpPacketizationConfig>(4242, "viewer-voice", 111, rtc::OpusRtpPacketizer::DefaultClockRate);
		vt->setMediaHandler(std::make_shared<rtc::OpusRtpPacketizer>(vcfg));
		rx->setLocalDescription(rtc::Description::Type::Offer);
		const bool applied = pub.applyOffer(std::string(*rx->localDescription()), &err);
		CHECK(applied, "SFU прислав новий offer з голосом глядача, answer готовий %s", err.c_str());
		rx->setRemoteDescription(rtc::Description(pub.localSdp(), rtc::Description::Type::Answer));
		CHECK(waitUntil([&]() { return vt->isOpen(); }, 3000), "трек голосу відкрито");
		OpusPacker mic;
		mic.open(1, 32, true);
		std::vector<int16_t> m(480);
		uint32_t ts = 0;
		for(int chunk = 0; chunk < 50; chunk++)
		{
			for(int i = 0; i < 480; i++)
				m[i] = static_cast<int16_t>(6000 * std::sin(2 * M_PI * 300 * (chunk * 480 + i) / 48000.0));
			mic.push(m.data(), 480, [&](const uint8_t *d, size_t n, int samples) {
				vt->sendFrame(reinterpret_cast<const rtc::byte *>(d), n, rtc::FrameInfo(ts));
				ts += static_cast<uint32_t>(samples);
			});
			std::this_thread::sleep_for(10ms);
		}
		CHECK(waitUntil([&]() { return remote_audio.load() >= 20; }, 3000), "гравець отримав пакетів голосу глядача: %d", remote_audio.load());
		pub.close();
		rx->close();
	}

	printf("\n%s: %d помилок\n", g_fail ? "ПОМИЛКИ" : "УСЕ ДОБРЕ", g_fail);
	return g_fail ? 1 : 0;
}
