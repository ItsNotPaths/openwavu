// Stock TK5 presenter (gamerender.wasm): the fight camera and the camera shots of moves. Per viewer, outside rollback. The
// camera and the timeline player are SDK libraries; TK5 gives params and data.
#include <SDL3/SDL.h>
#include <math.h>
#include <stddef.h>

#include "gamerender/presenter.h"
#include "pack_file.h"
#include "sim/anim.h"
#include "sqlite3.h"

// (hole sdk-camera :tags (sdk tk5mod round-show) :sev gap) the fight camera is the demo's follow camera, eased, in pack code: no SDK camera that frames both fighters by params (distance, zoom, lag), and the game's rules (0x772cc) are not ported.
// (hole move-cameras :tags (tk5mod round-show) :needs (sim-side-switch coded-cameras)) throw cameras are not played (tracks placed at the thrown fighter); the db has no camera category per move (property 0x815f) to pick them from the view, as intro shots are.
// (hole coded-cameras :tags (port round-show)) the hand-coded throw and hit cameras (ids below 0x67, 0x7b22c) are not ported.
// (hole sdk-timeline :tags (sdk tk5mod round-show) :needs (sdk-camera intro-timelines)) the shot player is pack code, not an SDK library, and plays only cameras: no effects, sounds or voices on the intro and win timelines.

static const float DISTANCE = 3.6f;      // metres from the midpoint, along the view normal; the closest it gets
static const float FIGHTER_ROOM = 1.2f;  // metres kept on screen past the two fighters' roots, both sides together
static const float FOCUS_HEIGHT = 0.9f;  // metres
static const float RAISE = 0.5f;         // the camera sits this much above the focus
static const float FOV = 0.698132f;      // 40 degrees, vertical
static const float TURN = 6.2831853f / 65536.0f;  // radians per facing unit
static const float FOLLOW_RATE = 8.0f;  // per second: how fast the fight camera closes on where it should be

enum { SHOTS_MAX = 32, CAMERA_CHANNELS = 3 };  // per side; channels: eye, target, lens (fov, roll, smoothing)

typedef float CameraKey[CAMERA_CHANNELS][3];

typedef struct {
    int16_t move;   // index in the side's move set
    int16_t frame;  // move frame of the first key
    uint16_t frame_count;
    const CameraKey *keys;
} Shot;

static Shot shots[T5_FIGHTER_COUNT][SHOTS_MAX];
static int shot_count[T5_FIGHTER_COUNT];

static T5KeyKind camera_channel_kind(int32_t channel) { return channel < 2 ? T5_KEY_POSITION : T5_KEY_VALUES; }

// Moves are numbered in sheet order, as the sim's loader lays them out.
static void load_shots(sqlite3 *db, int side, const char *character) {
    sqlite3_stmt *rows;
    const char *query = "SELECT move.number, move_camera.frame, anim.file FROM "
                        "(SELECT key, row_number() OVER (ORDER BY rowid) - 1 AS number FROM move WHERE character = ?1) AS move "
                        "JOIN move_camera ON move_camera.move = move.key "
                        "JOIN anim ON anim.character = move_camera.tracks AND anim.idx = move_camera.track";
    if (sqlite3_prepare_v2(db, query, -1, &rows, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(rows, 1, character, -1, SQLITE_STATIC);
    while (shot_count[side] < SHOTS_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        const float *keys;
        T5Bytes file = t5_read_pack_file(NULL, (const char *)sqlite3_column_text(rows, 2));
        uint16_t frames = t5_anim_file(file, "camera", CAMERA_CHANNELS, camera_channel_kind, &keys);
        if (!frames) continue;
        shots[side][shot_count[side]++] = (Shot){
            (int16_t)sqlite3_column_int(rows, 0), (int16_t)sqlite3_column_int(rows, 1), frames, (const CameraKey *)keys};
    }
    sqlite3_finalize(rows);
}

void t5_camera_init(sqlite3 *db, const T5View *view) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) load_shots(db, side, view->fighters[side].loadout.character);
}

static float screen_aspect(void) {
    int pixels_wide = 0, pixels_high = 0;
    SDL_GetRenderOutputSize(ow_renderer(), &pixels_wide, &pixels_high);
    return pixels_high > 0 ? (float)pixels_wide / (float)pixels_high : 16.0f / 9.0f;
}

// The tk5decomp demo's follow camera, pulled back when the fighters stand wider apart than it shows.
static OwCamera fight_camera(const T5View *view) {
    const T5Mat4 *first = &view->fighters[0].rig.root.world, *second = &view->fighters[1].rig.root.world;
    OwVec3 focus = {
        (first->m[3][0] + second->m[3][0]) * 0.5f * MM,
        FOCUS_HEIGHT,
        (first->m[3][2] + second->m[3][2]) * 0.5f * MM,
    };
    float right[2] = {view->view_normal[1], -view->view_normal[0]};  // screen right on the floor
    float across = fabsf(((second->m[3][0] - first->m[3][0]) * right[0] + (second->m[3][2] - first->m[3][2]) * right[1]) * MM);
    float shown_per_metre = 2.0f * tanf(FOV / 2) * screen_aspect();  // screen width at one metre away
    float distance = fmaxf(DISTANCE, (across + FIGHTER_ROOM) / shown_per_metre);
    OwVec3 position = {focus.x + view->view_normal[0] * distance, focus.y + RAISE, focus.z + view->view_normal[1] * distance};
    return (OwCamera){.position = position, .target = focus, .fov = FOV};
}

static struct {
    bool live;  // false: the next fight camera cuts in
    OwCamera camera;
} follow;

static OwVec3 eased(OwVec3 from, OwVec3 to, float weight) {
    return (OwVec3){from.x + (to.x - from.x) * weight, from.y + (to.y - from.y) * weight, from.z + (to.z - from.z) * weight};
}

// The fight camera eased toward `goal` over `seconds`, the same at any display rate.
static OwCamera followed(OwCamera goal, float seconds) {
    if (!follow.live) {
        follow.live = true;
        return follow.camera = goal;
    }
    float weight = 1.0f - expf(-FOLLOW_RATE * seconds);
    OwCamera *camera = &follow.camera;
    camera->position = eased(camera->position, goal.position, weight);
    camera->target = eased(camera->target, goal.target, weight);
    camera->fov += (goal.fov - camera->fov) * weight;
    return *camera;
}

// The key of the fighter's shot at its move frame; NULL when its move has no shot or the shot is over.
static const CameraKey *shot_key(const T5ViewFighter *fighter, int32_t *elapsed) {
    int set = fighter->move.set;
    if (fighter->move.index < 0 || set >= T5_FIGHTER_COUNT) return NULL;
    for (int at = 0; at < shot_count[set]; at++) {
        const Shot *shot = &shots[set][at];
        *elapsed = fighter->move_frame - shot->frame;
        if (shot->move == fighter->move.index) return *elapsed >= 0 && *elapsed < shot->frame_count ? &shot->keys[*elapsed] : NULL;
    }
    return NULL;
}

// Where a shot is placed: the fighter's position and facing on the shot's first frame, as the game keeps them.
typedef struct {
    int side;
    int16_t move;
    uint32_t start_frame;  // sim frame of the shot's first key
    T5Vec3 position;
    int16_t facing;
} Anchor;

static Anchor anchor = {.side = -1};

// (hole shot-height-ease :tags (tk5mod round-show) :sev polish) a shot's anchor height is set once; the game eases it toward the fighter's height (0x7d4c4), so a jump or crouch in a pose does not move the camera.
// A track point in the anchor's frame, in the world: turned by -facing about y, then moved to the anchor.
static OwVec3 placed(const float local[3]) {
    float angle = -anchor.facing * TURN, cosine = cosf(angle), sine = sinf(angle);
    T5Vec3 at = anchor.position;
    return (OwVec3){
        (at.x + cosine * local[0] - sine * local[2]) * MM,
        (at.y + local[1]) * MM,
        (at.z + sine * local[0] + cosine * local[2]) * MM,
    };
}

// The newest shot of the two fighters (the game's later shot replaces the earlier), else the fight camera. Shots and
// scene cuts are not eased.
OwCamera t5_camera(const T5View *view, float seconds) {
    const CameraKey *key = NULL;
    int shot_side = -1;
    int32_t newest = INT32_MAX;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        int32_t elapsed;
        const CameraKey *found = shot_key(&view->fighters[side], &elapsed);
        if (found && elapsed < newest) key = found, shot_side = side, newest = elapsed;
    }
    if (!key) {
        if (view->snap) follow.live = false;
        return followed(fight_camera(view), seconds);
    }
    follow.live = false;
    const T5ViewFighter *fighter = &view->fighters[shot_side];
    uint32_t start_frame = view->frame - (uint32_t)newest;
    if (anchor.side != shot_side || anchor.move != fighter->move.index || anchor.start_frame != start_frame)
        anchor = (Anchor){shot_side, fighter->move.index, start_frame, fighter->position, fighter->facing};
    return (OwCamera){.position = placed((*key)[0]), .target = placed((*key)[1]), .fov = (*key)[2][0], .roll = (*key)[2][1]};
}
