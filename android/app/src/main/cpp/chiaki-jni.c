// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <jni.h>

#include <android/log.h>

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/session.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/regist.h>
#include <chiaki/remote/holepunch.h>

#include <curl/curl.h>

#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>

#include <string.h>
#include <linux/in.h>
#include <linux/in6.h>
#include <arpa/inet.h>

#include "video-decoder.h"
#include "audio-decoder.h"
#include "audio-output.h"
#include "log.h"
#include "chiaki-jni.h"

static int anyplay_hex_nibble(char c)
{
	if(c >= '0' && c <= '9') return c - '0';
	if(c >= 'a' && c <= 'f') return c - 'a' + 10;
	if(c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static bool anyplay_parse_hex(uint8_t *buf, size_t buf_size, const char *hex)
{
	if(strlen(hex) != buf_size * 2)
		return false;
	for(size_t i = 0; i < buf_size; i++)
	{
		int hi = anyplay_hex_nibble(hex[i * 2]), lo = anyplay_hex_nibble(hex[i * 2 + 1]);
		if(hi < 0 || lo < 0)
			return false;
		buf[i] = (uint8_t)((hi << 4) | lo);
	}
	return true;
}

static void anyplay_format_hex(char *hex, const uint8_t *buf, size_t buf_size)
{
	static const char digits[] = "0123456789abcdef";
	for(size_t i = 0; i < buf_size; i++)
	{
		hex[i * 2] = digits[buf[i] >> 4];
		hex[i * 2 + 1] = digits[buf[i] & 0xf];
	}
	hex[buf_size * 2] = 0;
}

// ── AnyPlay: кореневі сертифікати для HTTPS-запитів бібліотеки до PSN ──
// У застосунку Android немає сховища сертифікатів, яке бачить OpenSSL, тому програма кладе свій файл cacert.pem і має
// сказати про нього бібліотеці. Змінної SSL_CERT_FILE для цього замало: OpenSSL читає її через ossl_safe_getenv(),
// а той повертає NULL, коли OPENSSL_issetugid() != 0. На Android (API 18+) OPENSSL_issetugid() = getauxval(AT_SECURE),
// і в КОЖНОМУ процесі застосунку це 1: ядро ставить AT_SECURE, коли init запускає zygote (зміна домену SELinux),
// а застосунки є його копіями (fork). Тож OpenSSL мовчки ігнорував SSL_CERT_FILE, не знаходив жодного кореневого
// сертифіката, і кожен запит до Sony падав з «SSL peer certificate or SSH remote key was not OK» (curl 60) —
// клієнт бачив «Sony зараз не відповідає». Два незалежні виправлення (обидва вмикає android/app/CMakeLists.txt
// прапорцем лінкера --wrap, бо сама бібліотека lib/ не дає задати файл сертифікатів):
//  1) кожному з'єднанню curl, яке створює бібліотека, явно задаємо файл сертифікатів (CURLOPT_CAINFO);
//  2) OpenSSL не вважає процес застосунку «setuid» і читає SSL_CERT_FILE (потрібно там, де бібліотека сама
//     перевіряє ланцюжок через сховище OpenSSL за замовчуванням: lib/src/aia_openssl.c).
static pthread_mutex_t anyplay_ca_mutex = PTHREAD_MUTEX_INITIALIZER;
static char anyplay_ca_bundle[1024];

CURL *__real_curl_easy_init(void);

CURL *__wrap_curl_easy_init(void)
{
	CURL *curl = __real_curl_easy_init();
	if(!curl)
		return NULL;
	char path[sizeof(anyplay_ca_bundle)];
	pthread_mutex_lock(&anyplay_ca_mutex);
	memcpy(path, anyplay_ca_bundle, sizeof(path));
	pthread_mutex_unlock(&anyplay_ca_mutex);
	if(path[0])
		curl_easy_setopt(curl, CURLOPT_CAINFO, path); // curl копіює рядок собі
	return curl;
}

int __wrap_OPENSSL_issetugid(void)
{
	return 0;
}

/** Останні помилки з журналу → статус HTTP і код помилки curl (0 — не було) */
#define ANYPLAY_DIAG_LINE 260

static void anyplay_diag(long *http_code, int *curl_code, char *last_line, size_t last_line_size)
{
	char buf[8192];
	*http_code = 0;
	*curl_code = 0;
	if(last_line_size)
		last_line[0] = 0;
	size_t len = anyplay_log_last_errors(buf, sizeof(buf));
	// найновіші рядки внизу: ідемо з кінця й беремо перший статус HTTP та першу помилку curl
	char *end = buf + len;
	while(end > buf)
	{
		char *line_end = end - 1; // на '\n'
		char *line = line_end;
		while(line > buf && line[-1] != '\n')
			line--;
		*line_end = 0;
		if(last_line_size && !last_line[0])
			snprintf(last_line, last_line_size, "%s", line);
		const char *h = strstr(line, "HTTP code ");
		if(h && !*http_code && !*curl_code)
			*http_code = strtol(h + 10, NULL, 10);
		const char *c = strstr(line, "CURL error ");
		if(c && !*curl_code && !*http_code)
		{
			c += 11;
			size_t best = 0;
			for(int code = 1; code < CURL_LAST; code++)
			{
				const char *text = curl_easy_strerror((CURLcode)code);
				size_t text_len = strlen(text);
				if(text_len > best && strncmp(c, text, text_len) == 0)
				{
					best = text_len;
					*curl_code = code;
				}
			}
			if(!*curl_code)
				*curl_code = -1;
		}
		end = line;
	}
}

static char *strdup_jni(const char *str)
{
	if(!str)
		return NULL;
	char *r = strdup(str);
	if(!r)
		return NULL;
	for(char *c=r; *c; c++)
	{
		if(*c & (1 << 7))
			*c = '?';
	}
	return r;
}

jobject jnistr_from_ascii(JNIEnv *env, const char *str)
{
	if(!str)
		return NULL;
	char *s = strdup_jni(str);
	if(!s)
		return NULL;
	jobject r = E->NewStringUTF(env, s);
	free(s);
	return r;
}

static jbyteArray jnibytearray_create(JNIEnv *env, const uint8_t *buf, size_t buf_size)
{
	jbyteArray r = E->NewByteArray(env, buf_size);
	E->SetByteArrayRegion(env, r, 0, buf_size, (const jbyte *)buf);
	return r;
}

static jobject get_kotlin_global_object(JNIEnv *env, const char *id)
{
	size_t idlen = strlen(id);
	char *sig = malloc(idlen + 3);
	if(!sig)
		return NULL;
	sig[0] = 'L';
	memcpy(sig + 1, id, idlen);
	sig[1 + idlen] = ';';
	sig[1 + idlen + 1] = '\0';
	jclass cls = E->FindClass(env, id);
	jfieldID field_id = E->GetStaticFieldID(env, cls, "INSTANCE", sig);
	jobject r = E->GetStaticObjectField(env, cls, field_id);
	free(sig);
	return r;
}

static ChiakiLog global_log;
JavaVM *global_vm;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved)
{
	global_vm = vm;

	android_chiaki_file_log_init(&global_log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, NULL);
	CHIAKI_LOGI(&global_log, "Loading Chiaki Library");
	ChiakiErrorCode err = chiaki_lib_init();
	CHIAKI_LOGI(&global_log, "Chiaki Library Init Result: %s\n", chiaki_error_string(err));
	return JNI_VERSION;
}

JNIEnv *attach_thread_jni()
{
	JNIEnv *env;
	int r = (*global_vm)->GetEnv(global_vm, (void **)&env, JNI_VERSION);
	if(r == JNI_OK)
		return env;

	if((*global_vm)->AttachCurrentThread(global_vm, &env, NULL) == 0)
		return env;

	CHIAKI_LOGE(&global_log, "Failed to get JNIEnv from JavaVM or attach");
	return NULL;
}

JNIEXPORT jstring JNICALL JNI_FCN(errorCodeToString)(JNIEnv *env, jobject obj, jint value)
{
	return E->NewStringUTF(env, chiaki_error_string((ChiakiErrorCode)value));
}

JNIEXPORT jstring JNICALL JNI_FCN(quitReasonToString)(JNIEnv *env, jobject obj, jint value)
{
	return E->NewStringUTF(env, chiaki_quit_reason_string((ChiakiQuitReason)value));
}

JNIEXPORT jboolean JNICALL JNI_FCN(quitReasonIsError)(JNIEnv *env, jobject obj, jint value)
{
	return chiaki_quit_reason_is_error(value);
}

JNIEXPORT jobject JNICALL JNI_FCN(videoProfilePreset)(JNIEnv *env, jobject obj, jint resolution_preset, jint fps_preset, jobject codec)
{
	ChiakiConnectVideoProfile profile = { 0 };
	chiaki_connect_video_profile_preset(&profile, (ChiakiVideoResolutionPreset)resolution_preset, (ChiakiVideoFPSPreset)fps_preset);
	jclass profile_class = E->FindClass(env, BASE_PACKAGE"/ConnectVideoProfile");
	jmethodID profile_ctor = E->GetMethodID(env, profile_class, "<init>", "(IIIIL"BASE_PACKAGE"/Codec;)V");
	return E->NewObject(env, profile_class, profile_ctor, profile.width, profile.height, profile.max_fps, profile.bitrate, codec);
}

typedef struct android_chiaki_session_t
{
	ChiakiSession session;
	ChiakiLog *log;
	jobject java_session;
	jclass java_session_class;
	jmethodID java_session_event_connected_meth;
	jmethodID java_session_event_login_pin_request_meth;
	jmethodID java_session_event_quit_meth;
	jmethodID java_session_event_rumble_meth;
	jfieldID java_controller_state_buttons;
	jfieldID java_controller_state_l2_state;
	jfieldID java_controller_state_r2_state;
	jfieldID java_controller_state_left_x;
	jfieldID java_controller_state_left_y;
	jfieldID java_controller_state_right_x;
	jfieldID java_controller_state_right_y;
	jfieldID java_controller_state_touches;
	jfieldID java_controller_state_gyro_x;
	jfieldID java_controller_state_gyro_y;
	jfieldID java_controller_state_gyro_z;
	jfieldID java_controller_state_accel_x;
	jfieldID java_controller_state_accel_y;
	jfieldID java_controller_state_accel_z;
	jfieldID java_controller_state_orient_x;
	jfieldID java_controller_state_orient_y;
	jfieldID java_controller_state_orient_z;
	jfieldID java_controller_state_orient_w;
	jfieldID java_controller_touch_x;
	jfieldID java_controller_touch_y;
	jfieldID java_controller_touch_id;

	AndroidChiakiVideoDecoder video_decoder;
	AndroidChiakiAudioDecoder audio_decoder;
	void *audio_output;
	bool started; // потік сесії запущено (інакше join нема чого чекати)
	ChiakiHolepunchSession holepunch; // AnyPlay: з'єднання через PSN (належить ChiakiSession)
	int psn_step; // AnyPlay: на якому кроці з'єднання через PSN ми зараз (або де зупинились), див. sessionPsnConnect
} AndroidChiakiSession;

static void android_chiaki_event_cb(ChiakiEvent *event, void *user)
{
	AndroidChiakiSession *session = user;

	JNIEnv *env = attach_thread_jni();
	if(!env)
		return;

	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			E->CallVoidMethod(env, session->java_session,
							  session->java_session_event_connected_meth);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			E->CallVoidMethod(env, session->java_session,
							  session->java_session_event_login_pin_request_meth,
							  (jboolean)event->login_pin_request.pin_incorrect);
			break;
		case CHIAKI_EVENT_QUIT:
		{
			char *reason_str = strdup_jni(event->quit.reason_str);
			jstring reason_str_java = reason_str ? E->NewStringUTF(env, reason_str) : NULL;
			E->CallVoidMethod(env, session->java_session,
							  session->java_session_event_quit_meth,
							  (jint)event->quit.reason,
							  reason_str_java);
			if(reason_str_java)
				E->DeleteLocalRef(env, reason_str_java);
			free(reason_str);
			break;
		}
		case CHIAKI_EVENT_RUMBLE:
			E->CallVoidMethod(env, session->java_session,
							  session->java_session_event_rumble_meth,
							  (jint)event->rumble.left,
							  (jint)event->rumble.right);
			break;
		default:
			break;
	}

	(*global_vm)->DetachCurrentThread(global_vm);
}

JNIEXPORT void JNICALL JNI_FCN(sessionCreate)(JNIEnv *env, jobject obj, jobject result, jobject connect_info_obj, jstring log_file_str, jboolean log_verbose, jobject java_session)
{
	AndroidChiakiSession *session = NULL;
	ChiakiLog *log = malloc(sizeof(ChiakiLog));
	const char *log_file = log_file_str ? E->GetStringUTFChars(env, log_file_str, NULL) : NULL;
	android_chiaki_file_log_init(log, log_verbose ? CHIAKI_LOG_ALL : (CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE), log_file);
	if(log_file)
		E->ReleaseStringUTFChars(env, log_file_str, log_file);

	ChiakiErrorCode err = CHIAKI_ERR_SUCCESS;
	char *host_str = NULL;

	jclass result_class = E->GetObjectClass(env, result);

	jclass connect_info_class = E->GetObjectClass(env, connect_info_obj);
	jboolean ps5 = E->GetBooleanField(env, connect_info_obj, E->GetFieldID(env, connect_info_class, "ps5", "Z"));
	jstring host_string = E->GetObjectField(env, connect_info_obj, E->GetFieldID(env, connect_info_class, "host", "Ljava/lang/String;"));
	jbyteArray regist_key_array = E->GetObjectField(env, connect_info_obj, E->GetFieldID(env, connect_info_class, "registKey", "[B"));
	jbyteArray morning_array = E->GetObjectField(env, connect_info_obj, E->GetFieldID(env, connect_info_class, "morning", "[B"));
	jobject connect_video_profile_obj = E->GetObjectField(env, connect_info_obj, E->GetFieldID(env, connect_info_class, "videoProfile", "L"BASE_PACKAGE"/ConnectVideoProfile;"));
	jclass connect_video_profile_class = E->GetObjectClass(env, connect_video_profile_obj);

	jstring psn_token_string = E->GetObjectField(env, connect_info_obj, E->GetFieldID(env, connect_info_class, "psnToken", "Ljava/lang/String;"));
	jbyteArray psn_account_id_array = E->GetObjectField(env, connect_info_obj, E->GetFieldID(env, connect_info_class, "psnAccountId", "[B"));
	ChiakiHolepunchSession holepunch = NULL;

	ChiakiConnectInfo connect_info = { 0 };
	connect_info.ps5 = ps5;

	const char *str_borrow = E->GetStringUTFChars(env, host_string, NULL);
	connect_info.host = host_str = strdup(str_borrow);
	E->ReleaseStringUTFChars(env, host_string, str_borrow);
	if(!connect_info.host)
	{
		err = CHIAKI_ERR_MEMORY;
		goto beach;
	}

	if(E->GetArrayLength(env, regist_key_array) != sizeof(connect_info.regist_key))
	{
		CHIAKI_LOGE(log, "Regist Key passed from Java has invalid length");
		err = CHIAKI_ERR_INVALID_DATA;
		goto beach;
	}
	jbyte *bytes = E->GetByteArrayElements(env, regist_key_array, NULL);
	memcpy(connect_info.regist_key, bytes, sizeof(connect_info.regist_key));
	E->ReleaseByteArrayElements(env, regist_key_array, bytes, JNI_ABORT);

	if(E->GetArrayLength(env, morning_array) != sizeof(connect_info.morning))
	{
		CHIAKI_LOGE(log, "Morning passed from Java has invalid length");
		err = CHIAKI_ERR_INVALID_DATA;
		goto beach;
	}
	bytes = E->GetByteArrayElements(env, morning_array, NULL);
	memcpy(connect_info.morning, bytes, sizeof(connect_info.morning));
	E->ReleaseByteArrayElements(env, morning_array, bytes, JNI_ABORT);

	connect_info.video_profile.width = (unsigned int)E->GetIntField(env, connect_video_profile_obj, E->GetFieldID(env, connect_video_profile_class, "width", "I"));
	connect_info.video_profile.height = (unsigned int)E->GetIntField(env, connect_video_profile_obj, E->GetFieldID(env, connect_video_profile_class, "height", "I"));
	connect_info.video_profile.max_fps = (unsigned int)E->GetIntField(env, connect_video_profile_obj, E->GetFieldID(env, connect_video_profile_class, "maxFPS", "I"));
	connect_info.video_profile.bitrate = (unsigned int)E->GetIntField(env, connect_video_profile_obj, E->GetFieldID(env, connect_video_profile_class, "bitrate", "I"));

	jobject codec_obj = E->GetObjectField(env, connect_video_profile_obj, E->GetFieldID(env, connect_video_profile_class, "codec", "L"BASE_PACKAGE"/Codec;"));
	jclass codec_class = E->GetObjectClass(env, codec_obj);
	jint target_value = E->GetIntField(env, codec_obj, E->GetFieldID(env, codec_class, "value", "I"));
	connect_info.video_profile.codec = (ChiakiCodec)target_value;

	connect_info.video_profile_auto_downgrade = true;
	connect_info.enable_idr_on_fec_failure = true;   // AnyPlay: після збою FEC просимо ключовий кадр і тримаємо останню добру картинку

	// AnyPlay: гра через інтернет — з'єднання з PS5 пробиває PSN, прив'язка відбувається в тій самій сесії
	if(psn_token_string)
	{
		if(!psn_account_id_array || E->GetArrayLength(env, psn_account_id_array) != sizeof(connect_info.psn_account_id))
		{
			CHIAKI_LOGE(log, "PSN account id passed from Java has invalid length");
			err = CHIAKI_ERR_INVALID_DATA;
			goto beach;
		}
		E->GetByteArrayRegion(env, psn_account_id_array, 0, sizeof(connect_info.psn_account_id), (jbyte *)connect_info.psn_account_id);
		const char *token = E->GetStringUTFChars(env, psn_token_string, NULL);
		holepunch = chiaki_holepunch_session_init(token, log);
		E->ReleaseStringUTFChars(env, psn_token_string, token);
		if(!holepunch)
		{
			CHIAKI_LOGE(log, "Failed to init PSN holepunch session");
			err = CHIAKI_ERR_MEMORY;
			goto beach;
		}
		connect_info.holepunch_session = holepunch;
	}

	session = CHIAKI_NEW(AndroidChiakiSession);
	if(!session)
	{
		err = CHIAKI_ERR_MEMORY;
		if(holepunch)
			chiaki_holepunch_session_fini(holepunch);
		goto beach;
	}
	memset(session, 0, sizeof(AndroidChiakiSession));
	session->log = log;
	session->holepunch = holepunch;
	err = android_chiaki_video_decoder_init(&session->video_decoder, log, connect_info.video_profile.width, connect_info.video_profile.height,
			connect_info.ps5 ? connect_info.video_profile.codec : CHIAKI_CODEC_H264);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(holepunch)
			chiaki_holepunch_session_fini(holepunch);
		free(session);
		session = NULL;
		goto beach;
	}

	err = android_chiaki_audio_decoder_init(&session->audio_decoder, log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(holepunch)
			chiaki_holepunch_session_fini(holepunch);
		android_chiaki_video_decoder_fini(&session->video_decoder);
		free(session);
		session = NULL;
		goto beach;
	}

	session->audio_output = android_chiaki_audio_output_new(log);

	android_chiaki_audio_decoder_set_cb(&session->audio_decoder, android_chiaki_audio_output_settings, android_chiaki_audio_output_frame, session->audio_output);

	err = chiaki_session_init(&session->session, &connect_info, log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(log, "JNI ChiakiSession failed to init");
		android_chiaki_video_decoder_fini(&session->video_decoder);
		android_chiaki_audio_decoder_fini(&session->audio_decoder);
		android_chiaki_audio_output_free(session->audio_output);
		free(session);
		session = NULL;
		goto beach;
	}

	session->java_session = E->NewGlobalRef(env, java_session);
	session->java_session_class = E->NewGlobalRef(env, E->GetObjectClass(env, session->java_session));
	session->java_session_event_connected_meth = E->GetMethodID(env, session->java_session_class, "eventConnected", "()V");
	session->java_session_event_login_pin_request_meth = E->GetMethodID(env, session->java_session_class, "eventLoginPinRequest", "(Z)V");
	session->java_session_event_quit_meth = E->GetMethodID(env, session->java_session_class, "eventQuit", "(ILjava/lang/String;)V");
	session->java_session_event_rumble_meth = E->GetMethodID(env, session->java_session_class, "eventRumble", "(II)V");

	jclass controller_state_class = E->FindClass(env, BASE_PACKAGE"/ControllerState");
	session->java_controller_state_buttons = E->GetFieldID(env, controller_state_class, "buttons", "I");
	session->java_controller_state_l2_state = E->GetFieldID(env, controller_state_class, "l2State", "B");
	session->java_controller_state_r2_state = E->GetFieldID(env, controller_state_class, "r2State", "B");
	session->java_controller_state_left_x = E->GetFieldID(env, controller_state_class, "leftX", "S");
	session->java_controller_state_left_y = E->GetFieldID(env, controller_state_class, "leftY", "S");
	session->java_controller_state_right_x = E->GetFieldID(env, controller_state_class, "rightX", "S");
	session->java_controller_state_right_y = E->GetFieldID(env, controller_state_class, "rightY", "S");
	session->java_controller_state_touches = E->GetFieldID(env, controller_state_class, "touches", "[L"BASE_PACKAGE"/ControllerTouch;");
	session->java_controller_state_gyro_x = E->GetFieldID(env, controller_state_class, "gyroX", "F");
	session->java_controller_state_gyro_y = E->GetFieldID(env, controller_state_class, "gyroY", "F");
	session->java_controller_state_gyro_z = E->GetFieldID(env, controller_state_class, "gyroZ", "F");
	session->java_controller_state_accel_x = E->GetFieldID(env, controller_state_class, "accelX", "F");
	session->java_controller_state_accel_y = E->GetFieldID(env, controller_state_class, "accelY", "F");
	session->java_controller_state_accel_z = E->GetFieldID(env, controller_state_class, "accelZ", "F");
	session->java_controller_state_orient_x = E->GetFieldID(env, controller_state_class, "orientX", "F");
	session->java_controller_state_orient_y = E->GetFieldID(env, controller_state_class, "orientY", "F");
	session->java_controller_state_orient_z = E->GetFieldID(env, controller_state_class, "orientZ", "F");
	session->java_controller_state_orient_w = E->GetFieldID(env, controller_state_class, "orientW", "F");

	jclass controller_touch_class = E->FindClass(env, BASE_PACKAGE"/ControllerTouch");
	session->java_controller_touch_x = E->GetFieldID(env, controller_touch_class, "x", "S");
	session->java_controller_touch_y = E->GetFieldID(env, controller_touch_class, "y", "S");
	session->java_controller_touch_id = E->GetFieldID(env, controller_touch_class, "id", "B");

	chiaki_session_set_event_cb(&session->session, android_chiaki_event_cb, session);
	chiaki_session_set_video_sample_cb(&session->session, android_chiaki_video_decoder_video_sample, &session->video_decoder);

	ChiakiAudioSink audio_sink;
	android_chiaki_audio_decoder_get_sink(&session->audio_decoder, &audio_sink);
	chiaki_session_set_audio_sink(&session->session, &audio_sink);

beach:
	if(!session && log)
	{
		android_chiaki_file_log_fini(log);
		free(log);
	}

	free(host_str);
	E->SetIntField(env, result, E->GetFieldID(env, result_class, "errorCode", "I"), (jint)err);
	E->SetLongField(env, result, E->GetFieldID(env, result_class, "ptr", "J"), (jlong)session);
}

JNIEXPORT void JNICALL JNI_FCN(sessionFree)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	if(!session)
		return;
	CHIAKI_LOGI(session->log, "Shutting down JNI Session");
	chiaki_session_fini(&session->session);
	android_chiaki_video_decoder_fini(&session->video_decoder);
	android_chiaki_audio_decoder_fini(&session->audio_decoder);
	android_chiaki_audio_output_free(session->audio_output);
	E->DeleteGlobalRef(env, session->java_session);
	E->DeleteGlobalRef(env, session->java_session_class);
	CHIAKI_LOGI(session->log, "JNI Session has quit");
	android_chiaki_file_log_fini(session->log);
	free(session->log);
	free(session);
}

// AnyPlay: пробити з'єднання з PS5 через PSN (довга операція — викликати не з головного потоку, до sessionStart)
JNIEXPORT jint JNICALL JNI_FCN(sessionPsnConnect)(JNIEnv *env, jobject obj, jlong ptr, jstring duid_string)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	if(!session || !session->holepunch || !duid_string)
		return CHIAKI_ERR_INVALID_DATA;
	ChiakiLog *log = session->log;
	uint8_t duid[32];
	const char *duid_str = E->GetStringUTFChars(env, duid_string, NULL);
	bool duid_ok = anyplay_parse_hex(duid, sizeof(duid), duid_str);
	E->ReleaseStringUTFChars(env, duid_string, duid_str);
	ChiakiErrorCode err;
	if(!duid_ok)
	{
		CHIAKI_LOGE(log, "PSN: invalid console id");
		return CHIAKI_ERR_INVALID_DATA;
	}
	// кроки (psn_step): 1 — роутер (UPnP), 2 — сесія на серверах Sony, 3 — наша адреса для приставки (STUN),
	// 4 — приставка приєднується до сесії, 5 — пряме з'єднання з приставкою
	anyplay_log_clear_errors();
	session->psn_step = 1;
	err = chiaki_holepunch_upnp_discover(session->holepunch);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(log, "PSN: upnp discover failed");
		return err;
	}
	session->psn_step = 2;
	err = chiaki_holepunch_session_create(session->holepunch);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(log, "PSN: failed to create session");
		return err;
	}
	session->psn_step = 3;
	err = holepunch_session_create_offer(session->holepunch);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(log, "PSN: failed to create offer for ctrl connection");
		return err;
	}
	session->psn_step = 4;
	err = chiaki_holepunch_session_start(session->holepunch, duid, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(log, "PSN: failed to start session");
		return err;
	}
	session->psn_step = 5;
	err = chiaki_holepunch_session_punch_hole(session->holepunch, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(log, "PSN: failed to punch hole for control connection");
		return err;
	}
	session->psn_step = 6;
	CHIAKI_LOGI(log, "PSN: punched hole for control connection");
	return CHIAKI_ERR_SUCCESS;
}

// AnyPlay: крок з'єднання через PSN, на якому сесія зараз або де вона зупинилась (0 — ще не починали, 6 — з'єднано)
JNIEXPORT jint JNICALL JNI_FCN(sessionPsnStep)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	return session ? session->psn_step : 0;
}

// AnyPlay: «статус HTTP<TAB>код curl<TAB>останній рядок помилки» з журналу бібліотеки (після невдалої дії)
JNIEXPORT jstring JNICALL JNI_FCN(psnDiag)(JNIEnv *env, jobject obj)
{
	long http_code;
	int curl_code;
	char line[ANYPLAY_DIAG_LINE];
	anyplay_diag(&http_code, &curl_code, line, sizeof(line));
	for(char *c = line; *c; c++)
		if(*c == '\t' || *c == '\n')
			*c = ' ';
	char out[ANYPLAY_DIAG_LINE + 64];
	snprintf(out, sizeof(out), "%ld\t%d\t%s", http_code, curl_code, line);
	return jnistr_from_ascii(env, out);
}

// AnyPlay: лічильники відео для телеметрії: кадрів прийшло, показано, втрачено, байтів (наростаючі)
JNIEXPORT jlongArray JNICALL JNI_FCN(sessionVideoStats)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	uint64_t stats[4] = { 0 };
	if(session)
		android_chiaki_video_decoder_stats(&session->video_decoder, stats);
	jlong values[4];
	for(int i = 0; i < 4; i++)
		values[i] = (jlong)stats[i];
	jlongArray r = E->NewLongArray(env, 4);
	if(r)
		E->SetLongArrayRegion(env, r, 0, 4, values);
	return r;
}

JNIEXPORT void JNICALL JNI_FCN(sessionPsnCancel)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	if(session && session->holepunch)
		chiaki_holepunch_main_thread_cancel(session->holepunch, false);
}

// AnyPlay: приставки акаунта PSN, до яких можна підключитись через інтернет.
// Перший рядок — «ok» або «err<TAB>код бібліотеки<TAB>статус HTTP<TAB>код curl»; далі рядки «duid<TAB>назва<TAB>0|1».
JNIEXPORT jstring JNICALL JNI_FCN(psnListDevices)(JNIEnv *env, jobject obj, jstring token_string)
{
	char status[96];
	if(!token_string)
		return E->NewStringUTF(env, "err\t11\t0\t0\n"); // CHIAKI_ERR_INVALID_DATA
	const char *token = E->GetStringUTFChars(env, token_string, NULL);
	ChiakiHolepunchDeviceInfo *devices = NULL;
	size_t count = 0;
	anyplay_log_clear_errors();
	ChiakiErrorCode err = chiaki_holepunch_list_devices(token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices, &count, &global_log);
	E->ReleaseStringUTFChars(env, token_string, token);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		long http_code;
		int curl_code;
		anyplay_diag(&http_code, &curl_code, NULL, 0);
		snprintf(status, sizeof(status), "err\t%d\t%ld\t%d\n", (int)err, http_code, curl_code);
		return E->NewStringUTF(env, status);
	}
	size_t buf_size = count * 128 + 8;
	char *buf = calloc(1, buf_size);
	if(!buf)
	{
		if(devices)
			chiaki_holepunch_free_device_list(&devices);
		snprintf(status, sizeof(status), "err\t%d\t0\t0\n", (int)CHIAKI_ERR_MEMORY);
		return E->NewStringUTF(env, status);
	}
	size_t off = (size_t)snprintf(buf, buf_size, "ok\n");
	for(size_t i = 0; i < count; i++)
	{
		char hex[sizeof(devices[i].device_uid) * 2 + 1];
		anyplay_format_hex(hex, devices[i].device_uid, sizeof(devices[i].device_uid));
		char name[sizeof(devices[i].device_name) + 1];
		memcpy(name, devices[i].device_name, sizeof(devices[i].device_name));
		name[sizeof(devices[i].device_name)] = 0;
		for(char *c = name; *c; c++)
			if(*c == '\t' || *c == '\n')
				*c = ' ';
		off += snprintf(buf + off, buf_size - off, "%s\t%s\t%d\n", hex, name, devices[i].remoteplay_enabled ? 1 : 0);
		if(off >= buf_size)
			break;
	}
	if(devices)
		chiaki_holepunch_free_device_list(&devices);
	char *safe = strdup_jni(buf);
	free(buf);
	jstring r = E->NewStringUTF(env, safe ? safe : "err\t4\t0\t0\n"); // CHIAKI_ERR_MEMORY
	free(safe);
	return r;
}

// AnyPlay: той самий файл для відновлення ланцюжка сертифікатів (сервер сповіщень Sony, крок PSN-2): lib/src/aia.c
extern void chiaki_aia_set_ca_file(const char *path);

// AnyPlay: файл кореневих сертифікатів для всіх HTTPS-запитів бібліотеки (див. пояснення біля __wrap_curl_easy_init)
JNIEXPORT void JNICALL JNI_FCN(setCaBundle)(JNIEnv *env, jobject obj, jstring path_string)
{
	const char *path = E->GetStringUTFChars(env, path_string, NULL);
	if(strlen(path) < sizeof(anyplay_ca_bundle))
	{
		pthread_mutex_lock(&anyplay_ca_mutex);
		strcpy(anyplay_ca_bundle, path);
		pthread_mutex_unlock(&anyplay_ca_mutex);
	}
	chiaki_aia_set_ca_file(path);
	setenv("SSL_CERT_FILE", path, 1);
	E->ReleaseStringUTFChars(env, path_string, path);
}

// AnyPlay: змінна середовища (шлях до кореневих сертифікатів для HTTPS-запитів до PSN)
JNIEXPORT void JNICALL JNI_FCN(setEnv)(JNIEnv *env, jobject obj, jstring name_string, jstring value_string)
{
	const char *name = E->GetStringUTFChars(env, name_string, NULL);
	const char *value = E->GetStringUTFChars(env, value_string, NULL);
	setenv(name, value, 1);
	E->ReleaseStringUTFChars(env, name_string, name);
	E->ReleaseStringUTFChars(env, value_string, value);
}

JNIEXPORT jint JNICALL JNI_FCN(sessionStart)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	CHIAKI_LOGI(session->log, "Start JNI Session");
	ChiakiErrorCode err = chiaki_session_start(&session->session);
	if(err == CHIAKI_ERR_SUCCESS)
		session->started = true;
	return err;
}

// AnyPlay: частка втрачених пакетів (0..1) за останній проміжок — для автоякості
JNIEXPORT jdouble JNICALL JNI_FCN(sessionPacketLoss)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	if(!session || !session->started)
		return 0.0;
	return session->session.stream_connection.congestion_control.packet_loss;
}

JNIEXPORT jint JNICALL JNI_FCN(sessionStop)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	CHIAKI_LOGI(session->log, "Stop JNI Session");
	if(!session->started)
		return CHIAKI_ERR_SUCCESS;
	return chiaki_session_stop(&session->session);
}

JNIEXPORT jint JNICALL JNI_FCN(sessionJoin)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	CHIAKI_LOGI(session->log, "Join JNI Session");
	if(!session->started)
		return CHIAKI_ERR_SUCCESS;
	return chiaki_session_join(&session->session);
}

JNIEXPORT void JNICALL JNI_FCN(sessionSetSurface)(JNIEnv *env, jobject obj, jlong ptr, jobject surface)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	android_chiaki_video_decoder_set_surface(&session->video_decoder, env, surface);
}

JNIEXPORT void JNICALL JNI_FCN(sessionSetControllerState)(JNIEnv *env, jobject obj, jlong ptr, jobject controller_state_java)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	ChiakiControllerState controller_state;
	chiaki_controller_state_set_idle(&controller_state);
	controller_state.buttons = (uint32_t)E->GetIntField(env, controller_state_java, session->java_controller_state_buttons);
	controller_state.l2_state = (uint8_t)E->GetByteField(env, controller_state_java, session->java_controller_state_l2_state);
	controller_state.r2_state = (uint8_t)E->GetByteField(env, controller_state_java, session->java_controller_state_r2_state);
	controller_state.left_x = (int16_t)E->GetShortField(env, controller_state_java, session->java_controller_state_left_x);
	controller_state.left_y = (int16_t)E->GetShortField(env, controller_state_java, session->java_controller_state_left_y);
	controller_state.right_x = (int16_t)E->GetShortField(env, controller_state_java, session->java_controller_state_right_x);
	controller_state.right_y = (int16_t)E->GetShortField(env, controller_state_java, session->java_controller_state_right_y);
	jobjectArray touch_array = E->GetObjectField(env, controller_state_java, session->java_controller_state_touches);
	size_t touch_array_len = (size_t)E->GetArrayLength(env, touch_array);
	for(size_t i = 0; i < CHIAKI_CONTROLLER_TOUCHES_MAX; i++)
	{
		if(i < touch_array_len)
		{
			jobject touch = E->GetObjectArrayElement(env, touch_array, i);
			controller_state.touches[i].x = (uint16_t)E->GetShortField(env, touch, session->java_controller_touch_x);
			controller_state.touches[i].y = (uint16_t)E->GetShortField(env, touch, session->java_controller_touch_y);
			controller_state.touches[i].id = (int8_t)E->GetByteField(env, touch, session->java_controller_touch_id);
		}
		else
		{
			controller_state.touches[i].x = 0;
			controller_state.touches[i].y = 0;
			controller_state.touches[i].id = -1;
		}
	}
	controller_state.gyro_x = E->GetFloatField(env, controller_state_java, session->java_controller_state_gyro_x);
	controller_state.gyro_y = E->GetFloatField(env, controller_state_java, session->java_controller_state_gyro_y);
	controller_state.gyro_z = E->GetFloatField(env, controller_state_java, session->java_controller_state_gyro_z);
	controller_state.accel_x = E->GetFloatField(env, controller_state_java, session->java_controller_state_accel_x);
	controller_state.accel_y = E->GetFloatField(env, controller_state_java, session->java_controller_state_accel_y);
	controller_state.accel_z = E->GetFloatField(env, controller_state_java, session->java_controller_state_accel_z);
	controller_state.orient_x = E->GetFloatField(env, controller_state_java, session->java_controller_state_orient_x);
	controller_state.orient_y = E->GetFloatField(env, controller_state_java, session->java_controller_state_orient_y);
	controller_state.orient_z = E->GetFloatField(env, controller_state_java, session->java_controller_state_orient_z);
	controller_state.orient_w = E->GetFloatField(env, controller_state_java, session->java_controller_state_orient_w);
	chiaki_session_set_controller_state(&session->session, &controller_state);
}

JNIEXPORT void JNICALL JNI_FCN(sessionSetLoginPin)(JNIEnv *env, jobject obj, jlong ptr, jstring pin_java)
{
	AndroidChiakiSession *session = (AndroidChiakiSession *)ptr;
	const char *pin = E->GetStringUTFChars(env, pin_java, NULL);
	chiaki_session_set_login_pin(&session->session, (const uint8_t *)pin, strlen(pin));
	E->ReleaseStringUTFChars(env, pin_java, pin);
}

typedef struct android_discovery_service_t
{
	ChiakiDiscoveryService service;
	jobject java_service;
	jclass java_service_class;
	jmethodID java_service_hosts_updated_meth;

	jclass host_class;
	jmethodID host_ctor;
	jobject host_state_unknown;
	jobject host_state_ready;
	jobject host_state_standby;
} AndroidDiscoveryService;

static void android_discovery_service_cb(ChiakiDiscoveryHost *hosts, size_t hosts_count, void *user)
{
	AndroidDiscoveryService *service = user;

	CHIAKI_LOGI(&global_log, "JNI Discovery Callback got %llu hosts", (unsigned long long)hosts_count);

	JNIEnv *env = attach_thread_jni();
	if(!env)
		return;

	jobjectArray r = E->NewObjectArray(env, hosts_count, service->host_class, NULL);

	for(size_t i=0; i<hosts_count; i++)
	{
		jobject state;
		ChiakiDiscoveryHost *host = hosts + i;
		switch(host->state)
		{
			case CHIAKI_DISCOVERY_HOST_STATE_STANDBY:
				state = service->host_state_standby;
				break;
			case CHIAKI_DISCOVERY_HOST_STATE_READY:
				state = service->host_state_ready;
				break;
			default:
				state = service->host_state_unknown;
				break;
		}

		jobject o = E->NewObject(env, service->host_class, service->host_ctor,
				state,
				host->host_request_port,
				jnistr_from_ascii(env, host->host_addr),
				jnistr_from_ascii(env, host->system_version),
				jnistr_from_ascii(env, host->device_discovery_protocol_version),
				jnistr_from_ascii(env, host->host_name),
				jnistr_from_ascii(env, host->host_type),
				jnistr_from_ascii(env, host->host_id),
				jnistr_from_ascii(env, host->running_app_titleid),
				jnistr_from_ascii(env, host->running_app_name));

		E->SetObjectArrayElement(env, r, i, o);
	}

	E->CallVoidMethod(env, service->java_service, service->java_service_hosts_updated_meth, r);

	(*global_vm)->DetachCurrentThread(global_vm);
}

static ChiakiErrorCode sockaddr_from_java(JNIEnv *env, jobject /*InetSocketAddress*/ sockaddr_obj, struct sockaddr **addr, size_t *addr_size)
{
	jclass sockaddr_class = E->GetObjectClass(env, sockaddr_obj);
	uint16_t port = (uint16_t)E->CallIntMethod(env, sockaddr_obj, E->GetMethodID(env, sockaddr_class, "getPort", "()I"));
	jobject addr_obj = E->CallObjectMethod(env, sockaddr_obj, E->GetMethodID(env, sockaddr_class, "getAddress", "()Ljava/net/InetAddress;"));
	jclass addr_class = E->GetObjectClass(env, addr_obj);
	jbyteArray addr_byte_array = E->CallObjectMethod(env, addr_obj, E->GetMethodID(env, addr_class, "getAddress", "()[B"));
	jsize addr_byte_array_len = E->GetArrayLength(env, addr_byte_array);

	if(addr_byte_array_len == 4)
	{
		struct sockaddr_in *inaddr = CHIAKI_NEW(struct sockaddr_in);
		if(!inaddr)
			return CHIAKI_ERR_MEMORY;
		memset(inaddr, 0, sizeof(*inaddr));
		inaddr->sin_family = AF_INET;
		jbyte *bytes = E->GetByteArrayElements(env, addr_byte_array, NULL);
		memcpy(&inaddr->sin_addr.s_addr, bytes, sizeof(inaddr->sin_addr.s_addr));
		E->ReleaseByteArrayElements(env, addr_byte_array, bytes, JNI_ABORT);
		inaddr->sin_port = htons(port);

		*addr = (struct sockaddr *)inaddr;
		*addr_size = sizeof(*inaddr);
	}
	else if(addr_byte_array_len == 0x10)
	{
		struct sockaddr_in6 *inaddr6 = CHIAKI_NEW(struct sockaddr_in6);
		if(!inaddr6)
			return CHIAKI_ERR_MEMORY;
		memset(inaddr6, 0, sizeof(*inaddr6));
		inaddr6->sin6_family = AF_INET6;
		jbyte *bytes = E->GetByteArrayElements(env, addr_byte_array, NULL);
		memcpy(&inaddr6->sin6_addr.in6_u, bytes, sizeof(inaddr6->sin6_addr.in6_u));
		E->ReleaseByteArrayElements(env, addr_byte_array, bytes, JNI_ABORT);
		inaddr6->sin6_port = htons(port);

		*addr = (struct sockaddr *)inaddr6;
		*addr_size = sizeof(*inaddr6);
	}
	else
		return CHIAKI_ERR_INVALID_DATA;

	return CHIAKI_ERR_SUCCESS;
}

JNIEXPORT void JNICALL JNI_FCN(discoveryServiceCreate)(JNIEnv *env, jobject obj, jobject result, jobject options_obj, jobject java_service)
{
	jclass result_class = E->GetObjectClass(env, result);
	ChiakiErrorCode err = CHIAKI_ERR_SUCCESS;
	ChiakiDiscoveryServiceOptions options = { 0 };

	AndroidDiscoveryService *service = CHIAKI_NEW(AndroidDiscoveryService);
	if(!service)
	{
		err = CHIAKI_ERR_MEMORY;
		goto beach;
	}

	jclass options_class = E->GetObjectClass(env, options_obj);

	options.hosts_max = (size_t)E->GetLongField(env, options_obj, E->GetFieldID(env, options_class, "hostsMax", "J"));
	options.host_drop_pings = (uint64_t)E->GetLongField(env, options_obj, E->GetFieldID(env, options_class, "hostDropPings", "J"));
	options.ping_ms = (uint64_t)E->GetLongField(env, options_obj, E->GetFieldID(env, options_class, "pingMs", "J"));
	options.cb = android_discovery_service_cb;
	options.cb_user = service;

	struct sockaddr *send_addr_tmp = NULL;
	err = sockaddr_from_java(env, E->GetObjectField(env, options_obj, E->GetFieldID(env, options_class, "sendAddr", "Ljava/net/InetSocketAddress;")), &send_addr_tmp, &options.send_addr_size);
	options.send_addr = (struct sockaddr_storage *)send_addr_tmp;
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&global_log, "Failed to get sockaddr from InetSocketAddress");
		goto beach;
	}

	service->java_service = E->NewGlobalRef(env, java_service);
	service->java_service_class = E->GetObjectClass(env, service->java_service);
	service->java_service_hosts_updated_meth = E->GetMethodID(env, service->java_service_class, "hostsUpdated", "([L"BASE_PACKAGE"/DiscoveryHost;)V");

	service->host_class = E->NewGlobalRef(env, E->FindClass(env, BASE_PACKAGE"/DiscoveryHost"));
	service->host_ctor = E->GetMethodID(env, service->host_class, "<init>", "("
		"L"BASE_PACKAGE"/DiscoveryHost$State;"
		"S" // hostRequestPort: UShort
		"Ljava/lang/String;" // hostAddr: String?,
		"Ljava/lang/String;" // systemVersion: String?,
		"Ljava/lang/String;" // deviceDiscoveryProtocolVersion: String?,
		"Ljava/lang/String;" // hostName: String?,
		"Ljava/lang/String;" // hostType: String?,
		"Ljava/lang/String;" // hostId: String?,
		"Ljava/lang/String;" // runningAppTitleid: String?,
		"Ljava/lang/String;" // runningAppName: String?
		")V");

	jclass host_state_class = E->FindClass(env, BASE_PACKAGE"/DiscoveryHost$State");
	service->host_state_unknown = E->NewGlobalRef(env, E->GetStaticObjectField(env, host_state_class, E->GetStaticFieldID(env, host_state_class, "UNKNOWN", "L"BASE_PACKAGE"/DiscoveryHost$State;")));
	service->host_state_standby = E->NewGlobalRef(env, E->GetStaticObjectField(env, host_state_class, E->GetStaticFieldID(env, host_state_class, "STANDBY", "L"BASE_PACKAGE"/DiscoveryHost$State;")));
	service->host_state_ready = E->NewGlobalRef(env, E->GetStaticObjectField(env, host_state_class, E->GetStaticFieldID(env, host_state_class, "READY", "L"BASE_PACKAGE"/DiscoveryHost$State;")));


	err = chiaki_discovery_service_init(&service->service, &options, &global_log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&global_log, "Failed to create discovery service (JNI)");
		E->DeleteGlobalRef(env, service->java_service);
		E->DeleteGlobalRef(env, service->host_state_unknown);
		E->DeleteGlobalRef(env, service->host_state_standby);
		E->DeleteGlobalRef(env, service->host_state_ready);
		E->DeleteGlobalRef(env, service->host_class);
		free(service);
		goto beach;
	}

beach:
	free(options.send_addr);
	E->SetIntField(env, result, E->GetFieldID(env, result_class, "errorCode", "I"), (jint)err);
	E->SetLongField(env, result, E->GetFieldID(env, result_class, "ptr", "J"), (jlong)service);
}

JNIEXPORT void JNICALL JNI_FCN(discoveryServiceFree)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidDiscoveryService *service = (AndroidDiscoveryService *)ptr;
	if(!service)
		return;
	chiaki_discovery_service_fini(&service->service);
	E->DeleteGlobalRef(env, service->java_service);
	E->DeleteGlobalRef(env, service->host_state_unknown);
	E->DeleteGlobalRef(env, service->host_state_standby);
	E->DeleteGlobalRef(env, service->host_state_ready);
	E->DeleteGlobalRef(env, service->host_class);
	free(service);
}

JNIEXPORT jint JNICALL JNI_FCN(discoveryServiceWakeup)(JNIEnv *env, jobject obj, jlong ptr, jstring host_string, jlong user_credential, jboolean ps5)
{
	AndroidDiscoveryService *service = (AndroidDiscoveryService *)ptr;
	const char *host = E->GetStringUTFChars(env, host_string, NULL);
	ChiakiErrorCode r = chiaki_discovery_wakeup(&global_log, service ? &service->service.discovery : NULL, host, (uint64_t)user_credential, ps5);
	E->ReleaseStringUTFChars(env, host_string, host);
	return r;
}


typedef struct android_chiaki_regist_t
{
	AndroidChiakiJNILog log;
	ChiakiRegist regist;

	jobject java_regist;
	jmethodID java_regist_event_meth;

	jclass java_target_class;

	jobject java_regist_event_canceled;
	jobject java_regist_event_failed;
	jclass java_regist_event_success_class;
	jmethodID java_regist_event_success_ctor;

	jclass java_regist_host_class;
	jmethodID java_regist_host_ctor;
} AndroidChiakiRegist;

static jobject create_jni_target(JNIEnv *env, jclass target_class, ChiakiTarget target)
{
	jmethodID meth = E->GetStaticMethodID(env, target_class, "fromValue", "(I)L"BASE_PACKAGE"/Target;");
	return E->CallStaticObjectMethod(env, target_class, meth, (jint)target);
}

static void android_chiaki_regist_cb(ChiakiRegistEvent *event, void *user)
{
	AndroidChiakiRegist *regist = user;

	JNIEnv *env = attach_thread_jni();
	if(!env)
		return;

	jobject java_event = NULL;
	switch(event->type)
	{
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
			java_event = regist->java_regist_event_canceled;
			break;
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED:
			java_event = regist->java_regist_event_failed;
			break;
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
		{
			ChiakiRegisteredHost *host = event->registered_host;
			jobject java_host = E->NewObject(env, regist->java_regist_host_class, regist->java_regist_host_ctor,
					create_jni_target(env, regist->java_target_class, host->target),
					jnistr_from_ascii(env, host->ap_ssid),
					jnistr_from_ascii(env, host->ap_bssid),
					jnistr_from_ascii(env, host->ap_key),
					jnistr_from_ascii(env, host->ap_name),
					jnibytearray_create(env, host->server_mac, sizeof(host->server_mac)),
					jnistr_from_ascii(env, host->server_nickname),
					jnibytearray_create(env, (const uint8_t *)host->rp_regist_key, sizeof(host->rp_regist_key)),
					(jint)host->rp_key_type,
					jnibytearray_create(env, host->rp_key, sizeof(host->rp_key)));
			java_event = E->NewObject(env, regist->java_regist_event_success_class, regist->java_regist_event_success_ctor, java_host);
			break;
		}
	}

	if(java_event)
		E->CallVoidMethod(env, regist->java_regist, regist->java_regist_event_meth, java_event);

	(*global_vm)->DetachCurrentThread(global_vm);
}

static void android_chiaki_regist_fini_partial(JNIEnv *env, AndroidChiakiRegist *regist)
{
	android_chiaki_jni_log_fini(&regist->log, env);
	E->DeleteGlobalRef(env, regist->java_regist);
	E->DeleteGlobalRef(env, regist->java_target_class);
	E->DeleteGlobalRef(env, regist->java_regist_event_canceled);
	E->DeleteGlobalRef(env, regist->java_regist_event_failed);
	E->DeleteGlobalRef(env, regist->java_regist_event_success_class);
	E->DeleteGlobalRef(env, regist->java_regist_host_class);
}

JNIEXPORT void JNICALL JNI_FCN(registStart)(JNIEnv *env, jobject obj, jobject result, jobject regist_info_obj, jobject log_obj, jobject java_regist)
{
	jclass result_class = E->GetObjectClass(env, result);
	ChiakiErrorCode err = CHIAKI_ERR_SUCCESS;
	AndroidChiakiRegist *regist = CHIAKI_NEW(AndroidChiakiRegist);
	if(!regist)
	{
		err = CHIAKI_ERR_MEMORY;
		goto beach;
	}

	android_chiaki_jni_log_init(&regist->log, env, log_obj);

	regist->java_regist = E->NewGlobalRef(env, java_regist);
	regist->java_regist_event_meth = E->GetMethodID(env, E->GetObjectClass(env, regist->java_regist), "event", "(L"BASE_PACKAGE"/RegistEvent;)V");

	regist->java_target_class = E->NewGlobalRef(env, E->FindClass(env, BASE_PACKAGE"/Target"));

	regist->java_regist_event_canceled = E->NewGlobalRef(env, get_kotlin_global_object(env, BASE_PACKAGE"/RegistEventCanceled"));
	regist->java_regist_event_failed = E->NewGlobalRef(env, get_kotlin_global_object(env, BASE_PACKAGE"/RegistEventFailed"));
	regist->java_regist_event_success_class = E->NewGlobalRef(env, E->FindClass(env, BASE_PACKAGE"/RegistEventSuccess"));
	regist->java_regist_event_success_ctor = E->GetMethodID(env, regist->java_regist_event_success_class, "<init>", "(L"BASE_PACKAGE"/RegistHost;)V");

	regist->java_regist_host_class = E->NewGlobalRef(env, E->FindClass(env, BASE_PACKAGE"/RegistHost"));
	regist->java_regist_host_ctor = E->GetMethodID(env, regist->java_regist_host_class, "<init>", "("
			  "L"BASE_PACKAGE"/Target;" // target: Target
			  "Ljava/lang/String;" // apSsid: String
			  "Ljava/lang/String;" // apBssid: String
			  "Ljava/lang/String;" // apKey: String
			  "Ljava/lang/String;" // apName: String
			  "[B" // serverMac: ByteArray
			  "Ljava/lang/String;" // serverNickname: String
			  "[B" // rpRegistKey: ByteArray
			  "I" // rpKeyType: UInt
			  "[B" // rpKey: ByteArray
			  ")V");

	jclass regist_info_class = E->GetObjectClass(env, regist_info_obj);

	jobject target_obj = E->GetObjectField(env, regist_info_obj, E->GetFieldID(env, regist_info_class, "target", "L"BASE_PACKAGE"/Target;"));
	jclass target_class = E->GetObjectClass(env, target_obj);
	jint target_value = E->GetIntField(env, target_obj, E->GetFieldID(env, target_class, "value", "I"));

	jstring host_string = E->GetObjectField(env, regist_info_obj, E->GetFieldID(env, regist_info_class, "host", "Ljava/lang/String;"));
	jboolean broadcast = E->GetBooleanField(env, regist_info_obj, E->GetFieldID(env, regist_info_class, "broadcast", "Z"));
	jstring psn_online_id_string = E->GetObjectField(env, regist_info_obj, E->GetFieldID(env, regist_info_class, "psnOnlineId", "Ljava/lang/String;"));
	jbyteArray psn_account_id_array = E->GetObjectField(env, regist_info_obj, E->GetFieldID(env, regist_info_class, "psnAccountId", "[B"));
	jint pin = E->GetIntField(env, regist_info_obj, E->GetFieldID(env, regist_info_class, "pin", "I"));

	ChiakiRegistInfo regist_info = { 0 };
	regist_info.target = (ChiakiTarget)target_value;
	regist_info.host = E->GetStringUTFChars(env, host_string, NULL);
	regist_info.broadcast = broadcast;
	if(psn_online_id_string)
		regist_info.psn_online_id = E->GetStringUTFChars(env, psn_online_id_string, NULL);
	if(psn_account_id_array && E->GetArrayLength(env, psn_account_id_array) == sizeof(regist_info.psn_account_id))
		E->GetByteArrayRegion(env, psn_account_id_array, 0, sizeof(regist_info.psn_account_id), (jbyte *)regist_info.psn_account_id);
	regist_info.pin = (uint32_t)pin;

	err = chiaki_regist_start(&regist->regist, &regist->log.log, &regist_info, android_chiaki_regist_cb, regist);

	E->ReleaseStringUTFChars(env, host_string, regist_info.host);
	if(regist_info.psn_online_id)
		E->ReleaseStringUTFChars(env, psn_online_id_string, regist_info.psn_online_id);

	if(err != CHIAKI_ERR_SUCCESS)
	{
		android_chiaki_regist_fini_partial(env, regist);
		free(regist);
		regist = NULL;
	}

beach:
	E->SetIntField(env, result, E->GetFieldID(env, result_class, "errorCode", "I"), (jint)err);
	E->SetLongField(env, result, E->GetFieldID(env, result_class, "ptr", "J"), (jlong)regist);
}

JNIEXPORT void JNICALL JNI_FCN(registStop)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiRegist *regist = (AndroidChiakiRegist *)ptr;
	chiaki_regist_stop(&regist->regist);
}

JNIEXPORT void JNICALL JNI_FCN(registFree)(JNIEnv *env, jobject obj, jlong ptr)
{
	AndroidChiakiRegist *regist = (AndroidChiakiRegist *)ptr;
	chiaki_regist_fini(&regist->regist);
	android_chiaki_regist_fini_partial(env, regist);
	free(regist);
}
