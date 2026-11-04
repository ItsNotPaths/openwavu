// Stock TK5 presenter (gamerender.wasm): the fight camera and the camera shots of moves. Per viewer, outside rollback. The
// camera and the timeline player are SDK libraries; TK5 gives params and data.
#include <math.h>
#include <stddef.h>

#include "gamerender/presenter.h"
#include "pack_file.h"
#include "sim/anim.h"
#include "sqlite3.h"

// (hole sdk-camera :tags (sdk tk5mod round-show) :sev gap) no general fight camera in the SDK (frames both fighters, keeps the side line, zoom and lag by params), and no TK5 params for it.
// (hole move-cameras :tags (tk5mod round-show) :needs (camera-side-re coded-cameras cue-ring)) throw cameras are not played: tracks placed at the thrown fighter, side switches.
// (hole coded-cameras :tags (port round-show)) the hand-coded throw and hit cameras (ids below 0x67, 0x7b22c) are not ported.
// (hole sdk-timeline :tags (sdk tk5mod round-show) :needs (sdk-camera intro-timelines cue-ring)) the shot player is pack code, not an SDK library, and plays only cameras: no effects, sounds or voices on the intro and win timelines.

static const float DISTANCE = 3.6f;      // metres from the midpoint, along the view normal
static const float FOCUS_HEIGHT = 0.9f;  // metres
static const float RAISE = 0.5f;         // the camera sits this much above the focus
static const float FOV = 0.698132f;      // 40 degrees, vertical
static const float TURN = 6.2831853f / 65536.0f;  // radians per facing unit

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

// The tk5decomp demo's follow camera: fixed distance, no zoom or lag.
static OwCamera fight_camera(const T5View *view) {
    const T5Mat4 *first = &view->fighters[0].rig.root.world, *second = &view->fighters[1].rig.root.world;
    OwVec3 focus = {
        (first->m[3][0] + second->m[3][0]) * 0.5f * MM,
        FOCUS_HEIGHT,
        (first->m[3][2] + second->m[3][2]) * 0.5f * MM,
    };
    OwVec3 position = {focus.x + view->view_normal[0] * DISTANCE, focus.y + RAISE, focus.z + view->view_normal[1] * DISTANCE};
    return (OwCamera){.position = position, .target = focus, .fov = FOV};
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

// The newest shot of the two fighters (the game's later shot replaces the earlier), else the fight camera.
OwCamera t5_camera(const T5View *view) {
    const CameraKey *key = NULL;
    int shot_side = -1;
    int32_t newest = INT32_MAX;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        int32_t elapsed;
        const CameraKey *found = shot_key(&view->fighters[side], &elapsed);
        if (found && elapsed < newest) key = found, shot_side = side, newest = elapsed;
    }
    if (!key) return fight_camera(view);
    const T5ViewFighter *fighter = &view->fighters[shot_side];
    uint32_t start_frame = view->frame - (uint32_t)newest;
    if (anchor.side != shot_side || anchor.move != fighter->move.index || anchor.start_frame != start_frame)
        anchor = (Anchor){shot_side, fighter->move.index, start_frame, fighter->position, fighter->facing};
    return (OwCamera){.position = placed((*key)[0]), .target = placed((*key)[1]), .fov = (*key)[2][0], .roll = (*key)[2][1]};
}
