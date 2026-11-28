// AnyPlay для iPhone та iPad: рідна частина (бібліотека chiaki + звук Opus) з простим C-інтерфейсом для Swift.
// Повторює те, що на Android робить chiaki-jni.c: з'єднання з PS5 через PSN, відео (Annex-B як є, декодує VideoToolbox
// у Swift), звук (тут декодується з Opus у PCM 16 біт), керування, події (підключено, кінець, вібрація, курки).
#ifndef ANYPLAY_CORE_H
#define ANYPLAY_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnyPlayCore AnyPlayCore;

/** Що дає сервер AnyPlay для гри (як ConnectInfo на Android) */
typedef struct
{
	bool ps5;
	const char *host;               // адреса приставки (для PSN — будь-яка, з'єднання пробиває holepunch)
	uint8_t regist_key[16];
	uint8_t morning[16];
	uint32_t width, height, max_fps, bitrate;
	bool h265;
	const char *psn_token;          // NULL — пряме з'єднання в локальній мережі
	uint8_t psn_account_id[8];
} AnyPlayConnect;

enum
{
	ANYPLAY_EVENT_CONNECTED = 1,
	ANYPLAY_EVENT_QUIT = 2,          // a — причина (ChiakiQuitReason), text — опис
	ANYPLAY_EVENT_RUMBLE = 3,        // a — лівий мотор 0..255, b — правий
	ANYPLAY_EVENT_TRIGGERS = 4,      // a — тип L2, b — тип R2, data — 20 байтів (10 L2 + 10 R2)
	ANYPLAY_EVENT_LOGIN_PIN = 5      // a — 1, якщо попередній PIN був неправильний
};

typedef struct
{
	void *user;
	/** Кадр відео (Annex-B, H.264 або H.265) з потоку сесії. Повернути true — прийнято */
	bool (*video)(void *user, const uint8_t *data, size_t size, int32_t frames_lost, bool frame_recovered);
	/** Звук почався або змінився формат */
	void (*audio_format)(void *user, unsigned channels, unsigned rate);
	/** PCM 16 біт, переміжаний, frames кадрів на канал */
	void (*audio)(void *user, const int16_t *pcm, size_t frames);
	void (*event)(void *user, int type, int a, int b, const char *text, const uint8_t *data, size_t data_size);
	void (*log)(void *user, int level, const char *msg);
} AnyPlayCallbacks;

/** err — код помилки chiaki (0 — успіх) */
AnyPlayCore *anyplay_core_create(const AnyPlayConnect *info, const AnyPlayCallbacks *cb, int *err);
/** Пробити з'єднання через PSN (довго, до хвилини: не з головного потоку). duid_hex — 64 шістнадцяткові символи */
int anyplay_core_psn_connect(AnyPlayCore *core, const char *duid_hex);
/** Крок з'єднання через PSN: 1 роутер, 2 сесія Sony, 3 STUN, 4 приставка приєднується, 5 пряме з'єднання, 6 готово */
int anyplay_core_psn_step(AnyPlayCore *core);
/** 155: зовнішня адреса приставки з обміну через PSN (після спроби «пробити»): 0 — є, інакше немає */
int anyplay_core_psn_console_addr(AnyPlayCore *core, char *out, size_t out_len);
void anyplay_core_psn_cancel(AnyPlayCore *core);
int anyplay_core_start(AnyPlayCore *core);
void anyplay_core_stop(AnyPlayCore *core);
/** Зупинити й звільнити (чекає кінця потоку сесії) */
void anyplay_core_free(AnyPlayCore *core);

void anyplay_core_set_controller(AnyPlayCore *core, uint32_t buttons, uint8_t l2, uint8_t r2,
	int16_t lx, int16_t ly, int16_t rx, int16_t ry);
/** Дотик до тачпада: id -1 — новий (повертає id), x/y у координатах тачпада 1920 × 942; up — відпустили */
int anyplay_core_touch(AnyPlayCore *core, int id, uint16_t x, uint16_t y, bool up);
/** Датчики руху телефона чи геймпада (гіроскоп рад/с, прискорення в g, орієнтація кватерніоном) */
void anyplay_core_set_motion(AnyPlayCore *core, float gx, float gy, float gz, float ax, float ay, float az,
	float ox, float oy, float oz, float ow);
void anyplay_core_set_login_pin(AnyPlayCore *core, const char *pin);
void anyplay_core_request_idr(AnyPlayCore *core);
/** Частка втрачених пакетів 0..1 */
double anyplay_core_packet_loss(AnyPlayCore *core);
/** Затримка до приставки, мкс (замір на старті) */
uint64_t anyplay_core_rtt_us(AnyPlayCore *core);
/** Виміряна швидкість потоку, Мбіт/с */
double anyplay_core_bitrate(AnyPlayCore *core);

const char *anyplay_core_error_string(int err);
const char *anyplay_core_quit_string(int reason);
bool anyplay_core_quit_is_error(int reason);

/**
 * Приставки акаунта PSN (блокує потік, мережа). Результат у out: перший рядок «ok» або «err<TAB>код»,
 * далі рядки «duid<TAB>назва<TAB>1|0» (1 — дистанційне відтворення увімкнено). Повертає код помилки chiaki.
 */
int anyplay_core_psn_devices(const char *token, char *out, size_t out_size);

/** Файл сертифікатів для HTTPS (PSN) — з пакета програми */
void anyplay_core_set_ca_bundle(const char *path);

// Кнопки (ChiakiControllerButton)
enum
{
	ANYPLAY_BTN_CROSS = 1 << 0, ANYPLAY_BTN_MOON = 1 << 1, ANYPLAY_BTN_BOX = 1 << 2, ANYPLAY_BTN_PYRAMID = 1 << 3,
	ANYPLAY_BTN_DPAD_LEFT = 1 << 4, ANYPLAY_BTN_DPAD_RIGHT = 1 << 5, ANYPLAY_BTN_DPAD_UP = 1 << 6, ANYPLAY_BTN_DPAD_DOWN = 1 << 7,
	ANYPLAY_BTN_L1 = 1 << 8, ANYPLAY_BTN_R1 = 1 << 9, ANYPLAY_BTN_L3 = 1 << 10, ANYPLAY_BTN_R3 = 1 << 11,
	ANYPLAY_BTN_OPTIONS = 1 << 12, ANYPLAY_BTN_SHARE = 1 << 13, ANYPLAY_BTN_TOUCHPAD = 1 << 14, ANYPLAY_BTN_PS = 1 << 15
};

/**
 * 136: шукає приставку в домашній мережі (за MAC з прив'язки, 12 hex-символів). 0 — знайдено, адреса в addr_out;
 * 1 — немає в мережі; 2 — у режимі спокою й не прокинулась; від'ємне — телефон не в Wi-Fi чи помилка.
 * regist_key — ключ прив'язки (rp_regist_key, текст hex) для команди «прокинься». Блокує потік.
 */
int anyplay_core_lan_find(const char *mac_hex, const char *regist_key, int search_ms, int wake_ms, char *addr_out, size_t addr_size);

// ── 157: трансляція друзям (WebRTC через libdatachannel; сигналізацію робить AnyPlayLive.swift через наш сервер) ──
int anyplay_live_available(void);
void anyplay_live_set_log(void (*cb)(const char *line));
/** Чи є заголовок відео гри (SPS/PPS), без нього трансляцію не почати */
int anyplay_live_header_ready(void);
/** "H.264" | "H.265" | "" */
void anyplay_live_codec(char *out, size_t n);
int64_t anyplay_live_game_bytes(void);
/** ice_urls — адреси STUN через \n. 0 — добре, інакше текст помилки в err_out */
int anyplay_live_create(const char *ice_urls, int pace_kbps, char *err_out, size_t err_n);
int anyplay_live_gathered(void);
/** Наш offer SDP; повертає потрібний розмір буфера (з нулем) */
size_t anyplay_live_local_sdp(char *out, size_t n);
int anyplay_live_apply_answer(const char *sdp, char *err_out, size_t err_n);
/** new | connecting | connected | disconnected | failed | closed | off */
void anyplay_live_state(char *out, size_t n);
int anyplay_live_open_channel(int id, const char *label, int ordered, int max_retransmits);
int anyplay_live_send(int id, const char *text);
void anyplay_live_go_live(int game_audio);
void anyplay_live_set_game_audio(int on);
void anyplay_live_set_video_on(int on);
void anyplay_live_request_keyframe(void);
int anyplay_live_take_key_wanted(void);
/** [кадрів прийшло, надіслано, пропущено, ключових, байтів надіслано, черга мс, rtt мс, втрати %, переповнень] */
void anyplay_live_stats(int64_t *out9);
void anyplay_live_close(int events_channel);

#ifdef __cplusplus
}
#endif

#endif
