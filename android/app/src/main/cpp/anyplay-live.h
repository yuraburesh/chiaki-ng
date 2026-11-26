// AnyPlay 124: трансляція друзям з телефона — гачки потоків гри (див. anyplay-live.cpp)
#ifndef ANYPLAY_LIVE_H
#define ANYPLAY_LIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef ANYPLAY_ANDROID_LIVE
/** Кадр відео з PS5 (Annex-B), той самий, що йде в декодер телефона. Дешево: копія в чергу, лише коли йде ефір */
void anyplay_live_tap_video(const uint8_t *data, size_t size);
/** Заголовок звуку гри */
void anyplay_live_tap_audio_header(unsigned channels, unsigned rate, unsigned frame_size);
/** Пакет Opus з PS5 як є */
void anyplay_live_tap_opus(const uint8_t *data, size_t size);
/** Поточна сесія гри (для запиту ключового кадру) */
void anyplay_live_set_session(void *session);
void anyplay_live_unset_session(void *session);
#else
static inline void anyplay_live_tap_video(const uint8_t *data, size_t size) { (void)data; (void)size; }
static inline void anyplay_live_tap_audio_header(unsigned channels, unsigned rate, unsigned frame_size) { (void)channels; (void)rate; (void)frame_size; }
static inline void anyplay_live_tap_opus(const uint8_t *data, size_t size) { (void)data; (void)size; }
static inline void anyplay_live_set_session(void *session) { (void)session; }
static inline void anyplay_live_unset_session(void *session) { (void)session; }
#endif

/** Реалізовано в chiaki-jni.c: попросити в приставки ключовий кадр для глядачів (не чіпаючи картинку гравця) */
void anyplay_live_request_idr(void *session);

#ifdef __cplusplus
}
#endif

#endif
