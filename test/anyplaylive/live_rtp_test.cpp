// AnyPlay 116: перевірка медіа трансляції на цьому комп'ютері.
// Кадр гри (NV12 і yuv420p, 1920x1080, 60 к/с) → VideoPipeline (масштаб до 1280x720, H.264, 30 к/с) →
// Peer (RTP H.264 + пакетування, NACK, PLI, пейсинг) → справжнє з'єднання WebRTC (ICE+DTLS-SRTP на localhost) →
// приймач libdatachannel (розпакування RTP) → декодер FFmpeg. Плюс канали даних з id «від SFU» і Opus.
#include "anyplaylivemedia.h"

#include <rtc/rtc.hpp>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
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

// кадр «гри»: смуги, що рухаються; Y = (x/4 + i*4) & 255
static AVFrame *makeFrame(int i, AVPixelFormat fmt)
{
	AVFrame *f = av_frame_alloc();
	f->format = fmt;
	f->width = 1920;
	f->height = 1080;
	av_frame_get_buffer(f, 0);
	for(int y = 0; y < f->height; y++)
		for(int x = 0; x < f->width; x++)
			f->data[0][y * f->linesize[0] + x] = static_cast<uint8_t>((x / 4 + i * 4) & 255);
	if(fmt == AV_PIX_FMT_NV12)
		for(int y = 0; y < f->height / 2; y++)
			memset(f->data[1] + y * f->linesize[1], 128, static_cast<size_t>(f->width));
	else
		for(int p = 1; p <= 2; p++)
			for(int y = 0; y < f->height / 2; y++)
				memset(f->data[p] + y * f->linesize[p], 128, static_cast<size_t>(f->width / 2));
	return f;
}

static void nalTypes(const std::vector<uint8_t> &au, bool *sps, bool *pps, bool *idr)
{
	for(size_t i = 0; i + 4 < au.size(); i++)
		if(au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1)
		{
			const int t = au[i + 3] & 0x1f;
			*sps |= t == 7;
			*pps |= t == 8;
			*idr |= t == 5;
		}
}

int main()
{
	setvbuf(stdout, nullptr, _IONBF, 0);
	setLogger([](const std::string &s) { printf("    [anyplay-live] %s\n", s.c_str()); });
	VideoConfig cfg;   // 1280x720@30, 2500 кбіт/с

	printf("1. Кодувальник: тестовий кадр → H.264\n");
	{
		VideoEncoder enc;
		std::string err;
		const bool opened = enc.open(cfg, true, &err);
		CHECK(opened, "кодувальник відкрито: %s %s", enc.name().c_str(), err.c_str());
		if(!opened)
			return 1;
		AVFrame *f = makeFrame(0, AV_PIX_FMT_NV12);
		std::vector<uint8_t> au;
		bool key = false;
		const bool ok = enc.encode(f, true, &au, &key, &err);
		bool sps = false, pps = false, idr = false;
		nalTypes(au, &sps, &pps, &idr);
		CHECK(ok && key && sps && pps && idr, "перший кадр ключовий з SPS/PPS/IDR, %zu байт, масштаб %.1f мс, кодування %.1f мс",
			au.size(), enc.lastScaleMs(), enc.lastEncodeMs());
		AVFrame *g = makeFrame(1, AV_PIX_FMT_YUV420P);
		const bool ok2 = enc.encode(g, false, &au, &key, &err);
		CHECK(ok2 && !au.empty() && !key, "другий кадр (yuv420p) — звичайний, %zu байт", au.size());
		av_frame_free(&f);
		av_frame_free(&g);
	}

	printf("2. WebRTC на цьому комп'ютері: offer гравця → answer «SFU»\n");
	std::atomic<bool> gathered{ false }, pli{ false };
	std::mutex msg_mutex;
	std::vector<std::pair<int, std::string>> pub_msgs;
	std::atomic<int> pub_open{ 0 };
	Peer::Callbacks cb;
	cb.gathered = [&]() { gathered = true; };
	cb.keyframe = [&]() { pli = true; };
	cb.message = [&](int id, const std::string &t) {
		std::lock_guard<std::mutex> l(msg_mutex);
		pub_msgs.emplace_back(id, t);
	};
	std::atomic<int> bin_size{ 0 };
	std::atomic<int> bin_magic{ 0 };
	cb.binary = [&](int id, const uint8_t *d, size_t n) {
		if(id == 4)
		{
			bin_size = static_cast<int>(n);
			bin_magic = n ? d[0] : 0;
		}
	};
	std::atomic<int> remote_audio{ 0 };
	std::string remote_mid;
	cb.remoteAudio = [&](const std::string &mid, const uint8_t *, size_t) {
		if(remote_audio++ == 0)
			remote_mid = mid;
	};
	cb.channelState = [&](int, bool open) {
		if(open)
			pub_open++;
	};
	Peer pub(cb);
	std::string err;
	CHECK(pub.create({}, &err), "Peer створено %s", err.c_str());
	pub.addVideo("video", 6250);
	pub.addAudio("game", 2);
	pub.addAudio("mic", 1);
	pub.makeOffer(true);
	waitUntil([&]() { return gathered.load(); }, 3000);
	const std::string offer = pub.localSdp();
	CHECK(offer.find("H264/90000") != std::string::npos && offer.find("opus/48000/2") != std::string::npos
		&& offer.find("a=mid:video") != std::string::npos && offer.find("a=sendonly") != std::string::npos
		&& offer.find("webrtc-datachannel") != std::string::npos,
		"offer: H.264 + Opus (mid video/game/mic, лише відправлення) + m=application (%zu байт)", offer.size());

	rtc::Configuration rc;
	rc.disableAutoNegotiation = true;
	auto rx = std::make_shared<rtc::PeerConnection>(rc);
	std::mutex au_mutex;
	std::vector<std::vector<uint8_t>> received;
	std::shared_ptr<rtc::Track> rx_video;
	std::vector<std::shared_ptr<rtc::Track>> rx_tracks;
	VoiceMixer mixer;
	std::atomic<int> audio_packets{ 0 };
	rx->onTrack([&](std::shared_ptr<rtc::Track> t) {
		rx_tracks.push_back(t);
		if(t->mid() == "video")
		{
			rx_video = t;
			auto depack = std::make_shared<rtc::H264RtpDepacketizer>(rtc::NalUnit::Separator::LongStartSequence);
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
				audio_packets++;
				mixer.pushOpus("game", reinterpret_cast<const uint8_t *>(data.data()), data.size());
			});
		}
	});
	std::atomic<bool> rx_gathered{ false };
	rx->onGatheringStateChange([&](rtc::PeerConnection::GatheringState s) {
		if(s == rtc::PeerConnection::GatheringState::Complete)
			rx_gathered = true;
	});
	rx->setRemoteDescription(rtc::Description(offer, rtc::Description::Type::Offer));
	rx->setLocalDescription(rtc::Description::Type::Answer);
	waitUntil([&]() { return rx_gathered.load(); }, 3000);
	CHECK(pub.applyAnswer(std::string(*rx->localDescription()), &err), "answer застосовано %s", err.c_str());
	CHECK(waitUntil([&]() { return pub.connected(); }, 10000), "з'єднання встановлено (ICE + DTLS-SRTP)");

	printf("3. Канали даних з id «від SFU» (datachannels/new), без нових переговорів\n");
	rtc::DataChannelInit room_init;
	room_init.negotiated = true;
	room_init.id = 2;
	auto rx_room = rx->createDataChannel("room", room_init);
	rtc::DataChannelInit input_init;
	input_init.negotiated = true;
	input_init.id = 4;
	input_init.reliability.unordered = true;
	input_init.reliability.maxRetransmits = 0;
	auto rx_input = rx->createDataChannel("input", input_init);
	std::vector<std::string> rx_msgs;
	rx_room->onMessage([](rtc::binary) {}, [&](rtc::string s) {
		std::lock_guard<std::mutex> l(msg_mutex);
		rx_msgs.push_back(s);
	});
	CHECK(pub.openChannel(2, "room", true, -1) && pub.openChannel(4, "input", false, 0), "канали events/2 і input/4 (negotiated)");
	CHECK(waitUntil([&]() { return pub_open.load() >= 2 && rx_room->isOpen() && rx_input->isOpen(); }, 5000), "канали відкрито з обох боків");
	pub.send(2, "{\"t\":\"state\",\"live\":true}");
	rx_input->send("{\"t\":\"pad\",\"gen\":1,\"seq\":1,\"b\":1}");
	{
		// пакет вводу помічника (контракт.md, п. 4.1): 28 байтів, 0xA7, версія 1
		rtc::binary pkt(28, std::byte{ 0 });
		pkt[0] = std::byte{ 0xA7 };
		pkt[1] = std::byte{ 1 };
		pkt[8] = std::byte{ 1 };   // хрестик
		rx_input->send(pkt);
	}
	waitUntil([&]() {
		std::lock_guard<std::mutex> l(msg_mutex);
		return !rx_msgs.empty() && !pub_msgs.empty();
	}, 3000);
	{
		std::lock_guard<std::mutex> l(msg_mutex);
		CHECK(!rx_msgs.empty() && rx_msgs[0] == "{\"t\":\"state\",\"live\":true}", "events: гравець → глядач");
		CHECK(!pub_msgs.empty() && pub_msgs[0].first == 4 && pub_msgs[0].second.find("\"pad\"") != std::string::npos, "input: текст помічник → гравець (id 4)");
	}

	CHECK(waitUntil([&]() { return bin_size.load() == 28; }, 2000) && bin_magic == 0xA7, "input: двійковий пакет 28 байтів (0xA7) дійшов до гравця");

	printf("4. Відео: 3 с «гри» 60 к/с → трансляція 30 к/с через RTP, PLI посередині\n");
	VideoPipeline pipe;
	std::atomic<int> status{ 0 };
	std::string enc_name;
	std::atomic<int> keys_sent{ 0 };
	pipe.start(cfg, true,
		[&](const std::vector<uint8_t> &au, bool key, int64_t us) {
			if(key)
				keys_sent++;
			pub.sendVideo(au, us);
		},
		[&](bool ok, const std::string &name, const std::string &) {
			enc_name = name;
			status = ok ? 1 : -1;
		});
	waitUntil([&]() { return status.load() != 0; }, 5000);
	CHECK(status == 1, "потік кодування запущено (%s)", enc_name.c_str());
	int offered = 0, skipped = 0;
	const int64_t t0 = nowUs();
	for(int i = 0; i < 180; i++)
	{
		const int64_t due = t0 + static_cast<int64_t>(i) * 16667;
		while(nowUs() < due)
			std::this_thread::sleep_for(1ms);
		if(i == 90 && rx_video)
			rx_video->requestKeyframe();   // новий глядач: PLI → ключовий кадр
		if(pli.exchange(false))
			pipe.requestKeyframe();
		if(pipe.wantsFrame(nowUs()))
		{
			AVFrame *f = makeFrame(i, i < 90 ? AV_PIX_FMT_NV12 : AV_PIX_FMT_YUV420P);
			pipe.offer(f);
			av_frame_free(&f);
			offered++;
		}
		else
			skipped++;
	}
	std::this_thread::sleep_for(800ms);
	pipe.stop();
	CHECK(offered >= 85 && offered <= 95, "із 180 кадрів гри взято %d (пропущено %d) — 30 к/с", offered, skipped);
	CHECK(pipe.frames_encoded.load() >= offered - 3, "закодовано %d, викинуто в черзі %d, середній час %.1f мс", pipe.frames_encoded.load(),
		pipe.frames_dropped.load(), pipe.encode_us_avg.load() / 1000.0);
	CHECK(keys_sent >= 2, "ключових кадрів %d (старт + на PLI)", keys_sent.load());

	std::vector<std::vector<uint8_t>> aus;
	{
		std::lock_guard<std::mutex> l(au_mutex);
		aus = received;
	}
	CHECK(aus.size() >= static_cast<size_t>(pipe.frames_encoded.load()) - 2, "отримано кадрів через RTP: %zu", aus.size());
	const AVCodec *dec_codec = avcodec_find_decoder(AV_CODEC_ID_H264);
	AVCodecContext *dec = avcodec_alloc_context3(dec_codec);
	avcodec_open2(dec, dec_codec, nullptr);
	AVPacket *pkt = av_packet_alloc();
	AVFrame *out = av_frame_alloc();
	int decoded = 0, idr = 0, bad_size = 0;
	double luma_err = 0;
	for(const auto &au : aus)
	{
		bool s = false, p = false, k = false;
		nalTypes(au, &s, &p, &k);
		if(k)
			idr++;
		pkt->data = const_cast<uint8_t *>(au.data());
		pkt->size = static_cast<int>(au.size());
		if(avcodec_send_packet(dec, pkt) < 0)
			continue;
		while(avcodec_receive_frame(dec, out) == 0)
		{
			decoded++;
			if(out->width != 1280 || out->height != 720)
				bad_size++;
			// середня яскравість рядка: смуги рівномірні, тож очікуємо ~127
			double sum = 0;
			for(int x = 0; x < out->width; x++)
				sum += out->data[0][360 * out->linesize[0] + x];
			luma_err = std::max(luma_err, std::fabs(sum / out->width - 127.5));
		}
	}
	CHECK(decoded >= static_cast<int>(aus.size()) - 2 && bad_size == 0, "декодовано %d кадрів 1280x720 (зламаних розмірів %d)", decoded, bad_size);
	CHECK(idr >= 2, "IDR у потоці: %d", idr);
	CHECK(luma_err < 12.0, "картинка збереглась (відхилення середньої яскравості %.1f)", luma_err);
	av_frame_free(&out);
	av_packet_free(&pkt);
	avcodec_free_context(&dec);

	printf("5. Звук гри: 1 с синуса 440 Гц → Opus → RTP → декодер\n");
	OpusPacker game;
	CHECK(game.open(2, 96, false), "кодувальник Opus стерео");
	std::vector<int16_t> pcm(480 * 2);
	for(int chunk = 0; chunk < 100; chunk++)
	{
		for(int i = 0; i < 480; i++)
		{
			const double t = (chunk * 480 + i) / 48000.0;
			const int16_t v = static_cast<int16_t>(8000 * std::sin(2 * M_PI * 440 * t));
			pcm[i * 2] = v;
			pcm[i * 2 + 1] = v;
		}
		game.push(pcm.data(), 480, [&](const uint8_t *d, size_t n, int samples) { pub.sendAudio("game", d, n, samples); });
		std::this_thread::sleep_for(10ms);
	}
	std::this_thread::sleep_for(300ms);
	std::vector<int16_t> mixed(4800 * 2);
	mixer.pull(mixed.data(), 4800);
	double e = 0;
	for(int16_t v : mixed)
		e += static_cast<double>(v) * v;
	const double rms = std::sqrt(e / mixed.size());
	CHECK(audio_packets >= 45, "пакетів Opus отримано: %d (по 20 мс)", audio_packets.load());
	CHECK(rms > 1000, "звук дійшов (RMS %.0f, гучність міксера 0,8)", rms);

	printf("6. Голос глядача: SFU присилає новий offer з треком на прийом → answer гравця → Opus доходить\n");
	{
		// приймач тут грає роль SFU, що пересилає голос глядача
		rtc::Description::Audio va("v1", rtc::Description::Direction::SendOnly);
		va.addOpusCodec(111);
		va.addSSRC(4242, std::string("viewer-voice"));
		auto vt = rx->addTrack(va);
		auto vcfg = std::make_shared<rtc::RtpPacketizationConfig>(4242, "viewer-voice", 111, rtc::OpusRtpPacketizer::DefaultClockRate);
		vt->setMediaHandler(std::make_shared<rtc::OpusRtpPacketizer>(vcfg));
		rx->setLocalDescription(rtc::Description::Type::Offer);
		const bool applied = pub.applyOffer(std::string(*rx->localDescription()), &err);
		CHECK(applied && pub.gatheringComplete(), "новий offer застосовано, answer одразу готовий %s", err.c_str());
		rx->setRemoteDescription(rtc::Description(pub.localSdp(), rtc::Description::Type::Answer));
		CHECK(waitUntil([&]() { return vt->isOpen(); }, 3000), "трек голосу відкрито");
		OpusPacker mic;
		mic.open(1, 32, true);
		std::vector<int16_t> m(480);
		for(int chunk = 0; chunk < 50; chunk++)
		{
			for(int i = 0; i < 480; i++)
				m[i] = static_cast<int16_t>(6000 * std::sin(2 * M_PI * 300 * (chunk * 480 + i) / 48000.0));
			mic.push(m.data(), 480, [&](const uint8_t *d, size_t n, int samples) {
				static uint32_t ts = 0;
				vt->sendFrame(reinterpret_cast<const rtc::byte *>(d), n, rtc::FrameInfo(ts));
				ts += static_cast<uint32_t>(samples);
			});
			std::this_thread::sleep_for(10ms);
		}
	}
	CHECK(waitUntil([&]() { return remote_audio.load() >= 20; }, 3000), "гравець отримав пакетів голосу: %d (mid %s)", remote_audio.load(), remote_mid.c_str());

	pub.close();
	rx->close();
	printf("\n%s: %d помилок\n", g_fail ? "ПОМИЛКИ" : "УСЕ ДОБРЕ", g_fail);
	return g_fail ? 1 : 0;
}
