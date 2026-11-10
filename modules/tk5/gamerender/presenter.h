// Stock TK5 presenter (gamerender.wasm): the parts its frame calls, each reading the sim view.
#ifndef T5_PRESENTER_H
#define T5_PRESENTER_H

#include <stdbool.h>
#include "openwavu.h"
#include "pack_file.h"
#include "view.h"

static const float MM = 0.001f;  // sim units to scene metres

// The fighters' costume parts and hand banks, and the stage, by asset id; false when the db does not open.
bool t5_scene_init(const T5View *view);
// The whole scene of this frame, `seconds` after the last.
void t5_scene_send(const T5View *view, float seconds);
// A voice of `side` started with this voice row face: the fighter's face plays it.
void t5_scene_voice_face(const T5View *view, int side, uint16_t voice_face);
typedef struct sqlite3 sqlite3;
// The ow_asset id of a pack path; 0 for none.
uint32_t t5_asset_of(const unsigned char *path);
// The stage's glb, and its floor tiles when it is infinite.
void t5_stage_init(sqlite3 *db, const T5View *view);
// The stage nodes of this frame, at most max; returns how many. midpoint: the fighters', metres.
uint32_t t5_stage_nodes(const T5View *view, OwCamera camera, float midpoint_x, float midpoint_z, OwNode *nodes, uint32_t max);
// The throw a hand-coded shot shows: it eases out once the thrower passes `release` in `move` or leaves it.
typedef struct {
    int thrower;
    int16_t move, release;  // release 0: the move's end
} T5CodedThrow;
// A hand-coded throw shot (camera ids below 0x67, coded_camera.c); mm.
typedef struct {
    T5CodedThrow throw_move;
    int id;
    bool thrower_right, wide, walled_stage, cut_in;  // cut_in: full weight at once
    uint32_t set_up_frame;   // sim frame it shows from
    uint32_t stepped_frame;  // the last sim frame stepped; 0: not set up yet
    int32_t easing_out;      // frames since the throw ended
    float fov, distance_scale;
    T5Vec3 eye, target;
    T5Vec3 line_point, line_direction;  // thrower to victim when it was set up
} T5CodedShot;
// A shot of the throw that sets its camera on sim `frame`.
void t5_coded_shot_start(T5CodedShot *shot, T5CodedThrow throw_move, int id, bool thrower_right, bool wide, bool hold,
                         bool walled_stage, uint32_t frame);
// This frame's shot and its weight, 0 to 1: how far it pulls the camera on screen (`shown`) a sim frame; 0: not shown.
float t5_coded_shot(T5CodedShot *shot, const T5View *view, OwCamera shown, OwCamera *camera);
// The throw camera rows, the global camera bank and whether the view's stage has walls.
void t5_camera_init(sqlite3 *db, const T5View *view);
// The camera shots and throw moves of a side's moves, from the db character whose move set it runs.
void t5_camera_load(sqlite3 *db, int side, const char *character, T5FileSet *files);
// A move's or a throw's camera shot while it plays, else the fight camera: behind the line between the fighters,
// eased over the `seconds` since the last frame. Sends each fighter's screen side to the host.
OwCamera t5_camera(const T5View *view, float seconds);
// The shared effect files and each fighter's own, with its hit table, by asset id.
void t5_effects_init(sqlite3 *db, const T5View *view);
// The effects of the view's cues, at most max; returns how many.
uint32_t t5_effects(const T5View *view, OwFx *entries, uint32_t max);
// The sounds of the fighters, the stage and the announcer, the stage's track, and the sound channels.
void t5_sound_init(sqlite3 *db, const T5View *view);
// The new sound, voice, announcer and music cues of the view; keeps the music fed.
void t5_sound_play(const T5View *view, float seconds);
// Health, timer, round marks and the phase banners, in SDL 2D.
void t5_hud_draw(const T5View *view);

#endif
