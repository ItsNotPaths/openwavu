// Stock TK6 presenter (gamerender.wasm): the parts its frame calls, each reading the sim view.
#ifndef T6_PRESENTER_H
#define T6_PRESENTER_H

#include <stdbool.h>
#include "openwavu.h"
#include "pack_file.h"
#include "view.h"

static const float MM = 0.001f;  // sim units to scene metres

// The fighters' costume parts and hand banks, and the stage, by asset id; false when the db does not open.
bool t6_scene_init(const T6View *view);
// The whole scene of this frame, `seconds` after the last.
void t6_scene_send(const T6View *view, float seconds);
// A voice of `side` started with this voice row face: the fighter's face plays it.
void t6_scene_voice_face(const T6View *view, int side, uint16_t voice_face);
typedef struct sqlite3 sqlite3;
// The ow_asset id of a pack path; 0 for none.
uint32_t t6_asset_of(const unsigned char *path);
// The stage's glb, and its floor tiles when it is infinite.
void t6_stage_init(sqlite3 *db, const T6View *view);
// The stage nodes of this frame, at most max; returns how many. midpoint: the fighters', metres.
uint32_t t6_stage_nodes(const T6View *view, OwCamera camera, float midpoint_x, float midpoint_z, OwNode *nodes, uint32_t max);
// A throw's camera shot drawn from a throw_shot row (degrees).
typedef struct {
    float yaw, pitch, fov;  // yaw off the fight camera's bearing; pitch from level
    float distance_scale;   // times the fight camera's distance
    bool cut_in;            // else it eases in
} T6ThrowShotPlan;
// A throw's camera shot while it plays (throw_shot.c); mm, radians.
typedef struct {
    int thrower;             // -1: none
    T6ThrowShotPlan plan;
    uint32_t stepped_frame;  // the last sim frame stepped
    int32_t age;             // sim frames since the draw
    int32_t letting_go;      // sim frames since the throw let go; 0: holding
    uint16_t thrower_moves;  // the thrower's throw moves at the draw
    float yaw, pitch, distance;
    T6Vec3 eye, target;
    T6Vec3 line_point, line_direction;  // thrower to victim when it was set up
} T6ThrowShot;
void t6_throw_shot_start(T6ThrowShot *shot, int thrower, T6ThrowShotPlan plan, uint16_t thrower_moves);
// This frame's shot and its weight, 0 to 1, over the fight camera; 0: not shown. `fight`: the fight camera.
// `releases_ahead`: a fighter of the throw still has a release property ahead in its move.
float t6_throw_shot(T6ThrowShot *shot, const T6View *view, OwCamera fight, bool releases_ahead, OwCamera *camera);
// The hit zoom rows.
void t6_camera_init(sqlite3 *db);
// The camera shots, throw shot lists and release frames of a side's moves, from the db character whose move set it runs.
void t6_camera_load(sqlite3 *db, int side, const char *character, T6FileSet *files);
// A move's or a throw's camera shot or a hit zoom while it plays, else the fight camera: behind the line between the fighters,
// eased over the `seconds` since the last frame. Sends each fighter's screen side to the host.
OwCamera t6_camera(const T6View *view, float seconds);
// The shared effect files and each fighter's own, with its hit table, by asset id.
void t6_effects_init(sqlite3 *db, const T6View *view);
// The effects of the view's cues, at most max; returns how many.
uint32_t t6_effects(const T6View *view, OwFx *entries, uint32_t max);
// The sounds of the fighters, the stage and the announcer, the stage's track, and the sound channels.
void t6_sound_init(sqlite3 *db, const T6View *view);
// The new sound, voice, announcer and music cues of the view; keeps the music fed.
void t6_sound_play(const T6View *view, float seconds);
// Health, timer, round marks and the phase banners, in SDL 2D.
void t6_hud_draw(const T6View *view);

#endif
