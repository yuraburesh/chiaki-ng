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
	bool shutdown_output;
	int32_t target_width;
	int32_t target_height;
	ChiakiCodec target_codec;
	// AnyPlay: лічильники для телеметрії (читає інший потік, тому лише через __atomic)
	uint64_t stat_frames_in;   // кадрів прийшло з приставки й віддано декодеру
	uint64_t stat_frames_out;  // кадрів показано на екрані
	uint64_t stat_frames_lost; // кадрів втрачено дорогою (за даними бібліотеки)
	uint64_t stat_bytes_in;    // байтів відео
} AndroidChiakiVideoDecoder;

ChiakiErrorCode android_chiaki_video_decoder_init(AndroidChiakiVideoDecoder *decoder, ChiakiLog *log, int32_t target_width, int32_t target_height, ChiakiCodec codec);
void android_chiaki_video_decoder_fini(AndroidChiakiVideoDecoder *decoder);
void android_chiaki_video_decoder_set_surface(AndroidChiakiVideoDecoder *decoder, JNIEnv *env, jobject surface);
bool android_chiaki_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user);
/** AnyPlay: out[0..3] = кадрів прийшло, показано, втрачено, байтів відео (наростаючі від початку сесії) */
void android_chiaki_video_decoder_stats(AndroidChiakiVideoDecoder *decoder, uint64_t out[4]);

#endif