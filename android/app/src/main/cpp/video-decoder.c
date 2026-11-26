// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "video-decoder.h"

#include <jni.h>

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <android/native_window_jni.h>

#include <chiaki/time.h>

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define INPUT_BUFFER_TIMEOUT_MS 10
#define OUTPUT_BUFFER_TIMEOUT_US 20000    // потік виводу перевіряє «зупинитись» щонайменше раз на 20 мс
#define INPUT_FAILS_RECREATE 45           // стільки кадрів поспіль декодер не приймає — створюємо його заново
#define HEADER_MAX_SIZE 4096
#define KEY_REQUEST_GAP_MS 1500           // декодер сам просить ключовий кадр не частіше
#define KEY_WAIT_MAX_MS 2500              // ключового кадру так і немає — показуємо що є (картинка не стоїть вічно)

// AnyPlay 118. Що тут виправлено (журнали Android: «звук є, картинки немає», «стіки є, картинки немає»):
//  1. set_surface(NULL) тримав м'ютекс і викликав kill_decoder, який брав його вдруге (м'ютекс не рекурсивний) —
//     головний потік зависав назавжди; без декодера ж виходив з функції, не відпустивши м'ютекс, — і далі зависав
//     уже потік відео (звук і керування живуть далі, картинки немає).
//  2. Кадр, що прийшов, поки декодера немає (поверхня ще не готова, декодер не створився), мовчки «приймався»,
//     і новий декодер отримував лише P-кадри без опори — нічого не показував. Тепер декодер сам пропускає кадри
//     до ключового й сам просить його (118.1: не через «кадр не прийнято», бо це давало шторм ключових кадрів).
//  3. Новий декодер (повторне створення, інша поверхня) не мав заголовка потоку (SPS/PPS): той приходить один раз
//     на початку. Тепер заголовок зберігаємо й віддаємо кожному новому декодеру першим.
//  4. Якщо декодер не перемкнувся на нову поверхню (обробка кольорів увімк./вимк.), він далі писав у звільнену —
//     чорний екран. Тепер у такому разі декодер створюється заново на новій поверхні.
//  5. Декодер, що зламався посеред гри (система забрала його, помилка заліза), більше не стоїть мертвим:
//     після серії відмов створюємо його заново. Потік виводу при помилках більше не крутиться вхолосту на 100% ядра.

static void *android_chiaki_video_decoder_output_thread_func(void *user);

ChiakiErrorCode android_chiaki_video_decoder_init(AndroidChiakiVideoDecoder *decoder, ChiakiLog *log, int32_t target_width, int32_t target_height, ChiakiCodec codec)
{
	decoder->log = log;
	decoder->codec = NULL;
	decoder->window = NULL;
	decoder->timestamp_cur = 0;
	decoder->target_width = target_width;
	decoder->target_height = target_height;
	decoder->target_codec = codec;
	decoder->shutdown_output = false;
	decoder->output_thread_running = false;
	decoder->stat_frames_in = 0;
	decoder->stat_frames_out = 0;
	decoder->stat_frames_lost = 0;
	decoder->stat_bytes_in = 0;
	decoder->header = NULL;
	decoder->header_size = 0;
	decoder->input_fails = 0;
	decoder->output_errors = 0;
	decoder->recreated = 0;
	decoder->no_codec_frames = 0;
	decoder->codec_failed = false;
	decoder->need_key = false;
	decoder->need_key_since_ms = 0;
	decoder->key_request_ms = 0;
	decoder->key_requests = 0;
	decoder->dropped = 0;
	decoder->key_frame_cb = NULL;
	decoder->key_frame_user = NULL;
	return chiaki_mutex_init(&decoder->codec_mutex, false);
}

void android_chiaki_video_decoder_stats(AndroidChiakiVideoDecoder *decoder, uint64_t out[ANDROID_VIDEO_STATS_COUNT])
{
	out[7] = __atomic_load_n(&decoder->dropped, __ATOMIC_RELAXED);
	out[8] = __atomic_load_n(&decoder->key_requests, __ATOMIC_RELAXED);
	out[0] = __atomic_load_n(&decoder->stat_frames_in, __ATOMIC_RELAXED);
	out[1] = __atomic_load_n(&decoder->stat_frames_out, __ATOMIC_RELAXED);
	out[2] = __atomic_load_n(&decoder->stat_frames_lost, __ATOMIC_RELAXED);
	out[3] = __atomic_load_n(&decoder->stat_bytes_in, __ATOMIC_RELAXED);
	out[4] = __atomic_load_n(&decoder->codec, __ATOMIC_RELAXED) ? 1 : 0;
	out[5] = __atomic_load_n(&decoder->recreated, __ATOMIC_RELAXED);
	out[6] = __atomic_load_n(&decoder->output_errors, __ATOMIC_RELAXED);
}

/**
 * Які NAL-одиниці на початку буфера (Annex B): 1 — набори параметрів (VPS/SPS/PPS), 2 — зріз кадру.
 * Дивимось лише перші байти: заголовок короткий, а в кадрі зріз іде одразу за кількома службовими одиницями.
 */
static unsigned nal_kinds(const uint8_t *buf, size_t size, bool h265)
{
	unsigned r = 0;
	size_t limit = size < HEADER_MAX_SIZE ? size : HEADER_MAX_SIZE;
	for(size_t i = 0; i + 3 < limit; i++)
	{
		if(buf[i] != 0 || buf[i + 1] != 0 || buf[i + 2] != 1)
			continue;
		uint8_t b = buf[i + 3];
		unsigned t = h265 ? (b >> 1) & 0x3f : b & 0x1f;
		if(h265 ? (t >= 32 && t <= 34) : (t == 7 || t == 8))
			r |= 1;
		else if(h265 ? t <= 31 : (t >= 1 && t <= 5))
			return r | 2;
		i += 3;
	}
	return r;
}

bool android_chiaki_video_is_key_frame(const uint8_t *buf, size_t size, bool h265)
{
	size_t limit = size < HEADER_MAX_SIZE ? size : HEADER_MAX_SIZE;
	for(size_t i = 0; i + 3 < limit; i++)
	{
		if(buf[i] != 0 || buf[i + 1] != 0 || buf[i + 2] != 1)
			continue;
		uint8_t b = buf[i + 3];
		unsigned t = h265 ? (b >> 1) & 0x3f : b & 0x1f;
		if(h265 && t <= 31)
			return t >= 16 && t <= 21;   // BLA/IDR/CRA — з нього декодер починає
		if(!h265 && t >= 1 && t <= 5)
			return t == 5;
		i += 3;
	}
	return false;
}

/** Попереду кадри без опори: пропускати до ключового (від цього моменту) */
static void want_key_locked(AndroidChiakiVideoDecoder *decoder, const char *why)
{
	if(!decoder->need_key)
	{
		decoder->need_key = true;
		decoder->need_key_since_ms = 0;
		CHIAKI_LOGI(decoder->log, "[anyplay-android] waiting for a key frame: %s", why);
	}
}

/** Заголовок потоку (лише набори параметрів, без кадру): запам'ятати для наступних декодерів. Під м'ютексом. */
static void remember_header(AndroidChiakiVideoDecoder *decoder, const uint8_t *buf, size_t size)
{
	if(size == 0 || size > HEADER_MAX_SIZE)
		return;
	if(nal_kinds(buf, size, chiaki_codec_is_h265(decoder->target_codec)) != 1)
		return;
	if(decoder->header && decoder->header_size == size && memcmp(decoder->header, buf, size) == 0)
		return;
	uint8_t *copy = malloc(size);
	if(!copy)
		return;
	memcpy(copy, buf, size);
	free(decoder->header);
	decoder->header = copy;
	decoder->header_size = size;
	CHIAKI_LOGI(decoder->log, "[anyplay-android] stream header saved (%zu bytes)", size);
}

/** Віддати декодеру шматок даних (кадр або заголовок). Під м'ютексом. false — декодер не взяв */
static bool queue_sample(AndroidChiakiVideoDecoder *decoder, const uint8_t *buf, size_t buf_size, ssize_t *fail_status)
{
	*fail_status = 0;
	while(buf_size > 0)
	{
		ssize_t codec_buf_index = AMediaCodec_dequeueInputBuffer(decoder->codec, INPUT_BUFFER_TIMEOUT_MS * 1000);
		if(codec_buf_index < 0)
		{
			*fail_status = codec_buf_index;
			return false;
		}
		size_t codec_buf_size;
		uint8_t *codec_buf = AMediaCodec_getInputBuffer(decoder->codec, (size_t)codec_buf_index, &codec_buf_size);
		if(!codec_buf || codec_buf_size == 0)
		{
			*fail_status = -2;
			return false;
		}
		size_t codec_sample_size = buf_size;
		if(codec_sample_size > codec_buf_size)
		{
			//CHIAKI_LOGD(decoder->log, "Sample is bigger than buffer, splitting");
			codec_sample_size = codec_buf_size;
		}
		memcpy(codec_buf, buf, codec_sample_size);
		media_status_t r = AMediaCodec_queueInputBuffer(decoder->codec, (size_t)codec_buf_index, 0, codec_sample_size, decoder->timestamp_cur++, 0); // timestamp just raised by 1 for maximum realtime
		if(r != AMEDIA_OK)
		{
			CHIAKI_LOGE(decoder->log, "AMediaCodec_queueInputBuffer() failed: %d", (int)r);
			*fail_status = (ssize_t)r;
			return false;
		}
		buf += codec_sample_size;
		buf_size -= codec_sample_size;
	}
	return true;
}

/** Зупинити й прибрати декодер. Під м'ютексом (потік виводу м'ютекса не бере, тож чекати його тут можна) */
static void kill_decoder_locked(AndroidChiakiVideoDecoder *decoder)
{
	if(!decoder->codec)
		return;
	__atomic_store_n(&decoder->shutdown_output, true, __ATOMIC_SEQ_CST);
	if(decoder->output_thread_running)
	{
		// потік виводу чекає кадр не довше 20 мс і бачить прапорець — спершу дочекаємось його, потім зупиняємо декодер,
		// щоб stop() не йшов одночасно з dequeueOutputBuffer в іншому потоці
		chiaki_thread_join(&decoder->output_thread, NULL);
		decoder->output_thread_running = false;
	}
	AMediaCodec_stop(decoder->codec);
	AMediaCodec_delete(decoder->codec);
	__atomic_store_n(&decoder->codec, NULL, __ATOMIC_RELAXED);
	__atomic_store_n(&decoder->shutdown_output, false, __ATOMIC_SEQ_CST);
	decoder->input_fails = 0;
}

/** Створити декодер на decoder->window. Під м'ютексом. */
static bool create_decoder_locked(AndroidChiakiVideoDecoder *decoder)
{
	if(!decoder->window)
		return false;
	const char *mime = chiaki_codec_is_h265(decoder->target_codec) ? "video/hevc" : "video/avc";
	CHIAKI_LOGI(decoder->log, "Initializing decoder with mime %s, %dx%d", mime, (int)decoder->target_width, (int)decoder->target_height);

	AMediaCodec *codec = AMediaCodec_createDecoderByType(mime);
	if(!codec)
	{
		CHIAKI_LOGE(decoder->log, "Failed to create AMediaCodec for mime type %s", mime);
		decoder->codec_failed = true;
		return false;
	}

	AMediaFormat *format = AMediaFormat_new();
	AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, decoder->target_width);
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, decoder->target_height);
	// AnyPlay 118: великий ключовий кадр уміщується в один вхідний буфер (розрізаний на кілька частина декодерів
	// не розбирає), найменша затримка й пріоритет реального часу (де декодер не знає цих ключів, він їх пропускає)
	int32_t max_input = decoder->target_width * decoder->target_height;
	if(max_input < 1024 * 1024)
		max_input = 1024 * 1024;
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_MAX_INPUT_SIZE, max_input);
	AMediaFormat_setInt32(format, "low-latency", 1);
	AMediaFormat_setInt32(format, "priority", 0);

	media_status_t r = AMediaCodec_configure(codec, format, decoder->window, NULL, 0);
	if(r != AMEDIA_OK)
	{
		// запасна спроба з мінімальним набором ключів, як було до 118
		CHIAKI_LOGW(decoder->log, "AMediaCodec_configure() failed: %d, retrying with plain format", (int)r);
		AMediaFormat_delete(format);
		format = AMediaFormat_new();
		AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, decoder->target_width);
		AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, decoder->target_height);
		r = AMediaCodec_configure(codec, format, decoder->window, NULL, 0);
	}
	AMediaFormat_delete(format);
	if(r != AMEDIA_OK)
	{
		CHIAKI_LOGE(decoder->log, "AMediaCodec_configure() failed: %d", (int)r);
		AMediaCodec_delete(codec);
		decoder->codec_failed = true;
		return false;
	}

	r = AMediaCodec_start(codec);
	if(r != AMEDIA_OK)
	{
		CHIAKI_LOGE(decoder->log, "AMediaCodec_start() failed: %d", (int)r);
		AMediaCodec_delete(codec);
		decoder->codec_failed = true;
		return false;
	}

	__atomic_store_n(&decoder->codec, codec, __ATOMIC_RELAXED);
	__atomic_store_n(&decoder->shutdown_output, false, __ATOMIC_SEQ_CST);
	__atomic_store_n(&decoder->output_errors, 0, __ATOMIC_RELAXED);
	decoder->input_fails = 0;
	ChiakiErrorCode err = chiaki_thread_create(&decoder->output_thread, android_chiaki_video_decoder_output_thread_func, decoder);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(decoder->log, "Failed to create output thread for AMediaCodec");
		AMediaCodec_stop(codec);
		AMediaCodec_delete(codec);
		__atomic_store_n(&decoder->codec, NULL, __ATOMIC_RELAXED);
		decoder->codec_failed = true;
		return false;
	}
	decoder->output_thread_running = true;
	decoder->codec_failed = false;
	// новому декодерові посеред потоку потрібен ключовий кадр (на старті ним і так буде перший кадр)
	want_key_locked(decoder, "new decoder");

	// заголовок потоку прийшов раніше (старому декодеру або коли декодера ще не було) — цьому теж потрібен
	if(decoder->header && decoder->header_size)
	{
		ssize_t st;
		if(queue_sample(decoder, decoder->header, decoder->header_size, &st))
			CHIAKI_LOGI(decoder->log, "[anyplay-android] stream header passed to the new decoder");
		else
			CHIAKI_LOGW(decoder->log, "[anyplay-android] new decoder did not take the stream header (%d)", (int)st);
	}
	return true;
}

void android_chiaki_video_decoder_fini(AndroidChiakiVideoDecoder *decoder)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	kill_decoder_locked(decoder);
	if(decoder->window)
	{
		ANativeWindow_release(decoder->window);
		decoder->window = NULL;
	}
	free(decoder->header);
	decoder->header = NULL;
	decoder->header_size = 0;
	chiaki_mutex_unlock(&decoder->codec_mutex);
	chiaki_mutex_fini(&decoder->codec_mutex);
}

bool android_chiaki_video_decoder_set_surface(AndroidChiakiVideoDecoder *decoder, JNIEnv *env, jobject surface)
{
	bool created = false;
	chiaki_mutex_lock(&decoder->codec_mutex);

	if(!surface)
	{
		if(decoder->codec)
		{
			kill_decoder_locked(decoder);
			CHIAKI_LOGI(decoder->log, "Decoder shut down after surface was removed");
		}
		if(decoder->window)
		{
			ANativeWindow_release(decoder->window);
			decoder->window = NULL;
		}
		goto beach;
	}

	ANativeWindow *new_window = ANativeWindow_fromSurface(env, surface);
	if(!new_window)
	{
		CHIAKI_LOGE(decoder->log, "ANativeWindow_fromSurface() failed");
		goto beach;
	}

	if(decoder->codec)
	{
		CHIAKI_LOGI(decoder->log, "Video decoder already initialized, swapping surface");
		media_status_t r = AMediaCodec_setOutputSurface(decoder->codec, new_window);
		if(r != AMEDIA_OK)
		{
			// декодер не вміє перемикатись (частина телефонів): інакше він писав би далі в стару поверхню — чорний екран
			CHIAKI_LOGW(decoder->log, "[anyplay-android] AMediaCodec_setOutputSurface() failed: %d, recreating decoder", (int)r);
			kill_decoder_locked(decoder);
		}
		if(decoder->window)
			ANativeWindow_release(decoder->window);
		decoder->window = new_window;
		if(r == AMEDIA_OK)
			goto beach;
	}
	else
	{
		if(decoder->window)
			ANativeWindow_release(decoder->window);
		decoder->window = new_window;
	}

	// посеред потоку (кадри вже йшли): новому декодеру потрібен ключовий кадр — про це скаже результат
	if(create_decoder_locked(decoder) && (__atomic_load_n(&decoder->stat_frames_in, __ATOMIC_RELAXED) > 0 || decoder->no_codec_frames > 0))
	{
		__atomic_fetch_add(&decoder->recreated, 1, __ATOMIC_RELAXED);
		created = true;
	}

beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return created;
}

bool android_chiaki_video_decoder_reset(AndroidChiakiVideoDecoder *decoder)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	bool ok = false;
	if(decoder->window)
	{
		CHIAKI_LOGI(decoder->log, "[anyplay-android] recreating decoder on request (no picture)");
		kill_decoder_locked(decoder);
		ok = create_decoder_locked(decoder);
		if(ok)
			__atomic_fetch_add(&decoder->recreated, 1, __ATOMIC_RELAXED);
	}
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return ok;
}

bool android_chiaki_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	AndroidChiakiVideoDecoder *decoder = user;
	// телеметрія: рахуємо все, що прийшло з приставки, навіть якщо декодер ще не готовий
	__atomic_fetch_add(&decoder->stat_frames_in, 1, __ATOMIC_RELAXED);
	__atomic_fetch_add(&decoder->stat_bytes_in, (uint64_t)buf_size, __ATOMIC_RELAXED);
	if(frames_lost > 0)
		__atomic_fetch_add(&decoder->stat_frames_lost, (uint64_t)frames_lost, __ATOMIC_RELAXED);
	bool ask_key = false;
	const bool h265 = chiaki_codec_is_h265(decoder->target_codec);
	chiaki_mutex_lock(&decoder->codec_mutex);

	remember_header(decoder, buf, buf_size);
	if(nal_kinds(buf, buf_size, h265) == 1)
	{
		// сам заголовок (на старті й при зміні профілю): поточному декодеру віддаємо одразу, наступні візьмуть з пам'яті
		ssize_t st;
		if(decoder->codec && !queue_sample(decoder, buf, buf_size, &st))
			CHIAKI_LOGW(decoder->log, "[anyplay-android] decoder did not take the stream header (%d)", (int)st);
		goto beach;
	}

	// AnyPlay 118.1: усі збої тут місцеві (декодер телефона), приставка ні до чого. Бібліотеці завжди «прийнято»,
	// щоб вона не звітувала приставці про пошкоджені кадри і не просила ключовий кадр щокадру; кадри без опори
	// пропускаємо самі й самі просимо один ключовий кадр (не частіше ніж раз на KEY_REQUEST_GAP_MS)
	if(!decoder->codec)
	{
		if(decoder->no_codec_frames++ % 120 == 0)
			CHIAKI_LOGE(decoder->log, "Received video data, but decoder is not initialized! (%u frames so far%s)",
					(unsigned)decoder->no_codec_frames, decoder->codec_failed ? ", decoder creation failed" : ", no surface yet");
		want_key_locked(decoder, "no decoder");
		__atomic_fetch_add(&decoder->dropped, 1, __ATOMIC_RELAXED);
		goto beach;
	}

	const uint64_t now = chiaki_time_now_monotonic_ms();
	if(decoder->need_key)
	{
		if(android_chiaki_video_is_key_frame(buf, buf_size, h265))
		{
			CHIAKI_LOGI(decoder->log, "[anyplay-android] key frame arrived, decoding again");
			decoder->need_key = false;
		}
		else
		{
			if(!decoder->need_key_since_ms)
				decoder->need_key_since_ms = now;
			if(now - decoder->need_key_since_ms < KEY_WAIT_MAX_MS)
			{
				if(now - decoder->key_request_ms >= KEY_REQUEST_GAP_MS)
				{
					decoder->key_request_ms = now;
					ask_key = true;
				}
				__atomic_fetch_add(&decoder->dropped, 1, __ATOMIC_RELAXED);
				goto beach;
			}
			CHIAKI_LOGW(decoder->log, "[anyplay-android] no key frame for %u ms, decoding what comes", (unsigned)(now - decoder->need_key_since_ms));
			decoder->need_key = false;
		}
	}

	if(__atomic_load_n(&decoder->output_errors, __ATOMIC_RELAXED) >= 50)
	{
		// вивід декодера зламався (кадри не виходять), хоча вхід ще приймає — створюємо заново
		CHIAKI_LOGW(decoder->log, "[anyplay-android] decoder output keeps failing, recreating");
		kill_decoder_locked(decoder);
		if(create_decoder_locked(decoder))
			__atomic_fetch_add(&decoder->recreated, 1, __ATOMIC_RELAXED);
		__atomic_fetch_add(&decoder->dropped, 1, __ATOMIC_RELAXED);
		goto beach;
	}

	ssize_t fail_status = 0;
	if(!queue_sample(decoder, buf, buf_size, &fail_status))
	{
		decoder->input_fails++;
		__atomic_fetch_add(&decoder->dropped, 1, __ATOMIC_RELAXED);
		if(decoder->input_fails == 1 || decoder->input_fails % 30 == 0)
			CHIAKI_LOGE(decoder->log, "Failed to get input buffer (status %d, %u frames in a row)", (int)fail_status, (unsigned)decoder->input_fails);
		// пропущений кадр — опора наступних, тож далі до ключового
		want_key_locked(decoder, "decoder did not take a frame");
		// декодер стоїть: довго не бере кадри або видає справжні помилки (не «спробуй пізніше») — створюємо його заново
		const bool hard = fail_status != AMEDIACODEC_INFO_TRY_AGAIN_LATER;
		if(decoder->input_fails >= INPUT_FAILS_RECREATE || (hard && decoder->input_fails >= 5))
		{
			CHIAKI_LOGW(decoder->log, "[anyplay-android] decoder stuck (status %d, %u fails, %u output errors), recreating",
					(int)fail_status, (unsigned)decoder->input_fails, (unsigned)__atomic_load_n(&decoder->output_errors, __ATOMIC_RELAXED));
			kill_decoder_locked(decoder);
			if(create_decoder_locked(decoder))
				__atomic_fetch_add(&decoder->recreated, 1, __ATOMIC_RELAXED);
		}
		if(now - decoder->key_request_ms >= KEY_REQUEST_GAP_MS)
		{
			decoder->key_request_ms = now;
			ask_key = true;
		}
		goto beach;
	}
	decoder->input_fails = 0;

beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
	if(ask_key && decoder->key_frame_cb)
	{
		__atomic_fetch_add(&decoder->key_requests, 1, __ATOMIC_RELAXED);
		decoder->key_frame_cb(decoder->key_frame_user);
	}
	return true;
}

static void *android_chiaki_video_decoder_output_thread_func(void *user)
{
	AndroidChiakiVideoDecoder *decoder = user;
	AMediaCodec *codec = __atomic_load_n(&decoder->codec, __ATOMIC_RELAXED);
	uint32_t errors_logged = 0;

	while(!__atomic_load_n(&decoder->shutdown_output, __ATOMIC_SEQ_CST))
	{
		AMediaCodecBufferInfo info;
		ssize_t status = AMediaCodec_dequeueOutputBuffer(codec, &info, OUTPUT_BUFFER_TIMEOUT_US);
		if(status >= 0)
		{
			AMediaCodec_releaseOutputBuffer(codec, (size_t)status, info.size != 0);
			if(info.size != 0)
				__atomic_fetch_add(&decoder->stat_frames_out, 1, __ATOMIC_RELAXED);
			if(info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)
			{
				CHIAKI_LOGI(decoder->log, "AMediaCodec reported EOS");
				break;
			}
		}
		else if(status == AMEDIACODEC_INFO_TRY_AGAIN_LATER || status == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED
			|| status == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)
		{
			if(status == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED)
				CHIAKI_LOGI(decoder->log, "AMediaCodec output format changed");
		}
		else
		{
			// справжня помилка декодера: рахуємо (потік відео створить його заново) і не крутимось вхолосту
			uint32_t n = __atomic_add_fetch(&decoder->output_errors, 1, __ATOMIC_RELAXED);
			if(errors_logged < 5 || n % 100 == 0)
			{
				errors_logged++;
				CHIAKI_LOGE(decoder->log, "AMediaCodec_dequeueOutputBuffer() error %d (%u so far)", (int)status, (unsigned)n);
			}
			usleep(5000);
		}
	}

	CHIAKI_LOGI(decoder->log, "Video Decoder Output Thread exiting");

	return NULL;
}
