// AnyPlay 145: обгортка над визначником з програми для комп'ютера (див. VehicleBridge.h)
#include "VehicleBridge.h"
#include "anyplayvehicle.h"

#include <cstring>

struct APVehicle
{
	AnyPlayVehicleDetector d;
};

APVehicle *ap_vehicle_new(const char *layout, bool vehicle, int64_t now_ms)
{
	APVehicle *v = new APVehicle();
	v->d.Reset(AnyPlayVehicleRulesFor(layout ? layout : "gta6"), vehicle, now_ms);
	return v;
}

void ap_vehicle_free(APVehicle *v) { delete v; }

void ap_vehicle_triggers(APVehicle *v, uint8_t type_left, uint8_t type_right, const uint8_t *data20, int64_t now_ms)
{
	if(!v) return;
	const bool el = data20 ? AnyPlayTriggerDataEmpty(data20) : false;
	const bool er = data20 ? AnyPlayTriggerDataEmpty(data20 + 10) : false;
	v->d.Triggers(AnyPlayTriggerClass(type_left, el), AnyPlayTriggerClass(type_right, er), type_left, type_right, now_ms);
}

void ap_vehicle_rumble(APVehicle *v, uint8_t left, uint8_t right, int64_t now_ms) { if(v) v->d.Rumble(left, right, now_ms); }

void ap_vehicle_event(APVehicle *v, int kind, int64_t now_ms)
{
	if(!v) return;
	switch(kind)
	{
		case AP_VEH_MENU_TOGGLE: v->d.SetMenu(!v->d.menu, now_ms); break;
		case AP_VEH_MENU_ON: v->d.SetMenu(true, now_ms); break;
		case AP_VEH_MENU_OFF: v->d.SetMenu(false, now_ms); break;
		case AP_VEH_ACTIVITY: v->d.Activity(now_ms); break;
		case AP_VEH_INTERACT: v->d.Interact(now_ms); break;
		case AP_VEH_WEAPON: v->d.Weapon(now_ms); break;
		case AP_VEH_BOX: v->d.Box(now_ms); break;
		case AP_VEH_MINIGAME: v->d.Minigame(now_ms); break;
		default: break;
	}
}

void ap_vehicle_aiming(APVehicle *v, bool on, int64_t now_ms) { if(v) v->d.SetAiming(on, now_ms); }
void ap_vehicle_moving(APVehicle *v, bool on, int64_t now_ms) { if(v) v->d.SetMoving(on, now_ms); }
void ap_vehicle_manual(APVehicle *v, bool vehicle, int64_t now_ms) { if(v) v->d.Manual(vehicle, now_ms); }
int ap_vehicle_tick(APVehicle *v, int64_t now_ms) { return v ? v->d.Tick(now_ms) : 0; }
bool ap_vehicle_menu(APVehicle *v) { return v ? v->d.menu : false; }

void ap_vehicle_take_log(APVehicle *v, char *out, int size)
{
	if(!out || size <= 0) return;
	out[0] = 0;
	if(!v) return;
	const std::string s = v->d.TakeLog();
	std::strncpy(out, s.c_str(), size - 1);
	out[size - 1] = 0;
}
