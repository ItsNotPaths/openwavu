// Stock TK5 presenter (gamerender.wasm): the parts its frame calls, each reading the sim view.
#ifndef T5_PRESENTER_H
#define T5_PRESENTER_H

#include <stdbool.h>
#include "openwavu.h"
#include "view.h"

static const float MM = 0.001f;  // sim units to scene metres

// The fighters' costume parts and the stage, by asset id; false when the db does not open.
bool t5_scene_init(const T5View *view);
// The whole scene of this frame.
void t5_scene_send(const T5View *view);
// The fight camera: behind the line between the fighters, on the sim's camera side.
OwCamera t5_fight_camera(const T5View *view);
// Health, timer, round marks and the phase banners, in SDL 2D.
void t5_hud_draw(const T5View *view);

#endif
