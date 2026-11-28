// AnyPlay 157: трансляція з iPhone та iPad — гачки потоків гри (реалізація в anyplay_live.cpp)
#ifndef ANYPLAY_LIVE_HOOKS_H
#define ANYPLAY_LIVE_HOOKS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef ANYPLAY_IOS_LIVE
/** Кадр відео з PS5 (Annex-B), той самий, що йде в декодер. Дешево: копія в чергу, лише коли йде ефір */
void anyplay_live_tap_video(const uint8_t *data, size_t size);
/** Заголовок звуку гри */
void anyplay_live_tap_audio_header(unsigned channels, unsigned rate, unsigned frame_size);
/** Пакет Opus з PS5 як є */
void anyplay_live_tap_opus(const uint8_t *data, size_t size);
/** Поточна сесія гри (для запиту ключового кадру) */
void anyplay_live_set_session(void *core);
void anyplay_live_unset_session(void *core);
#else
static inline void anyplay_live_tap_video(const uint8_t *data, size_t size) { (void)data; (void)size; }
static inline void anyplay_live_tap_audio_header(unsigned channels, unsigned rate, unsigned frame_size) { (void)channels; (void)rate; (void)frame_size; }
static inline void anyplay_live_tap_opus(const uint8_t *data, size_t size) { (void)data; (void)size; }
static inline void anyplay_live_set_session(void *core) { (void)core; }
static inline void anyplay_live_unset_session(void *core) { (void)core; }
#endif

#ifdef __cplusplus
}
#endif

#endif
