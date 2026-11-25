// AnyPlay 116: трансляція для друзів — медіа без Qt. Див. anyplaylivemedia.h.
#include "anyplaylivemedia.h"

#include <rtc/rtc.hpp>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

#include <opus/opus.h>

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

static std::string averr(int err)
{
	char buf[AV_ERROR_MAX_STRING_SIZE] = {};
	av_strerror(err, buf, sizeof(buf));
	return buf;
}

// потік кодування не має відбирати час у гри: нижчий пріоритет
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

// ───────────────────────────── відео ─────────────────────────────

VideoEncoder::~VideoEncoder()
{
	close();
}

std::vector<std::string> VideoEncoder::candidates(bool allowSoftware)
{
	std::vector<std::string> list;
#if defined(_WIN32)
	// NVIDIA, AMD, Intel; Media Foundation — апаратний кодувальник через Windows (hw_encoding=1, програмний не приймаємо)
	list = { "h264_nvenc", "h264_amf", "h264_qsv", "h264_mf" };
#elif defined(__APPLE__)
	list = { "h264_videotoolbox" };
#else
	list = { "h264_nvenc", "h264_qsv" };
#endif
	if(allowSoftware)
	{
		list.push_back("libx264");
		list.push_back("libopenh264");
	}
	return list;
}

bool VideoEncoder::open(const VideoConfig &cfg, bool allowSoftware, std::string *err)
{
	close();
	std::string errors;
	for(const std::string &name : candidates(allowSoftware))
	{
		std::string e;
		const int64_t t0 = nowUs();
		if(openNamed(name, cfg, &e))
		{
			logf("encoder %s opened %dx%d@%d %d kbps in %d ms", name.c_str(), cfg.width, cfg.height, cfg.fps, cfg.kbps,
				static_cast<int>((nowUs() - t0) / 1000));
			return true;
		}
		logf("encoder %s unavailable: %s", name.c_str(), e.c_str());
		if(!errors.empty())
			errors += "; ";
		errors += name + ": " + e;
	}
	if(err)
		*err = errors.empty() ? std::string("no H.264 encoders") : errors;
	return false;
}

static void setOpt(AVDictionary **d, const char *k, const char *v)
{
	av_dict_set(d, k, v, 0);
}

bool VideoEncoder::openNamed(const std::string &codec_name, const VideoConfig &cfg, std::string *err)
{
	const AVCodec *codec = avcodec_find_encoder_by_name(codec_name.c_str());
	if(!codec)
	{
		*err = "not in this FFmpeg build";
		return false;
	}
	// дві спроби: з усіма побажаннями для низької затримки, потім лише з обов'язковими (старі драйвери не знають частини опцій)
	for(int attempt = 0; attempt < 2; attempt++)
	{
		AVCodecContext *ctx = avcodec_alloc_context3(codec);
		if(!ctx)
		{
			*err = "alloc";
			return false;
		}
		ctx->width = cfg.width;
		ctx->height = cfg.height;
		ctx->time_base = AVRational{ 1, cfg.fps };
		ctx->framerate = AVRational{ cfg.fps, 1 };
		ctx->pix_fmt = AV_PIX_FMT_NV12;
		ctx->bit_rate = static_cast<int64_t>(cfg.kbps) * 1000;
		ctx->rc_max_rate = ctx->bit_rate;
		ctx->rc_buffer_size = static_cast<int>(ctx->bit_rate / 2);   // ~0,5 с: рівний потік без великих стрибків
		ctx->gop_size = cfg.fps * 2;                                  // ключовий кадр раз на 2 с (новий глядач бачить картинку швидко)
		ctx->max_b_frames = 0;                                        // B-кадри дають затримку і не всі браузери їх люблять
		ctx->color_range = AVCOL_RANGE_MPEG;
		ctx->colorspace = AVCOL_SPC_BT709;
		ctx->color_primaries = AVCOL_PRI_BT709;
		ctx->color_trc = AVCOL_TRC_BT709;
		AVDictionary *opts = nullptr;
		const bool full = attempt == 0;
		if(codec_name == "h264_nvenc")
		{
			setOpt(&opts, "preset", "p2");
			setOpt(&opts, "tune", "ull");
			setOpt(&opts, "rc", "cbr");
			setOpt(&opts, "zerolatency", "1");
			setOpt(&opts, "delay", "0");
			setOpt(&opts, "forced-idr", "1");
			if(full)
				setOpt(&opts, "profile", "baseline");
		}
		else if(codec_name == "h264_amf")
		{
			setOpt(&opts, "usage", "ultralowlatency");
			setOpt(&opts, "quality", "speed");
			setOpt(&opts, "rc", "cbr");
			if(full)
			{
				setOpt(&opts, "profile", "constrained_baseline");
				setOpt(&opts, "latency", "1");
			}
		}
		else if(codec_name == "h264_qsv")
		{
			setOpt(&opts, "preset", "veryfast");
			setOpt(&opts, "async_depth", "1");
			if(full)
			{
				setOpt(&opts, "profile", "baseline");
				setOpt(&opts, "forced_idr", "1");
			}
		}
		else if(codec_name == "h264_mf")
		{
			setOpt(&opts, "hw_encoding", "1");   // лише апаратний MFT
			setOpt(&opts, "rate_control", "cbr");
			if(full)
				setOpt(&opts, "scenario", "display_remoting");
		}
		else if(codec_name == "h264_videotoolbox")
		{
			setOpt(&opts, "realtime", "1");
			setOpt(&opts, "allow_sw", "0");
			if(full)
			{
				setOpt(&opts, "profile", "constrained_baseline");
				setOpt(&opts, "prio_speed", "1");
			}
		}
		else if(codec_name == "libx264")
		{
			setOpt(&opts, "preset", "ultrafast");
			setOpt(&opts, "tune", "zerolatency");
			setOpt(&opts, "profile", "baseline");
			setOpt(&opts, "forced-idr", "1");
		}
		const int r = avcodec_open2(ctx, codec, &opts);
		av_dict_free(&opts);
		if(r >= 0)
		{
			ctx_ = ctx;
			name_ = codec_name;
			cfg_ = cfg;
			pts_ = 0;
			sps_pps_.clear();
			if(ctx->extradata && ctx->extradata_size > 4)
				rememberParameterSets(ctx->extradata, static_cast<size_t>(ctx->extradata_size));
			scaled_ = av_frame_alloc();
			sw_ = av_frame_alloc();
			if(!scaled_ || !sw_)
			{
				close();
				*err = "alloc";
				return false;
			}
			scaled_->format = AV_PIX_FMT_NV12;
			scaled_->width = cfg.width;
			scaled_->height = cfg.height;
			if(av_frame_get_buffer(scaled_, 0) < 0)
			{
				close();
				*err = "frame buffer";
				return false;
			}
			return true;
		}
		*err = averr(r);
		avcodec_free_context(&ctx);
	}
	return false;
}

void VideoEncoder::close()
{
	if(ctx_)
		avcodec_free_context(&ctx_);
	if(sws_)
	{
		sws_freeContext(sws_);
		sws_ = nullptr;
	}
	av_frame_free(&sw_);
	av_frame_free(&scaled_);
	sws_src_w_ = sws_src_h_ = 0;
	sws_src_fmt_ = -1;
	name_.clear();
}

// NAL-одиниці Annex-B: колбек (тип, початок з кодом, довжина з кодом)
template<typename F> static void forEachNal(const uint8_t *d, size_t n, F f)
{
	size_t i = 0;
	auto find_start = [&](size_t from, size_t *code_len) -> size_t {
		for(size_t k = from; k + 3 <= n; k++)
		{
			if(d[k] == 0 && d[k + 1] == 0)
			{
				if(d[k + 2] == 1) { *code_len = 3; return k; }
				if(k + 4 <= n && d[k + 2] == 0 && d[k + 3] == 1) { *code_len = 4; return k; }
			}
		}
		*code_len = 0;
		return n;
	};
	size_t cl = 0;
	i = find_start(0, &cl);
	while(i < n)
	{
		size_t next_cl = 0;
		const size_t next = find_start(i + cl, &next_cl);
		if(i + cl < n)
			f(d[i + cl] & 0x1f, d + i, next - i);
		i = next;
		cl = next_cl;
	}
}

void VideoEncoder::rememberParameterSets(const uint8_t *data, size_t size)
{
	std::vector<uint8_t> sets;
	forEachNal(data, size, [&](int type, const uint8_t *p, size_t len) {
		if(type == 7 || type == 8)
			sets.insert(sets.end(), p, p + len);
	});
	if(!sets.empty())
		sps_pps_ = std::move(sets);
}

bool VideoEncoder::prepareInput(const AVFrame *src, std::string *err)
{
	const AVFrame *in = src;
	transfer_ms_ = 0;
	if(src->hw_frames_ctx)
	{
		// копія з відеокарти; одразу після неї кадр гри відпускається (декодер не чекає)
		av_frame_unref(sw_);
		const int64_t t0 = nowUs();
		const int r = av_hwframe_transfer_data(sw_, src, 0);
		transfer_ms_ = (nowUs() - t0) / 1000.0;
		if(r < 0)
		{
			*err = "hwframe transfer: " + averr(r);
			return false;
		}
		in = sw_;
	}
	const int64_t t0 = nowUs();
	if(!sws_ || sws_src_w_ != in->width || sws_src_h_ != in->height || sws_src_fmt_ != in->format)
	{
		sws_ = sws_getCachedContext(sws_, in->width, in->height, static_cast<AVPixelFormat>(in->format),
			cfg_.width, cfg_.height, AV_PIX_FMT_NV12, SWS_BILINEAR, nullptr, nullptr, nullptr);
		if(!sws_)
		{
			const char *fmt_name = av_get_pix_fmt_name(static_cast<AVPixelFormat>(in->format));
			*err = std::string("swscale: unsupported ") + (fmt_name ? fmt_name : "?");
			return false;
		}
		sws_src_w_ = in->width;
		sws_src_h_ = in->height;
		sws_src_fmt_ = in->format;
	}
	// кодувальник може ще тримати попередній буфер: тоді беремо новий
	if(av_frame_make_writable(scaled_) < 0)
	{
		*err = "frame not writable";
		return false;
	}
	sws_scale(sws_, in->data, in->linesize, 0, in->height, scaled_->data, scaled_->linesize);
	scale_ms_ = (nowUs() - t0) / 1000.0;
	if(in == sw_)
		av_frame_unref(sw_);
	return true;
}

bool VideoEncoder::encode(const AVFrame *src, bool forceKey, std::vector<uint8_t> *out, bool *isKey, std::string *err)
{
	out->clear();
	*isKey = false;
	if(!ctx_)
	{
		*err = "encoder closed";
		return false;
	}
	if(!prepareInput(src, err))
		return false;
	const int64_t t0 = nowUs();
	scaled_->pts = pts_++;
	scaled_->pict_type = forceKey ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
	int r = avcodec_send_frame(ctx_, scaled_);
	if(r < 0 && r != AVERROR(EAGAIN))
	{
		*err = "send_frame: " + averr(r);
		return false;
	}
	AVPacket *pkt = av_packet_alloc();
	if(!pkt)
	{
		*err = "alloc";
		return false;
	}
	while(true)
	{
		r = avcodec_receive_packet(ctx_, pkt);
		if(r == AVERROR(EAGAIN) || r == AVERROR_EOF)
			break;
		if(r < 0)
		{
			*err = "receive_packet: " + averr(r);
			av_packet_free(&pkt);
			return false;
		}
		const bool key = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
		bool has_sps = false;
		forEachNal(pkt->data, static_cast<size_t>(pkt->size), [&](int type, const uint8_t *, size_t) {
			if(type == 7)
				has_sps = true;
		});
		if(has_sps)
			rememberParameterSets(pkt->data, static_cast<size_t>(pkt->size));
		else if(key && !sps_pps_.empty())
			out->insert(out->end(), sps_pps_.begin(), sps_pps_.end());   // глядач, що прийшов посеред гри, має отримати SPS/PPS
		out->insert(out->end(), pkt->data, pkt->data + pkt->size);
		*isKey = *isKey || key;
		av_packet_unref(pkt);
	}
	av_packet_free(&pkt);
	encode_ms_ = (nowUs() - t0) / 1000.0;
	return true;
}

VideoPipeline::VideoPipeline() = default;

VideoPipeline::~VideoPipeline()
{
	stop();
}

void VideoPipeline::start(const VideoConfig &cfg, bool allowSoftware, Output out, Status status)
{
	stop();
	{
		std::lock_guard<std::mutex> lock(mutex_);
		cfg_ = cfg;
		quit_ = false;
		reconfig_ = false;
		out_ = std::move(out);
		status_ = std::move(status);
	}
	interval_us_.store(1000000 / std::max(1, cfg.fps));
	next_due_us_.store(0);
	want_key_.store(true);
	frames_encoded.store(0);
	frames_dropped.store(0);
	bytes_out.store(0);
	errors.store(0);
	thread_ = std::thread([this, allowSoftware]() { run(allowSoftware); });
}

void VideoPipeline::stop()
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
	if(pending_)
		av_frame_free(&pending_);
}

void VideoPipeline::reconfigure(const VideoConfig &cfg)
{
	{
		std::lock_guard<std::mutex> lock(mutex_);
		cfg_ = cfg;
		reconfig_ = true;
	}
	interval_us_.store(1000000 / std::max(1, cfg.fps));
	cv_.notify_all();
}

VideoConfig VideoPipeline::config() const
{
	std::lock_guard<std::mutex> lock(mutex_);
	return cfg_;
}

bool VideoPipeline::wantsFrame(int64_t now_us) const
{
	return running_.load(std::memory_order_relaxed) && !paused_.load(std::memory_order_relaxed)
		&& now_us >= next_due_us_.load(std::memory_order_relaxed);
}

void VideoPipeline::offer(const AVFrame *frame)
{
	if(!frame || !running_.load(std::memory_order_relaxed))
		return;
	const int64_t now = nowUs();
	// кадри гри йдуть рівно (наприклад 60 за секунду), трансляції треба 30: беремо кожен, після якого минув інтервал
	// (з запасом 3 мс на нерівність показу)
	next_due_us_.store(now + interval_us_.load(std::memory_order_relaxed) - 3000, std::memory_order_relaxed);
	AVFrame *copy = av_frame_clone(frame);   // лише посилання: гра далі йде без чекання
	if(!copy)
		return;
	AVFrame *old = nullptr;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		old = pending_;
		pending_ = copy;
		pending_us_ = now;
	}
	if(old)
	{
		av_frame_free(&old);
		frames_dropped.fetch_add(1, std::memory_order_relaxed);
	}
	cv_.notify_one();
}

void VideoPipeline::run(bool allowSoftware)
{
	lowerThreadPriority();
	VideoEncoder enc;
	VideoConfig cfg;
	{
		std::lock_guard<std::mutex> lock(mutex_);
		cfg = cfg_;
	}
	std::string err;
	const bool ok = enc.open(cfg, allowSoftware, &err);
	if(status_)
		status_(ok, enc.name(), err);
	if(!ok)
		return;
	running_.store(true);
	std::vector<uint8_t> au;
	double avg_us = 0;
	int consecutive_errors = 0;
	while(true)
	{
		AVFrame *frame = nullptr;
		int64_t capture_us = 0;
		bool reopen = false;
		{
			std::unique_lock<std::mutex> lock(mutex_);
			cv_.wait_for(lock, std::chrono::milliseconds(500), [this]() { return quit_ || pending_ || reconfig_; });
			if(quit_)
				break;
			if(reconfig_)
			{
				reconfig_ = false;
				reopen = true;
				cfg = cfg_;
			}
			frame = pending_;
			pending_ = nullptr;
			capture_us = pending_us_;
		}
		if(reopen)
		{
			// нова якість: той самий кодувальник з новими розмірами й бітрейтом
			const std::string had = enc.name();
			enc.close();
			if(!enc.open(cfg, allowSoftware, &err))
			{
				logf("encoder reopen failed: %s", err.c_str());
				running_.store(false);
				if(status_)
					status_(false, had, err);
				av_frame_free(&frame);
				break;
			}
			want_key_.store(true);
		}
		if(!frame)
			continue;
		const int64_t t0 = nowUs();
		bool key = false;
		const bool force = want_key_.exchange(false);
		if(!enc.encode(frame, force, &au, &key, &err))
		{
			errors.fetch_add(1);
			if(force)
				want_key_.store(true);
			if(++consecutive_errors == 1 || consecutive_errors % 100 == 0)
				logf("encode error #%d: %s", consecutive_errors, err.c_str());
			if(consecutive_errors >= 30)
			{
				// кодувальник зламався (драйвер, сон комп'ютера): пробуємо відкрити заново один раз
				enc.close();
				if(!enc.open(cfg, allowSoftware, &err))
				{
					running_.store(false);
					if(status_)
						status_(false, std::string(), err);
					av_frame_free(&frame);
					break;
				}
				consecutive_errors = 0;
				want_key_.store(true);
			}
			av_frame_free(&frame);
			continue;
		}
		consecutive_errors = 0;
		av_frame_free(&frame);
		const int64_t spent = nowUs() - t0;
		avg_us = avg_us <= 0 ? spent : avg_us * 0.9 + spent * 0.1;
		encode_us_avg.store(static_cast<int>(avg_us), std::memory_order_relaxed);
		if(au.empty())
			continue;
		frames_encoded.fetch_add(1, std::memory_order_relaxed);
		bytes_out.fetch_add(static_cast<int64_t>(au.size()), std::memory_order_relaxed);
		if(out_)
			out_(au, key, capture_us);
	}
	running_.store(false);
	enc.close();
}

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
			const size_t take = std::min(v.pcm.size(), frames * 2);
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

void Peer::addVideo(const std::string &mid, double paceKbps)
{
	if(!pc_)
		return;
	const uint32_t ssrc = randomSsrc();
	rtc::Description::Video media(mid, rtc::Description::Direction::SendOnly);
	media.addH264Codec(96);   // constrained baseline 3.1, packetization-mode=1
	media.addSSRC(ssrc, std::string("anyplay-") + mid, std::string("anyplay"), mid);
	auto track = pc_->addTrack(media);
	auto cfg = std::make_shared<rtc::RtpPacketizationConfig>(ssrc, "anyplay-" + mid, 96, rtc::H264RtpPacketizer::ClockRate);
	auto pack = std::make_shared<rtc::H264RtpPacketizer>(rtc::NalUnit::Separator::StartSequence, cfg, 1100);
	pack->addToChain(std::make_shared<rtc::RtcpSrReporter>(cfg));
	pack->addToChain(std::make_shared<rtc::RtcpNackResponder>(1024));
	pack->addToChain(std::make_shared<rtc::PliHandler>([this]() {
		if(cb_.keyframe)
			cb_.keyframe();
	}));
	pack->addToChain(std::make_shared<rtc::RembHandler>([this](unsigned bps) {
		if(cb_.remb)
			cb_.remb(bps / 1000);
	}));
	// ключовий кадр не вилітає одним шматком (сотні пакетів за мить забивали б канал гравця)
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
	if(!video_start_us_)
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
