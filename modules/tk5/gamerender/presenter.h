// Stock TK5 presenter (gamerender.wasm): the parts its frame calls, each reading the sim view.
#ifndef T5_PRESENTER_H
#define T5_PRESENTER_H

#include <stdbool.h>
#include "openwavu.h"
#include "view.h"

static const float MM = 0.001f;  // sim units to scene metres

// The fighters' costume parts and hand banks, and the stage, by asset id; false when the db does not open.
bool t5_scene_init(const T5View *view);
// The whole scene of this frame, `seconds` after the last.
void t5_scene_send(const T5View *view, float seconds);
typedef struct sqlite3 sqlite3;
// The camera shots of both sides' moves.
void t5_camera_init(sqlite3 *db, const T5View *view);
// A move's camera shot while it plays, else the fight camera: behind the line between the fighters, on the sim's camera
// side, eased over the `seconds` since the last frame.
OwCamera t5_camera(const T5View *view, float seconds);
// Health, timer, round marks and the phase banners, in SDL 2D.
void t5_hud_draw(const T5View *view);

#endif
