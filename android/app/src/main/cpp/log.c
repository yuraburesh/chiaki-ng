// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "log.h"

#include <android/log.h>

#include <string.h>
#include <errno.h>
#include <jni.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>

#include "chiaki-jni.h"

#define LOG_TAG "Chiaki"

// AnyPlay: останні помилки бібліотеки (усіх журналів) — з них програма дістає технічний код для клієнта й підтримки:
// бібліотека повертає лише загальний код («помилка мережі»), а статус HTTP чи помилку curl пише тільки в журнал
#define ANYPLAY_ERRORS_MAX 12
#define ANYPLAY_ERROR_LEN 512
static pthread_mutex_t anyplay_errors_mutex = PTHREAD_MUTEX_INITIALIZER;
static char anyplay_errors[ANYPLAY_ERRORS_MAX][ANYPLAY_ERROR_LEN];
static unsigned int anyplay_errors_count = 0;

static void anyplay_log_note_error(const char *msg)
{
	pthread_mutex_lock(&anyplay_errors_mutex);
	char *slot = anyplay_errors[anyplay_errors_count % ANYPLAY_ERRORS_MAX];
	strncpy(slot, msg, ANYPLAY_ERROR_LEN - 1);
	slot[ANYPLAY_ERROR_LEN - 1] = 0;
	anyplay_errors_count++;
	pthread_mutex_unlock(&anyplay_errors_mutex);
}

void anyplay_log_clear_errors(void)
{
	pthread_mutex_lock(&anyplay_errors_mutex);
	anyplay_errors_count = 0;
	pthread_mutex_unlock(&anyplay_errors_mutex);
}

size_t anyplay_log_last_errors(char *out, size_t out_size)
{
	if(!out_size)
		return 0;
	size_t off = 0;
	out[0] = 0;
	pthread_mutex_lock(&anyplay_errors_mutex);
	unsigned int n = anyplay_errors_count < ANYPLAY_ERRORS_MAX ? anyplay_errors_count : ANYPLAY_ERRORS_MAX;
	for(unsigned int i = anyplay_errors_count - n; i < anyplay_errors_count; i++)
	{
		const char *line = anyplay_errors[i % ANYPLAY_ERRORS_MAX];
		size_t len = strlen(line);
		if(off + len + 2 > out_size)
			break;
		memcpy(out + off, line, len);
		off += len;
		out[off++] = '\n';
		out[off] = 0;
	}
	pthread_mutex_unlock(&anyplay_errors_mutex);
	return off;
}

void log_cb_android(ChiakiLogLevel level, const char *msg, void *user)
{
	if(level == CHIAKI_LOG_ERROR)
		anyplay_log_note_error(msg);
	int prio;
	switch(level)
	{
		case CHIAKI_LOG_DEBUG:
			prio = ANDROID_LOG_DEBUG;
			break;
		case CHIAKI_LOG_VERBOSE:
			prio = ANDROID_LOG_VERBOSE;
			break;
		case CHIAKI_LOG_INFO:
			prio = ANDROID_LOG_INFO;
			break;
		case CHIAKI_LOG_WARNING:
			prio = ANDROID_LOG_ERROR;
			break;
		case CHIAKI_LOG_ERROR:
			prio = ANDROID_LOG_ERROR;
			break;
		default:
			prio = ANDROID_LOG_INFO;
			break;
	}
	__android_log_write(prio, LOG_TAG, msg);
}

static void log_cb_android_file(ChiakiLogLevel level, const char *msg, void *user)
{
	log_cb_android(level, msg, user);
	FILE *f = user;
	if(!f)
		return;
	char tag;
	switch(level)
	{
		case CHIAKI_LOG_DEBUG: tag = 'D'; break;
		case CHIAKI_LOG_VERBOSE: tag = 'V'; break;
		case CHIAKI_LOG_INFO: tag = 'I'; break;
		case CHIAKI_LOG_WARNING: tag = 'W'; break;
		case CHIAKI_LOG_ERROR: tag = 'E'; break;
		default: tag = '?'; break;
	}
	// AnyPlay 118.2: час кожного рядка і запис на диск одразу. До цього рядки сиділи в буфері stdio, і коли процес
	// гинув, хвіст журналу пропадав (журнал Galaxy S7 обривався посеред «Senkusha sending P»)
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	struct tm tm;
	time_t secs = ts.tv_sec;
	localtime_r(&secs, &tm);
	flockfile(f);
	fprintf(f, "[%c] %02d:%02d:%02d.%03ld %s\n", tag, tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec / 1000000, msg);
	fflush(f);
	funlockfile(f);
}

ChiakiErrorCode android_chiaki_file_log_init(ChiakiLog *log, uint32_t level, const char *file)
{
	chiaki_log_init(log, level, log_cb_android, NULL);
	if(file)
	{
		FILE *f = fopen(file, "w+");
		if(!f)
		{
			CHIAKI_LOGE(log, "Failed to open log file %s for writing: %s", file, strerror(errno));
			return CHIAKI_ERR_UNKNOWN;
		}
		else
		{
			log->user = f;
			log->cb = log_cb_android_file;
			CHIAKI_LOGI(log, "Logging to file %s", file);
		}
	}
	return CHIAKI_ERR_SUCCESS;
}

void android_chiaki_file_log_fini(ChiakiLog *log)
{
	if(log->user)
	{
		FILE *f = log->user;
		fclose(f);
		log->user = NULL;
	}
}



static void android_chiaki_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	log_cb_android(level, msg, NULL);

	AndroidChiakiJNILog *log = user;
	JNIEnv *env = attach_thread_jni();
	if(!env)
		return;
	E->CallVoidMethod(env, log->java_log, log->java_log_meth, (jint)level, jnistr_from_ascii(env, msg));
	(*global_vm)->DetachCurrentThread(global_vm);
}

void android_chiaki_jni_log_init(AndroidChiakiJNILog *log, JNIEnv *env, jobject java_log)
{
	log->java_log = E->NewGlobalRef(env, java_log);
	jclass log_class = E->GetObjectClass(env, log->java_log);
	log->java_log_meth = E->GetMethodID(env, log_class, "log", "(ILjava/lang/String;)V");
	log->log.level_mask = (uint32_t)E->GetIntField(env, log->java_log, E->GetFieldID(env, log_class, "levelMask", "I"));
	log->log.cb = android_chiaki_log_cb;
	log->log.user = log;
}

void android_chiaki_jni_log_fini(AndroidChiakiJNILog *log, JNIEnv *env)
{
	E->DeleteGlobalRef(env, log->java_log);
}