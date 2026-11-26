// AnyPlay для iPhone та iPad: рідна частина. Те саме, що chiaki-jni.c на Android, але без JNI: Swift отримує
// кадри відео як є (Annex-B), звук уже в PCM (Opus декодуємо тут), події й керування простими функціями.
#include "anyplay_core.h"

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/session.h>
#include <chiaki/controller.h>
#include <chiaki/remote/holepunch.h>

#include <opus.h>

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct AnyPlayCore
{
	ChiakiLog log;
	ChiakiSession session;
	ChiakiHolepunchSession holepunch;
	ChiakiControllerState controller;
	ChiakiMutex controller_mutex;
	AnyPlayCallbacks cb;
	bool session_inited;
	bool started;
	atomic_int psn_step;
	// звук
	OpusDecoder *opus;
	unsigned channels, rate, frame_size;
	int16_t *pcm;
	size_t pcm_frames;
};

static void core_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	AnyPlayCore *core = user;
	if(core && core->cb.log)
		core->cb.log(core->cb.user, (int)level, msg);
	else
		fprintf(stderr, "[chiaki %d] %s\n", (int)level, msg);
}

static void core_event_cb(ChiakiEvent *event, void *user)
{
	AnyPlayCore *core = user;
	if(!core->cb.event)
		return;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			core->cb.event(core->cb.user, ANYPLAY_EVENT_CONNECTED, 0, 0, NULL, NULL, 0);
			break;
		case CHIAKI_EVENT_QUIT:
			core->cb.event(core->cb.user, ANYPLAY_EVENT_QUIT, (int)event->quit.reason, 0, event->quit.reason_str, NULL, 0);
			break;
		case CHIAKI_EVENT_RUMBLE:
			core->cb.event(core->cb.user, ANYPLAY_EVENT_RUMBLE, event->rumble.left, event->rumble.right, NULL, NULL, 0);
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
		{
			uint8_t d[20];
			memcpy(d, event->trigger_effects.left, 10);
			memcpy(d + 10, event->trigger_effects.right, 10);
			core->cb.event(core->cb.user, ANYPLAY_EVENT_TRIGGERS, event->trigger_effects.type_left, event->trigger_effects.type_right, NULL, d, sizeof(d));
			break;
		}
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			core->cb.event(core->cb.user, ANYPLAY_EVENT_LOGIN_PIN, event->login_pin_request.pin_incorrect ? 1 : 0, 0, NULL, NULL, 0);
			break;
		default:
			break;
	}
}

static bool core_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	AnyPlayCore *core = user;
	if(!core->cb.video)
		return true;
	return core->cb.video(core->cb.user, buf, buf_size, frames_lost, frame_recovered);
}

static void core_audio_header_cb(ChiakiAudioHeader *header, void *user)
{
	AnyPlayCore *core = user;
	if(core->opus)
	{
		opus_decoder_destroy(core->opus);
		core->opus = NULL;
	}
	int err = 0;
	core->channels = header->channels ? header->channels : 2;
	core->rate = header->rate ? header->rate : 48000;
	core->frame_size = header->frame_size ? header->frame_size : 480;
	core->opus = opus_decoder_create((opus_int32)core->rate, (int)core->channels, &err);
	if(!core->opus)
		CHIAKI_LOGE(&core->log, "AnyPlay iOS: Opus decoder failed (%d)", err);
	// запас на найдовший кадр Opus (120 мс)
	size_t want = (size_t)core->rate * 120 / 1000;
	if(want > core->pcm_frames)
	{
		free(core->pcm);
		core->pcm = malloc(want * core->channels * sizeof(int16_t));
		core->pcm_frames = core->pcm ? want : 0;
	}
	if(core->cb.audio_format)
		core->cb.audio_format(core->cb.user, core->channels, core->rate);
}

static void core_audio_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
	AnyPlayCore *core = user;
	if(!core->opus || !core->pcm || !core->cb.audio)
		return;
	int n = opus_decode(core->opus, buf, (opus_int32)buf_size, core->pcm, (int)core->pcm_frames, 0);
	if(n > 0)
		core->cb.audio(core->cb.user, core->pcm, (size_t)n);
}

static int hex_nibble(char c)
{
	if(c >= '0' && c <= '9') return c - '0';
	if(c >= 'a' && c <= 'f') return c - 'a' + 10;
	if(c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static bool parse_hex(uint8_t *buf, size_t size, const char *hex)
{
	if(!hex || strlen(hex) != size * 2)
		return false;
	for(size_t i = 0; i < size; i++)
	{
		int a = hex_nibble(hex[2 * i]), b = hex_nibble(hex[2 * i + 1]);
		if(a < 0 || b < 0)
			return false;
		buf[i] = (uint8_t)((a << 4) | b);
	}
	return true;
}

static atomic_bool lib_ready;

AnyPlayCore *anyplay_core_create(const AnyPlayConnect *info, const AnyPlayCallbacks *cb, int *err_out)
{
	ChiakiErrorCode err = CHIAKI_ERR_SUCCESS;
	if(!atomic_exchange(&lib_ready, true))
		chiaki_lib_init();
	AnyPlayCore *core = calloc(1, sizeof(AnyPlayCore));
	if(!core)
	{
		if(err_out) *err_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	if(cb)
		core->cb = *cb;
	chiaki_log_init(&core->log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, core_log_cb, core);
	chiaki_controller_state_set_idle(&core->controller);
	chiaki_mutex_init(&core->controller_mutex, false);

	ChiakiConnectInfo ci = { 0 };
	ci.ps5 = info->ps5;
	ci.host = info->host ? info->host : "0.0.0.0";
	memcpy(ci.regist_key, info->regist_key, sizeof(ci.regist_key));
	memcpy(ci.morning, info->morning, sizeof(ci.morning));
	ci.video_profile.width = info->width;
	ci.video_profile.height = info->height;
	ci.video_profile.max_fps = info->max_fps;
	ci.video_profile.bitrate = info->bitrate;
	ci.video_profile.codec = info->h265 ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
	ci.video_profile_auto_downgrade = true;
	ci.enable_idr_on_fec_failure = true;
	// як на Android 118.1 і на комп'ютері: приставка бачить DualSense (ігри для PS5 інакше не беруть керування)
	ci.enable_dualsense = info->ps5;
	ci.packet_loss_max = 0.05;

	if(info->psn_token)
	{
		memcpy(ci.psn_account_id, info->psn_account_id, sizeof(ci.psn_account_id));
		core->holepunch = chiaki_holepunch_session_init(info->psn_token, &core->log);
		if(!core->holepunch)
		{
			CHIAKI_LOGE(&core->log, "AnyPlay iOS: PSN holepunch init failed");
			err = CHIAKI_ERR_MEMORY;
			goto fail;
		}
		ci.holepunch_session = core->holepunch;
	}

	err = chiaki_session_init(&core->session, &ci, &core->log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&core->log, "AnyPlay iOS: session init failed: %s", chiaki_error_string(err));
		if(core->holepunch)
			chiaki_holepunch_session_fini(core->holepunch);
		goto fail;
	}
	core->session_inited = true;
	chiaki_session_set_event_cb(&core->session, core_event_cb, core);
	chiaki_session_set_video_sample_cb(&core->session, core_video_cb, core);
	ChiakiAudioSink sink = { 0 };
	sink.user = core;
	sink.header_cb = core_audio_header_cb;
	sink.frame_cb = core_audio_frame_cb;
	chiaki_session_set_audio_sink(&core->session, &sink);
	if(err_out) *err_out = 0;
	return core;

fail:
	chiaki_mutex_fini(&core->controller_mutex);
	free(core);
	if(err_out) *err_out = (int)err;
	return NULL;
}

int anyplay_core_psn_connect(AnyPlayCore *core, const char *duid_hex)
{
	if(!core || !core->holepunch)
		return CHIAKI_ERR_INVALID_DATA;
	uint8_t duid[32];
	if(!parse_hex(duid, sizeof(duid), duid_hex))
	{
		CHIAKI_LOGE(&core->log, "PSN: invalid console id");
		return CHIAKI_ERR_INVALID_DATA;
	}
	ChiakiErrorCode err;
	atomic_store(&core->psn_step, 1);
	if((err = chiaki_holepunch_upnp_discover(core->holepunch)) != CHIAKI_ERR_SUCCESS) { CHIAKI_LOGE(&core->log, "PSN: upnp discover failed"); return err; }
	atomic_store(&core->psn_step, 2);
	if((err = chiaki_holepunch_session_create(core->holepunch)) != CHIAKI_ERR_SUCCESS) { CHIAKI_LOGE(&core->log, "PSN: failed to create session"); return err; }
	atomic_store(&core->psn_step, 3);
	if((err = holepunch_session_create_offer(core->holepunch)) != CHIAKI_ERR_SUCCESS) { CHIAKI_LOGE(&core->log, "PSN: failed to create offer"); return err; }
	atomic_store(&core->psn_step, 4);
	if((err = chiaki_holepunch_session_start(core->holepunch, duid, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5)) != CHIAKI_ERR_SUCCESS) { CHIAKI_LOGE(&core->log, "PSN: failed to start session"); return err; }
	atomic_store(&core->psn_step, 5);
	if((err = chiaki_holepunch_session_punch_hole(core->holepunch, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL)) != CHIAKI_ERR_SUCCESS) { CHIAKI_LOGE(&core->log, "PSN: failed to punch hole"); return err; }
	atomic_store(&core->psn_step, 6);
	CHIAKI_LOGI(&core->log, "PSN: punched hole for control connection");
	return CHIAKI_ERR_SUCCESS;
}

int anyplay_core_psn_step(AnyPlayCore *core) { return core ? atomic_load(&core->psn_step) : 0; }

void anyplay_core_psn_cancel(AnyPlayCore *core)
{
	if(core && core->holepunch)
		chiaki_holepunch_main_thread_cancel(core->holepunch, false);
}

int anyplay_core_start(AnyPlayCore *core)
{
	if(!core || !core->session_inited)
		return CHIAKI_ERR_INVALID_DATA;
	ChiakiErrorCode err = chiaki_session_start(&core->session);
	if(err == CHIAKI_ERR_SUCCESS)
		core->started = true;
	return err;
}

void anyplay_core_stop(AnyPlayCore *core)
{
	if(core && core->started)
		chiaki_session_stop(&core->session);
}

void anyplay_core_free(AnyPlayCore *core)
{
	if(!core)
		return;
	if(core->started)
	{
		chiaki_session_stop(&core->session);
		chiaki_session_join(&core->session);
	}
	if(core->session_inited)
		chiaki_session_fini(&core->session);
	if(core->opus)
		opus_decoder_destroy(core->opus);
	free(core->pcm);
	chiaki_mutex_fini(&core->controller_mutex);
	free(core);
}

static void send_controller(AnyPlayCore *core)
{
	if(core->started)
		chiaki_session_set_controller_state(&core->session, &core->controller);
}

void anyplay_core_set_controller(AnyPlayCore *core, uint32_t buttons, uint8_t l2, uint8_t r2, int16_t lx, int16_t ly, int16_t rx, int16_t ry)
{
	if(!core) return;
	chiaki_mutex_lock(&core->controller_mutex);
	core->controller.buttons = buttons;
	core->controller.l2_state = l2;
	core->controller.r2_state = r2;
	core->controller.left_x = lx;
	core->controller.left_y = ly;
	core->controller.right_x = rx;
	core->controller.right_y = ry;
	send_controller(core);
	chiaki_mutex_unlock(&core->controller_mutex);
}

int anyplay_core_touch(AnyPlayCore *core, int id, uint16_t x, uint16_t y, bool up)
{
	if(!core) return -1;
	chiaki_mutex_lock(&core->controller_mutex);
	int r = id;
	if(up)
	{
		if(id >= 0)
			chiaki_controller_state_stop_touch(&core->controller, (uint8_t)id);
		r = -1;
	}
	else if(id < 0)
		r = chiaki_controller_state_start_touch(&core->controller, x, y);
	else
		chiaki_controller_state_set_touch_pos(&core->controller, (uint8_t)id, x, y);
	send_controller(core);
	chiaki_mutex_unlock(&core->controller_mutex);
	return r;
}

void anyplay_core_set_motion(AnyPlayCore *core, float gx, float gy, float gz, float ax, float ay, float az, float ox, float oy, float oz, float ow)
{
	if(!core) return;
	chiaki_mutex_lock(&core->controller_mutex);
	core->controller.gyro_x = gx; core->controller.gyro_y = gy; core->controller.gyro_z = gz;
	core->controller.accel_x = ax; core->controller.accel_y = ay; core->controller.accel_z = az;
	core->controller.orient_x = ox; core->controller.orient_y = oy; core->controller.orient_z = oz; core->controller.orient_w = ow;
	send_controller(core);
	chiaki_mutex_unlock(&core->controller_mutex);
}

void anyplay_core_set_login_pin(AnyPlayCore *core, const char *pin)
{
	if(core && pin && core->session_inited)
		chiaki_session_set_login_pin(&core->session, (const uint8_t *)pin, strlen(pin));
}

void anyplay_core_request_idr(AnyPlayCore *core)
{
	if(core && core->started)
		chiaki_session_request_idr(&core->session);
}

double anyplay_core_packet_loss(AnyPlayCore *core)
{
	return core && core->started ? core->session.stream_connection.congestion_control.packet_loss : 0.0;
}

uint64_t anyplay_core_rtt_us(AnyPlayCore *core)
{
	return core && core->started ? core->session.rtt_us : 0;
}

double anyplay_core_bitrate(AnyPlayCore *core)
{
	return core && core->started ? core->session.stream_connection.measured_bitrate : 0.0;
}

const char *anyplay_core_error_string(int err) { return chiaki_error_string((ChiakiErrorCode)err); }
const char *anyplay_core_quit_string(int reason) { return chiaki_quit_reason_string((ChiakiQuitReason)reason); }
bool anyplay_core_quit_is_error(int reason) { return chiaki_quit_reason_is_error((ChiakiQuitReason)reason); }

extern void chiaki_aia_set_ca_file(const char *path);

void anyplay_core_set_ca_bundle(const char *path)
{
	if(!path) return;
	// curl зібрано без вбудованого шляху до сертифікатів (як на Android): OpenSSL бере файл зі SSL_CERT_FILE
	setenv("SSL_CERT_FILE", path, 1);
	setenv("CURL_CA_BUNDLE", path, 1);
	// 132: той самий файл для відновлення ланцюжка сертифікатів сервера сповіщень Sony (як на Android). Без нього
	// на iPad підключення падало на кроці 2 з «помилка 6»: curl не бачив кореня для довантаженого проміжного сертифіката
	chiaki_aia_set_ca_file(path);
}

int anyplay_core_psn_devices(const char *token, char *out, size_t out_size)
{
	if(!out || out_size < 16)
		return CHIAKI_ERR_INVALID_DATA;
	if(!atomic_exchange(&lib_ready, true))
		chiaki_lib_init();
	static ChiakiLog list_log;
	static atomic_bool list_log_ready;
	if(!atomic_exchange(&list_log_ready, true))
		chiaki_log_init(&list_log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, chiaki_log_cb_print, NULL);
	ChiakiHolepunchDeviceInfo *devices = NULL;
	size_t count = 0;
	ChiakiErrorCode err = token ? chiaki_holepunch_list_devices(token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices, &count, &list_log)
		: CHIAKI_ERR_INVALID_DATA;
	if(err != CHIAKI_ERR_SUCCESS)
	{
		snprintf(out, out_size, "err\t%d\n", (int)err);
		return err;
	}
	size_t off = (size_t)snprintf(out, out_size, "ok\n");
	for(size_t i = 0; i < count && off < out_size; i++)
	{
		char hex[sizeof(devices[i].device_uid) * 2 + 1];
		for(size_t j = 0; j < sizeof(devices[i].device_uid); j++)
			snprintf(hex + 2 * j, 3, "%02x", devices[i].device_uid[j]);
		char name[sizeof(devices[i].device_name) + 1];
		memcpy(name, devices[i].device_name, sizeof(devices[i].device_name));
		name[sizeof(devices[i].device_name)] = 0;
		for(char *c = name; *c; c++)
			if(*c == '\t' || *c == '\n')
				*c = ' ';
		off += (size_t)snprintf(out + off, out_size - off, "%s\t%s\t%d\n", hex, name, devices[i].remoteplay_enabled ? 1 : 0);
	}
	if(devices)
		chiaki_holepunch_free_device_list(&devices);
	return CHIAKI_ERR_SUCCESS;
}
