// Stock TK5 presenter (gamerender.wasm): the fight camera and the camera shots of moves and throws. Per viewer, outside
// rollback. The camera and the timeline player are SDK libraries; TK5 gives params and data.
#include <SDL3/SDL.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>

#include "gamerender/presenter.h"
#include "pack_file.h"
#include "sim/anim.h"
#include "sqlite3.h"

// (hole sdk-camera :tags (sdk tk5mod round-show) :sev gap) the fight camera is the demo's follow camera, eased, in pack code: no SDK camera that frames both fighters by params (distance, zoom, lag), and the game's rules (0x772cc) are not ported. tekken 6 as well modules/tk6/gamerender/camera.c
// (hole throw-camera-gaps :tags (tk5mod round-show) :sev polish) a track is not low-passed (0x7f970, 0.1 a frame) and does not ease in over its first 60 frames; aim_at_fighters aims at the fighters' middle (0x7a5a4 not used); a hand-coded shot does not end at a chain throw's next step. tekken 6 as well modules/tk6/gamerender/camera.c
// (hole sdk-timeline :tags (sdk tk5mod round-show) :needs (sdk-camera intro-timelines)) the shot player is pack code, not an SDK library, and plays only cameras: no effects, sounds or voices on the intro and win timelines. tekken 6 as well modules/tk6/gamerender/camera.c

static const float DISTANCE = 3.6f;      // metres from the midpoint, along the view normal; the closest it gets
static const float FIGHTER_ROOM = 1.2f;  // metres kept on screen past the two fighters' roots, both sides together
static const float FOCUS_HEIGHT = 0.9f;  // metres
static const float RAISE = 0.5f;         // the camera sits this much above the focus
static const float FOV = 0.698132f;      // 40 degrees, vertical
static const float TURN = 6.2831853f / 65536.0f;  // radians per yaw unit
static const float FOLLOW_RATE = 8.0f;  // per second: how fast the fight camera closes on where it should be

enum { SHOTS_MAX = 32, THROW_MOVES_MAX = 96, THROW_CAMERAS_MAX = 1024, CLIPS_MAX = 512 };  // shots, throw moves: per side
enum { CAMERA_CHANNELS = 3 };  // eye, target, lens (fov, roll, smoothing)

typedef float CameraKey[CAMERA_CHANNELS][3];

typedef struct {
    uint16_t frame_count;
    const CameraKey *keys;
} Clip;

typedef struct {
    int16_t move;   // index in the side's move set
    int16_t frame;  // move frame of the first key
    Clip clip;
} Shot;

// A thrower's move with a camera category (property 0x815f) that has throw_camera rows.
typedef struct {
    int16_t move;     // index in the side's move set
    int16_t frame;    // move frame the category is set on
    int16_t release;  // move frame a hand-coded shot starts to ease out (properties 0x803b..0x8041); 0: the move's end
    int32_t category;
} ThrowMove;

typedef struct {
    int32_t category, weight;
    int16_t camera[T5_FIGHTER_COUNT];  // the game's camera id by the thrower's screen side, left then right
    bool hold, wide;                   // hold: no wait before a coded shot
    bool mirror_x, mirror_z;           // only with the thrower on the right
    bool aim_at_fighters;
    bool wall_check;
} ThrowCamera;

static Shot shots[T5_FIGHTER_COUNT][SHOTS_MAX];
static int shot_count[T5_FIGHTER_COUNT];
static ThrowMove throw_moves[T5_FIGHTER_COUNT][THROW_MOVES_MAX];
static int throw_move_count[T5_FIGHTER_COUNT];
static ThrowCamera throw_cameras[THROW_CAMERAS_MAX];  // by category, then pos
static int throw_camera_count;
static Clip clips[CLIPS_MAX];  // the global bank
static T5FileSet clip_files;
static bool walled_stage;

static T5KeyKind camera_channel_kind(int32_t channel) { return channel < 2 ? T5_KEY_POSITION : T5_KEY_VALUES; }

// No frames: the file is not a camera track.
static Clip clip_of(T5FileSet *files, const unsigned char *path) {
    const float *keys;
    uint16_t frames = t5_anim_file(t5_read_set_file(files, (const char *)path), "camera", CAMERA_CHANNELS, camera_channel_kind, &keys);
    return (Clip){frames, (const CameraKey *)keys};
}

// Moves are numbered in sheet order, as the sim's loader lays them out.
#define MOVES_IN_SHEET_ORDER \
    "(SELECT key, extra_props, row_number() OVER (ORDER BY rowid) - 1 AS number FROM move WHERE character = ?1) AS move "

static void load_shots(sqlite3 *db, int side, const char *character, T5FileSet *files) {
    shot_count[side] = 0;
    sqlite3_stmt *rows;
    const char *query = "SELECT move.number, move_camera.frame, anim.file FROM " MOVES_IN_SHEET_ORDER
                        "JOIN move_camera ON move_camera.move = move.key "
                        "JOIN anim ON anim.character = move_camera.tracks AND anim.idx = move_camera.track";
    if (sqlite3_prepare_v2(db, query, -1, &rows, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(rows, 1, character, -1, SQLITE_STATIC);
    while (shot_count[side] < SHOTS_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        Clip clip = clip_of(files, sqlite3_column_text(rows, 2));
        if (clip.frame_count)
            shots[side][shot_count[side]++] = (Shot){(int16_t)sqlite3_column_int(rows, 0), (int16_t)sqlite3_column_int(rows, 1), clip};
    }
    sqlite3_finalize(rows);
}

static void load_throw_moves(sqlite3 *db, int side, const char *character) {
    throw_move_count[side] = 0;
    sqlite3_stmt *rows;
    const char *query = "SELECT move.number, extra_prop.\"when\" & 0x7fff, extra_prop.value, "
                        "(SELECT min(release.\"when\" & 0x7fff) FROM extra_prop AS release "
                        "WHERE release.list = move.extra_props AND release.id BETWEEN 0x803b AND 0x8041) FROM " MOVES_IN_SHEET_ORDER
                        "JOIN extra_prop ON extra_prop.list = move.extra_props AND extra_prop.id = 0x815f "
                        "WHERE extra_prop.value IN (SELECT category FROM throw_camera)";
    if (sqlite3_prepare_v2(db, query, -1, &rows, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(rows, 1, character, -1, SQLITE_STATIC);
    while (throw_move_count[side] < THROW_MOVES_MAX && sqlite3_step(rows) == SQLITE_ROW)
        throw_moves[side][throw_move_count[side]++] = (ThrowMove){
            (int16_t)sqlite3_column_int(rows, 0), (int16_t)sqlite3_column_int(rows, 1), (int16_t)sqlite3_column_int(rows, 3),
            sqlite3_column_int(rows, 2)};
    sqlite3_finalize(rows);
}

void t5_camera_load(sqlite3 *db, int side, const char *character, T5FileSet *files) {
    load_shots(db, side, character, files);
    load_throw_moves(db, side, character);
}

void t5_camera_init(sqlite3 *db, const T5View *view) {
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT radius = 0 FROM stage WHERE id = ?1", -1, &rows, NULL) == SQLITE_OK) {
        sqlite3_bind_text(rows, 1, view->stage, -1, SQLITE_STATIC);
        walled_stage = sqlite3_step(rows) == SQLITE_ROW && sqlite3_column_int(rows, 0) != 0;
        sqlite3_finalize(rows);
    }
    if (sqlite3_prepare_v2(db, "SELECT idx, file FROM anim WHERE character = 'cameras'", -1, &rows, NULL) == SQLITE_OK) {
        while (sqlite3_step(rows) == SQLITE_ROW) {
            int index = sqlite3_column_int(rows, 0);
            if (index >= 0 && index < CLIPS_MAX) clips[index] = clip_of(&clip_files, sqlite3_column_text(rows, 1));
        }
        sqlite3_finalize(rows);
    }
    const char *query = "SELECT category, weight, coalesce(left_track + 0x67, left_coded), coalesce(right_track + 0x67, right_coded), hold, wide, "
                        "mirror_x, mirror_z, aim_at_fighters AND NOT track_target, wall_check "
                        "FROM throw_camera ORDER BY category, pos";
    if (sqlite3_prepare_v2(db, query, -1, &rows, NULL) != SQLITE_OK) return;
    while (throw_camera_count < THROW_CAMERAS_MAX && sqlite3_step(rows) == SQLITE_ROW)
        throw_cameras[throw_camera_count++] = (ThrowCamera){
            sqlite3_column_int(rows, 0), sqlite3_column_int(rows, 1), {(int16_t)sqlite3_column_int(rows, 2), (int16_t)sqlite3_column_int(rows, 3)},
            sqlite3_column_int(rows, 4) != 0, sqlite3_column_int(rows, 5) != 0, sqlite3_column_int(rows, 6) != 0,
            sqlite3_column_int(rows, 7) != 0, sqlite3_column_int(rows, 8) != 0, sqlite3_column_int(rows, 9) != 0};
    sqlite3_finalize(rows);
}

// xz direction from the fighters to the camera; screen sides follow it. On -x: side 1, at -z, is on the left.
static float view_normal[2] = {-1, 0};
static bool on_right[T5_FIGHTER_COUNT];  // as last sent to the host

// The camera's side of the line between the fighters. A shot keeps the side its eye is on, `shot_side` (xz, mm): the
// game measures the screen sides through whatever camera is on screen, and the fight camera keeps them after the shot
// (0x772cc), which is how some throws swap the screen sides. Else a fighter changes screen side only by crossing over,
// and a scene cut (a round start) takes a fresh side, with side 1 on the left. Each side goes to the host for its pad.
static void update_sides(const T5View *view, const float *shot_side) {
    const T5Mat4 *first = &view->fighters[0].rig.root.world, *second = &view->fighters[1].rig.root.world;
    float dx = second->m[3][0] - first->m[3][0], dz = second->m[3][2] - first->m[3][2], length = sqrtf(dx * dx + dz * dz);
    if (length > 1) {
        float normal_x = -dz / length, normal_z = dx / length;
        float kept_x = view_normal[0], kept_z = view_normal[1];
        if (shot_side) kept_x = shot_side[0], kept_z = shot_side[1];
        if ((shot_side || !view->snap) && normal_x * kept_x + normal_z * kept_z < 0) normal_x = -normal_x, normal_z = -normal_z;
        view_normal[0] = normal_x;
        view_normal[1] = normal_z;
    }
    float right[2] = {view_normal[1], -view_normal[0]};  // screen right on the floor
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        const T5Mat4 *me = &view->fighters[side].rig.root.world, *other = &view->fighters[1 - side].rig.root.world;
        float along = (me->m[3][0] - other->m[3][0]) * right[0] + (me->m[3][2] - other->m[3][2]) * right[1];
        on_right[side] = along > 0 || (along == 0 && side == 1);
        ow_pad_on_right((uint32_t)side, on_right[side]);
    }
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
    float right[2] = {view_normal[1], -view_normal[0]};  // screen right on the floor
    float across = fabsf(((second->m[3][0] - first->m[3][0]) * right[0] + (second->m[3][2] - first->m[3][2]) * right[1]) * MM);
    float shown_per_metre = 2.0f * tanf(FOV / 2) * screen_aspect();  // screen width at one metre away
    float distance = fmaxf(DISTANCE, (across + FIGHTER_ROOM) / shown_per_metre);
    OwVec3 position = {focus.x + view_normal[0] * distance, focus.y + RAISE, focus.z + view_normal[1] * distance};
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

// Where a track is placed: a fighter's position and move yaw.
typedef struct {
    T5Vec3 position;
    int16_t yaw;
} Anchor;

// (hole shot-height-ease :tags (tk5mod round-show) :sev polish) a shot's anchor height is set once; the game eases it toward the fighter's height (0x7d4c4), so a jump or crouch in a pose does not move the camera. tekken 6 as well modules/tk6/gamerender/camera.c:placed
// A track point in the anchor's frame, in the world: turned by -yaw about y, then moved to the anchor.
static OwVec3 placed(Anchor anchor, const float local[3], bool mirror_x, bool mirror_z) {
    float x = mirror_x ? -local[0] : local[0], z = mirror_z ? -local[2] : local[2];
    float angle = -anchor.yaw * TURN, cosine = cosf(angle), sine = sinf(angle);
    T5Vec3 at = anchor.position;
    return (OwVec3){
        (at.x + cosine * x - sine * z) * MM,
        (at.y + local[1]) * MM,
        (at.z + sine * x + cosine * z) * MM,
    };
}

static OwCamera keyed(Anchor anchor, const CameraKey *key, bool mirror_x, bool mirror_z) {
    return (OwCamera){
        .position = placed(anchor, (*key)[0], mirror_x, mirror_z),
        .target = placed(anchor, (*key)[1], mirror_x, mirror_z),
        .fov = (*key)[2][0],
        .roll = (*key)[2][1],
    };
}

// The key of the fighter's shot at its move frame; NULL when its move has no shot or the shot is over.
static const CameraKey *shot_key(const T5ViewFighter *fighter, int32_t *elapsed) {
    int set = fighter->move.set;
    if (fighter->move.index < 0 || set >= T5_FIGHTER_COUNT) return NULL;
    for (int at = 0; at < shot_count[set]; at++) {
        const Shot *shot = &shots[set][at];
        *elapsed = fighter->move_frame - shot->frame;
        if (shot->move == fighter->move.index)
            return *elapsed >= 0 && *elapsed < shot->clip.frame_count ? &shot->clip.keys[*elapsed] : NULL;
    }
    return NULL;
}

// The move shot playing: placed where its fighter stood on its first frame, as the game keeps it.
static struct {
    int side;
    int16_t move;
    uint32_t start_frame;  // sim frame of the shot's first key
    Anchor anchor;
} move_shot = {.side = -1};

// The newest move shot of the two fighters (the game's later shot replaces the earlier).
static bool move_shot_camera(const T5View *view, OwCamera *camera) {
    const CameraKey *key = NULL;
    int shot_side = -1;
    int32_t newest = INT32_MAX;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        int32_t elapsed;
        const CameraKey *found = shot_key(&view->fighters[side], &elapsed);
        if (found && elapsed < newest) key = found, shot_side = side, newest = elapsed;
    }
    if (!key) return false;
    const T5ViewFighter *fighter = &view->fighters[shot_side];
    uint32_t start_frame = view->frame - (uint32_t)newest;
    if (move_shot.side != shot_side || move_shot.move != fighter->move.index || move_shot.start_frame != start_frame)
        move_shot = (typeof(move_shot)){shot_side, fighter->move.index, start_frame, {fighter->position, fighter->move_yaw}};
    *camera = keyed(move_shot.anchor, key, false, false);
    return true;
}

// A row of the category by weight, as the game draws it (libc rand, not the sim's). A wall-checked row needs the camera
// over a list 3 floor and it and the fighters off list 2 (0x796d0): no stage has those lists, so on a walled stage it is
// always row 0. Infinite stages skip the check (stage mode word 0x70e3c).
static const ThrowCamera *pick_throw_camera(int32_t category) {
    int first = 0, total = 0;
    while (first < throw_camera_count && throw_cameras[first].category != category) first++;
    int end = first;
    for (; end < throw_camera_count && throw_cameras[end].category == category; end++) total += throw_cameras[end].weight;
    if (first == end) return NULL;
    int draw = total > 0 ? rand() % total : 0;
    const ThrowCamera *row = &throw_cameras[first];
    for (int at = first; at < end; at++) {
        draw -= throw_cameras[at].weight;
        if (draw < 0) {
            row = &throw_cameras[at];
            break;
        }
    }
    return row->wall_check && walled_stage ? &throw_cameras[first] : row;
}

enum { CODED_CAMERAS = 0x67, WIDER_CODED = 0x66, INFINITE_CODED = 2 };  // ids below CODED_CAMERAS are hand-coded shots

// The throw shot: picked once per throw. A track plays for its length whatever the moves do, following the thrown
// fighter on the floor while they are in the throw, then staying (0x7f970). A hand-coded shot runs until the throw ends.
static struct {
    int thrower;  // -1: none yet
    int16_t move;
    uint32_t start_frame;  // sim frame of the shot's first key
    const Clip *clip;      // NULL: a coded shot
    bool mirror_x, mirror_z, aim_at_fighters;
    Anchor anchor;
    T5CodedShot coded;
    T5Vec3 line_point, line_direction;  // the throw's line, still while the fighters' roots shift as they grapple
} throw_shot = {.thrower = -1};

// A throw starts its shot on the frame its thrower's move sets the camera category. On an infinite stage every shot is
// hand-coded id 2 (0x66 stays, 0x7899c in 0x7e454), so no throw switches sides there.
static void start_throw_shot(const T5View *view) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        const T5ViewFighter *thrower = &view->fighters[side];
        int set = thrower->move.set;
        if (thrower->throw_role != THROW_ROLE_THROWER || set >= T5_FIGHTER_COUNT) continue;
        for (int at = 0; at < throw_move_count[set]; at++) {
            const ThrowMove *throw_move = &throw_moves[set][at];
            if (throw_move->move != thrower->move.index || thrower->move_frame < throw_move->frame) continue;
            uint32_t start_frame = view->frame - (uint32_t)(thrower->move_frame - throw_move->frame);
            if (throw_shot.thrower == side && throw_shot.move == throw_move->move && throw_shot.start_frame == start_frame) return;
            const ThrowCamera *row = pick_throw_camera(throw_move->category);
            if (!row) return;
            bool right = on_right[side];
            int id = row->camera[right];
            if (!walled_stage) id = id == WIDER_CODED ? WIDER_CODED : INFINITE_CODED;
            int clip = id - CODED_CAMERAS;
            bool tracked = clip >= 0 && clip < CLIPS_MAX && clips[clip].frame_count;
            const T5ViewFighter *thrown = &view->fighters[1 - side];
            throw_shot = (typeof(throw_shot)){side, throw_move->move, start_frame, tracked ? &clips[clip] : NULL,
                                              tracked && right && row->mirror_x, tracked && right && row->mirror_z,
                                              tracked && row->aim_at_fighters, {thrown->position, thrown->move_yaw}};
            if (!tracked)
                t5_coded_shot_start(&throw_shot.coded, (T5CodedThrow){side, throw_move->move, throw_move->release}, id, right, row->wide,
                                    row->hold, walled_stage, start_frame);
            return;
        }
    }
}

// This frame's throw shot and its weight: how far it pulls the camera on screen a sim frame (0x7a97c); 0: none. A
// track's weight is its smoothing channel, 0 on its first frames and falling to 0 at its end.
static float throw_shot_camera(const T5View *view, OwCamera *camera) {
    start_throw_shot(view);
    if (throw_shot.thrower < 0) return 0;
    if (!throw_shot.clip) {
        float weight = t5_coded_shot(&throw_shot.coded, view, follow.camera, camera);
        throw_shot.line_point = throw_shot.coded.line_point;
        throw_shot.line_direction = throw_shot.coded.line_direction;
        return weight;
    }
    int32_t elapsed = (int32_t)(view->frame - throw_shot.start_frame);
    if (elapsed < 0 || elapsed >= throw_shot.clip->frame_count) return 0;
    const T5ViewFighter *thrown = &view->fighters[1 - throw_shot.thrower];
    if (thrown->throw_role == THROW_ROLE_THROWN) {
        throw_shot.anchor.position.x = thrown->position.x;
        throw_shot.anchor.position.z = thrown->position.z;
        throw_shot.anchor.yaw = thrown->move_yaw;
    }
    const CameraKey *key = &throw_shot.clip->keys[elapsed];
    float angle = -throw_shot.anchor.yaw * TURN;
    throw_shot.line_point = throw_shot.anchor.position;
    throw_shot.line_direction = (T5Vec3){-sinf(angle), 0, cosf(angle)};  // the anchor's facing: local +z
    *camera = keyed(throw_shot.anchor, key, throw_shot.mirror_x, throw_shot.mirror_z);
    if (throw_shot.aim_at_fighters) {
        const T5Vec3 *first = &view->fighters[0].position, *second = &view->fighters[1].position;
        camera->target.x = (first->x + second->x) * 0.5f * MM;
        camera->target.z = (first->z + second->z) * 0.5f * MM;
    }
    return (*key)[2][2];
}

static uint32_t shown_frame;  // the sim frame the camera on screen was last pulled on

// The camera on screen pulled toward a throw shot by `weight` for each sim frame since the last pull (0x7a97c). As a
// shot's weight falls the camera stays where the shot left it, and the fight camera eases on from there.
static OwCamera shown_toward(OwCamera shot, float weight, uint32_t frames) {
    OwCamera *shown = &follow.camera;
    if (!follow.live) {
        follow.live = true;
        *shown = shot;
    }
    float share = 1 - powf(1 - fminf(weight, 1), (float)frames);
    shown->position = eased(shown->position, shot.position, share);
    shown->target = eased(shown->target, shot.target, share);
    shown->fov += (shot.fov - shown->fov) * share;
    shown->roll += (shot.roll - shown->roll) * share;
    return *shown;
}

// The eye's offset from a line, square to it on the floor (mm).
static void side_of(OwVec3 eye, T5Vec3 point, T5Vec3 direction, float side[2]) {
    float x = eye.x / MM - point.x, z = eye.z / MM - point.z;
    float length_squared = direction.x * direction.x + direction.z * direction.z;
    float along = length_squared > 0 ? (x * direction.x + z * direction.z) / length_squared : 0;
    side[0] = x - along * direction.x;
    side[1] = z - along * direction.z;
}

// A move shot (cut in), else a throw shot pulling the camera on screen, else the fight camera.
OwCamera t5_camera(const T5View *view, float seconds) {
    OwCamera camera;
    float side[2];
    if (move_shot_camera(view, &camera)) {
        const T5Mat4 *first = &view->fighters[0].rig.root.world;
        side_of(camera.position, (T5Vec3){first->m[3][0], 0, first->m[3][2]}, (T5Vec3){0}, side);
        update_sides(view, side);
        follow.live = false;
        return camera;
    }
    uint32_t frames = view->frame > shown_frame ? view->frame - shown_frame : 0;
    shown_frame = view->frame;
    float weight = throw_shot_camera(view, &camera);
    if (weight > 0) {
        camera = shown_toward(camera, weight, frames);
        side_of(camera.position, throw_shot.line_point, throw_shot.line_direction, side);
        update_sides(view, side);
        return camera;
    }
    update_sides(view, NULL);
    if (view->snap) follow.live = false;
    return followed(fight_camera(view), seconds);
}
