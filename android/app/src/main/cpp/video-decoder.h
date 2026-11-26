// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_JNI_VIDEO_DECODER_H
#define CHIAKI_JNI_VIDEO_DECODER_H

#include <jni.h>

#include <chiaki/thread.h>
#include <chiaki/log.h>

typedef struct AMediaCodec AMediaCodec;
typedef struct ANativeWindow ANativeWindow;

typedef struct android_chiaki_video_decoder_t
{
	ChiakiLog *log;
	ChiakiMutex codec_mutex;
	AMediaCodec *codec;
	ANativeWindow *window;
	uint64_t timestamp_cur;
	ChiakiThread output_thread;
	bool output_thread_running;
	bool shutdown_output; // AnyPlay: читає потік виводу без м'ютекса, тому лише через __atomic
	int32_t target_width;
	int32_t target_height;
	ChiakiCodec target_codec;
	// AnyPlay: лічильники для телеметрії (читає інший потік, тому лише через __atomic)
	uint64_t stat_frames_in;   // кадрів прийшло з приставки й віддано декодеру
	uint64_t stat_frames_out;  // кадрів показано на екрані
	uint64_t stat_frames_lost; // кадрів втрачено дорогою (за даними бібліотеки)
	uint64_t stat_bytes_in;    // байтів відео
	// AnyPlay 118: стійкість декодера (чорний екран при живому звуці)
	uint8_t *header;           // заголовок потоку (SPS/PPS, у HEVC ще VPS): віддаємо кожному новому декодеру першим
	size_t header_size;
	uint32_t input_fails;      // кадрів поспіль, які декодер не прийняв
	uint32_t output_errors;    // помилок потоку виводу з останнього (пере)створення (__atomic)
	uint32_t recreated;        // скільки разів декодер створено заново за сесію (__atomic)
	uint32_t no_codec_frames;  // кадрів прийшло, коли декодера ще (або вже) немає
	bool codec_failed;         // останнє створення декодера не вдалося
	// AnyPlay 118.1: місцеві збої (декодера ще немає, немає вхідного буфера, декодер перестворюється) більше не
	// повідомляються бібліотеці як «кадр не прийнято»: інакше вона щокадру звітувала приставці про пошкоджені кадри,
	// і та слала ключовий кадр через кожні 2–3 кадри (шторм у журналі Galaxy S7). Тепер декодер сам пропускає кадри
	// до ключового і сам просить один ключовий кадр, не частіше ніж раз на KEY_REQUEST_GAP_MS
	bool need_key;             // кадри до ключового не мають опори — пропускаємо
	uint64_t need_key_since_ms;
	uint64_t key_request_ms;   // коли востаннє просили ключовий кадр
	uint32_t key_requests;     // скільки разів просили (__atomic)
	uint32_t dropped;          // кадрів пропущено через місцеві збої (__atomic)
	void (*key_frame_cb)(void *user);   // попросити в приставки ключовий кадр (ставить JNI)
	void *key_frame_user;
} AndroidChiakiVideoDecoder;

ChiakiErrorCode android_chiaki_video_decoder_init(AndroidChiakiVideoDecoder *decoder, ChiakiLog *log, int32_t target_width, int32_t target_height, ChiakiCodec codec);
void android_chiaki_video_decoder_fini(AndroidChiakiVideoDecoder *decoder);
/** @return true, якщо декодер створено заново посеред потоку (тоді потрібен ключовий кадр) */
bool android_chiaki_video_decoder_set_surface(AndroidChiakiVideoDecoder *decoder, JNIEnv *env, jobject surface);
/** AnyPlay 118: створити декодер заново на тій самій поверхні (картинка не йде). @return true, якщо вийшло */
bool android_chiaki_video_decoder_reset(AndroidChiakiVideoDecoder *decoder);
bool android_chiaki_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user);
/** AnyPlay: out[0..3] = кадрів прийшло, показано, втрачено, байтів відео (наростаючі від початку сесії);
 * out[4] = декодер є (1) чи ні (0), out[5] = скільки разів створено заново, out[6] = помилок виводу,
 * out[7] = кадрів пропущено через місцеві збої, out[8] = запитів ключового кадру від декодера */
#define ANDROID_VIDEO_STATS_COUNT 9
void android_chiaki_video_decoder_stats(AndroidChiakiVideoDecoder *decoder, uint64_t out[ANDROID_VIDEO_STATS_COUNT]);
/** AnyPlay 118.1: чи перший зріз кадру ключовий (HEVC NAL 16–21, H.264 NAL 5) */
bool android_chiaki_video_is_key_frame(const uint8_t *buf, size_t size, bool h265);

#endif
