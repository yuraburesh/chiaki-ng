// AnyPlay 145: визначник «пішки чи транспорт» за адаптивними курками — той самий код, що в програмі для комп'ютера
// (gui/include/anyplayvehicle.h, копіюється сюди під час збірки). C-інтерфейс для Swift (KeyLayout.swift).
#ifndef ANYPLAY_VEHICLE_BRIDGE_H
#define ANYPLAY_VEHICLE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct APVehicle APVehicle;

/** Події гравця для визначника (як AnyPlayInput::NoteGameEvent на комп'ютері) */
enum
{
	AP_VEH_MENU_TOGGLE = 1,   // пауза
	AP_VEH_MENU_ON = 2,       // мапа, PS
	AP_VEH_MENU_OFF = 3,      // дія в грі
	AP_VEH_ACTIVITY = 4,
	AP_VEH_INTERACT = 5,      // △
	AP_VEH_WEAPON = 6,        // колесо зброї, кобура
	AP_VEH_BOX = 7,           // □
	AP_VEH_MINIGAME = 8       // обертання стіків
};

APVehicle *ap_vehicle_new(const char *layout, bool vehicle, int64_t now_ms);
void ap_vehicle_free(APVehicle *v);
void ap_vehicle_triggers(APVehicle *v, uint8_t type_left, uint8_t type_right, const uint8_t *data20, int64_t now_ms);
void ap_vehicle_rumble(APVehicle *v, uint8_t left, uint8_t right, int64_t now_ms);
void ap_vehicle_event(APVehicle *v, int kind, int64_t now_ms);
void ap_vehicle_aiming(APVehicle *v, bool on, int64_t now_ms);
void ap_vehicle_moving(APVehicle *v, bool on, int64_t now_ms);
void ap_vehicle_manual(APVehicle *v, bool vehicle, int64_t now_ms);
/** +1 — перемкнути на транспорт, -1 — на пішки, 0 — нічого */
int ap_vehicle_tick(APVehicle *v, int64_t now_ms);
bool ap_vehicle_menu(APVehicle *v);
/** Текст для журналу (порожній — нічого); буфер до size байт */
void ap_vehicle_take_log(APVehicle *v, char *out, int size);

#ifdef __cplusplus
}
#endif

#endif
