#ifndef MAC_TRACKPAD_HAPTIC_H
#define MAC_TRACKPAD_HAPTIC_H

#ifdef __cplusplus
extern "C" {
#endif

// macOS only (AnyPlay, «віддача на екрані»): один легкий поштовх трекпада Force Touch.
// Система відтворює його, лише коли палець лежить на трекпаді; на Mac без такого трекпада нічого не відбувається.
// strong != 0 — трохи відчутніший поштовх. Викликати з головного потоку.
void macTrackpadHapticTick(int strong);

#ifdef __cplusplus
}
#endif

#endif
