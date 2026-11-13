// Stock TK6 presenter (gamerender.wasm): the fight camera, the camera shots of moves and throws, and the hit zoom. Per
// viewer, outside rollback. The camera and the timeline player are SDK libraries; TK6 gives params and data.
#include <SDL3/SDL.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>

#include "gamerender/presenter.h"
#include "pack_file.h"
#include "sim/anim.h"
#include "sqlite3.h"


static const float DISTANCE = 3.6f;      // metres from the midpoint, along the view normal; the closest it gets
static const float FIGHTER_ROOM = 1.2f;  // metres kept on screen past the two fighters' roots, both sides together
static const float FOCUS_HEIGHT = 0.9f;  // metres above the floor
static const float RAISE = 0.5f;         // the camera sits this much above the focus
static const float FOV = 0.698132f;      // 40 degrees, vertical
static const float TURN = 6.2831853f / 65536.0f;  // radians per yaw unit
static const float DEGREE = 3.14159265f / 180;
static const float FOLLOW_RATE = 8.0f;  // per second: how fast the fight camera closes on where it should be

enum {
    SHOTS_MAX = 32, THROW_MOVES_MAX = 128, THROW_SHOTS_MAX = 1024, RELEASE_MOVES_MAX = 512,  // per side
    HIT_ZOOMS_MAX = 64, ZOOM_TURNS_MAX = 4,
    COUNTER_FRAMES = 5,  // a counter hit lets a counter-only hit zoom start this many frames
};
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

// A move that draws a throw shot (move_throw_shot).
typedef struct {
    int16_t move, frame;
    int32_t list;
} ThrowMove;

// A throw_shot row: ranges least, most, in degrees.
typedef struct {
    int32_t list, weight;
    bool thrower_right, keeps_fight_camera, cut_in;
    float yaw[2], pitch[2], fov[2], distance_scale;
} ThrowShotRow;

// A move's last release property frame (0x803b..0x8041): the throw holds until then.
typedef struct {
    int16_t move, frame;
} ReleaseFrame;

typedef struct {
    int32_t weight;
    float turn, wall_turn;  // degrees
} ZoomTurn;

typedef struct {
    int32_t category, frames;
    float distance, fov;  // mm, degrees
    bool counter_only;
    int turn_count;
    ZoomTurn turns[ZOOM_TURNS_MAX];
} HitZoom;

static Shot shots[T6_FIGHTER_COUNT][SHOTS_MAX];
static int shot_count[T6_FIGHTER_COUNT];
static ThrowMove throw_moves[T6_FIGHTER_COUNT][THROW_MOVES_MAX];
static int throw_move_count[T6_FIGHTER_COUNT];
static ThrowShotRow throw_shot_rows[T6_FIGHTER_COUNT][THROW_SHOTS_MAX];  // by list, then pos
static int throw_shot_row_count[T6_FIGHTER_COUNT];
static ReleaseFrame release_frames[T6_FIGHTER_COUNT][RELEASE_MOVES_MAX];
static int release_frame_count[T6_FIGHTER_COUNT];
static HitZoom hit_zooms[HIT_ZOOMS_MAX];
static int hit_zoom_count;

static T6KeyKind camera_channel_kind(int32_t channel) { return channel < 2 ? T6_KEY_POSITION : T6_KEY_VALUES; }

// No frames: the file is not a camera track.
static Clip clip_of(T6FileSet *files, const unsigned char *path) {
    const float *keys;
    uint16_t frames = t6_anim_file(t6_read_set_file(files, (const char *)path), "camera", CAMERA_CHANNELS, camera_channel_kind, &keys);
    return (Clip){frames, (const CameraKey *)keys};
}

// Moves are numbered in sheet order, as the sim's loader lays them out.
#define MOVES_IN_SHEET_ORDER \
    "(SELECT key, extra_props, row_number() OVER (ORDER BY rowid) - 1 AS number FROM move WHERE character = ?1) AS move "

static sqlite3_stmt *character_rows(sqlite3 *db, const char *query, const char *character) {
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, query, -1, &rows, NULL) != SQLITE_OK) return NULL;
    sqlite3_bind_text(rows, 1, character, -1, SQLITE_STATIC);
    return rows;
}

static void load_shots(sqlite3 *db, int side, const char *character, T6FileSet *files) {
    shot_count[side] = 0;
    sqlite3_stmt *rows = character_rows(db,
        "SELECT move.number, move_camera.frame, anim.file FROM " MOVES_IN_SHEET_ORDER
        "JOIN move_camera ON move_camera.move = move.key "
        "JOIN anim ON anim.character = move_camera.tracks AND anim.idx = move_camera.track", character);
    if (!rows) return;
    while (shot_count[side] < SHOTS_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        Clip clip = clip_of(files, sqlite3_column_text(rows, 2));
        if (clip.frame_count)
            shots[side][shot_count[side]++] = (Shot){(int16_t)sqlite3_column_int(rows, 0), (int16_t)sqlite3_column_int(rows, 1), clip};
    }
    sqlite3_finalize(rows);
}

static void load_throw_shots(sqlite3 *db, int side, const char *character) {
    throw_move_count[side] = throw_shot_row_count[side] = release_frame_count[side] = 0;
    sqlite3_stmt *rows = character_rows(db,
        "SELECT move.number, move_throw_shot.frame, move_throw_shot.list FROM " MOVES_IN_SHEET_ORDER
        "JOIN move_throw_shot ON move_throw_shot.move = move.key", character);
    if (rows) {
        while (throw_move_count[side] < THROW_MOVES_MAX && sqlite3_step(rows) == SQLITE_ROW)
            throw_moves[side][throw_move_count[side]++] =
                (ThrowMove){(int16_t)sqlite3_column_int(rows, 0), (int16_t)sqlite3_column_int(rows, 1), sqlite3_column_int(rows, 2)};
        sqlite3_finalize(rows);
    }
    rows = character_rows(db,
        "SELECT list, weight, thrower_right, keeps_fight_camera, cut_in, yaw_least, yaw_most, pitch_least, pitch_most, "
        "fov_least, fov_most, distance_scale FROM throw_shot WHERE character = ?1 ORDER BY list, pos", character);
    if (rows) {
        while (throw_shot_row_count[side] < THROW_SHOTS_MAX && sqlite3_step(rows) == SQLITE_ROW) {
            float value[7];
            for (int at = 0; at < 7; at++) value[at] = (float)sqlite3_column_double(rows, 5 + at);
            throw_shot_rows[side][throw_shot_row_count[side]++] = (ThrowShotRow){
                sqlite3_column_int(rows, 0), sqlite3_column_int(rows, 1), sqlite3_column_int(rows, 2) != 0,
                sqlite3_column_int(rows, 3) != 0, sqlite3_column_int(rows, 4) != 0,
                {value[0], value[1]}, {value[2], value[3]}, {value[4], value[5]}, value[6]};
        }
        sqlite3_finalize(rows);
    }
    rows = character_rows(db,
        "SELECT move.number, max(extra_prop.\"when\" & 0x7fff) FROM " MOVES_IN_SHEET_ORDER
        "JOIN extra_prop ON extra_prop.list = move.extra_props AND extra_prop.id BETWEEN 0x803b AND 0x8041 GROUP BY move.number",
        character);
    if (rows) {
        while (release_frame_count[side] < RELEASE_MOVES_MAX && sqlite3_step(rows) == SQLITE_ROW)
            release_frames[side][release_frame_count[side]++] = (ReleaseFrame){(int16_t)sqlite3_column_int(rows, 0), (int16_t)sqlite3_column_int(rows, 1)};
        sqlite3_finalize(rows);
    }
}

void t6_camera_load(sqlite3 *db, int side, const char *character, T6FileSet *files) {
    load_shots(db, side, character, files);
    load_throw_shots(db, side, character);
}

void t6_camera_init(sqlite3 *db) {
    hit_zoom_count = 0;
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT category, frames, distance, fov, counter_only FROM hit_zoom ORDER BY category", -1, &rows, NULL) != SQLITE_OK) return;
    while (hit_zoom_count < HIT_ZOOMS_MAX && sqlite3_step(rows) == SQLITE_ROW)
        hit_zooms[hit_zoom_count++] = (HitZoom){sqlite3_column_int(rows, 0), sqlite3_column_int(rows, 1), (float)sqlite3_column_double(rows, 2),
                                                (float)sqlite3_column_double(rows, 3), sqlite3_column_int(rows, 4) != 0};
    sqlite3_finalize(rows);
    if (sqlite3_prepare_v2(db, "SELECT category, weight, turn, wall_turn FROM hit_zoom_turn ORDER BY category, pos", -1, &rows, NULL) != SQLITE_OK) return;
    while (sqlite3_step(rows) == SQLITE_ROW) {
        int32_t category = sqlite3_column_int(rows, 0);
        for (int at = 0; at < hit_zoom_count; at++) {
            HitZoom *zoom = &hit_zooms[at];
            if (zoom->category != category || zoom->turn_count == ZOOM_TURNS_MAX) continue;
            zoom->turns[zoom->turn_count++] = (ZoomTurn){sqlite3_column_int(rows, 1), (float)sqlite3_column_double(rows, 2), (float)sqlite3_column_double(rows, 3)};
        }
    }
    sqlite3_finalize(rows);
}

// xz direction from the fighters to the camera; screen sides follow it. On -x: side 1, at -z, is on the left.
static float view_normal[2] = {-1, 0};
static bool on_right[T6_FIGHTER_COUNT];  // as last sent to the host

// The camera's side of the line between the fighters. A shot keeps the side its eye is on, `shot_side` (xz, mm): the
// game measures the screen sides through whatever camera is on screen, and the fight camera keeps them after the shot
// which is how some throws swap the screen sides. Else a fighter changes screen side only by crossing over,
// and a scene cut (a round start) takes a fresh side, with side 1 on the left. Each side goes to the host for its pad.
static void update_sides(const T6View *view, const float *shot_side) {
    const T6Mat4 *first = &view->fighters[0].rig.root.world, *second = &view->fighters[1].rig.root.world;
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
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6Mat4 *me = &view->fighters[side].rig.root.world, *other = &view->fighters[1 - side].rig.root.world;
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

// The follow camera, pulled back when the fighters stand wider apart than it shows.
static OwCamera fight_camera(const T6View *view) {
    const T6Mat4 *first = &view->fighters[0].rig.root.world, *second = &view->fighters[1].rig.root.world;
    OwVec3 focus = {
        (first->m[3][0] + second->m[3][0]) * 0.5f * MM,
        fminf(view->fighters[0].position.y, view->fighters[1].position.y) * MM + FOCUS_HEIGHT,  // over the lower floor
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

static OwCamera blended(OwCamera from, OwCamera to, float weight) {
    return (OwCamera){eased(from.position, to.position, weight), eased(from.target, to.target, weight),
                      from.fov + (to.fov - from.fov) * weight, from.roll + (to.roll - from.roll) * weight};
}

// The fight camera eased toward `goal` over `seconds`, the same at any display rate.
static OwCamera followed(OwCamera goal, float seconds) {
    if (!follow.live) {
        follow.live = true;
        return follow.camera = goal;
    }
    float weight = 1.0f - expf(-FOLLOW_RATE * seconds);
    follow.camera = blended(follow.camera, goal, weight);
    return follow.camera;
}

// Where a track is placed: a fighter's position and move yaw.
typedef struct {
    T6Vec3 position;
    int16_t yaw;
} Anchor;

// A track point in the anchor's frame, in the world: turned by -yaw about y, then moved to the anchor.
static OwVec3 placed(Anchor anchor, const float local[3]) {
    float angle = -anchor.yaw * TURN, cosine = cosf(angle), sine = sinf(angle);
    T6Vec3 at = anchor.position;
    return (OwVec3){
        (at.x + cosine * local[0] - sine * local[2]) * MM,
        (at.y + local[1]) * MM,
        (at.z + sine * local[0] + cosine * local[2]) * MM,
    };
}

static OwCamera keyed(Anchor anchor, const CameraKey *key) {
    return (OwCamera){
        .position = placed(anchor, (*key)[0]),
        .target = placed(anchor, (*key)[1]),
        .fov = (*key)[2][0],
        .roll = (*key)[2][1],
    };
}

// The key of the fighter's shot at its move frame; NULL when its move has no shot or the shot is over.
static const CameraKey *shot_key(const T6ViewFighter *fighter, int32_t *elapsed) {
    int set = fighter->move.set;
    if (fighter->move.index < 0 || set >= T6_FIGHTER_COUNT) return NULL;
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
static bool move_shot_camera(const T6View *view, OwCamera *camera) {
    const CameraKey *key = NULL;
    int shot_side = -1;
    int32_t newest = INT32_MAX;
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        int32_t elapsed;
        const CameraKey *found = shot_key(&view->fighters[side], &elapsed);
        if (found && elapsed < newest) key = found, shot_side = side, newest = elapsed;
    }
    if (!key) return false;
    const T6ViewFighter *fighter = &view->fighters[shot_side];
    uint32_t start_frame = view->frame - (uint32_t)newest;
    if (move_shot.side != shot_side || move_shot.move != fighter->move.index || move_shot.start_frame != start_frame)
        move_shot = (typeof(move_shot)){shot_side, fighter->move.index, start_frame, {fighter->position, fighter->move_yaw}};
    *camera = keyed(move_shot.anchor, key);
    return true;
}

static float random_unit(void) { return (float)rand() / ((float)RAND_MAX + 1.0f); }
static float drawn(const float range[2]) { return range[0] + (range[1] - range[0]) * random_unit(); }

// The row of a list for the thrower's screen side, by weight (libc rand, not the sim's); NULL when the list has none.
static const ThrowShotRow *draw_throw_shot(int set, int32_t list, bool thrower_right) {
    int total = 0;
    for (int at = 0; at < throw_shot_row_count[set]; at++) {
        const ThrowShotRow *row = &throw_shot_rows[set][at];
        if (row->list == list && row->thrower_right == thrower_right) total += row->weight;
    }
    if (total <= 0) return NULL;
    int draw = rand() % total;
    for (int at = 0; at < throw_shot_row_count[set]; at++) {
        const ThrowShotRow *row = &throw_shot_rows[set][at];
        if (row->list != list || row->thrower_right != thrower_right) continue;
        draw -= row->weight;
        if (draw < 0) return row;
    }
    return NULL;
}

static T6ThrowShot throw_shot = {.thrower = -1};
static struct {
    int thrower;
    int16_t move;
    uint32_t frame;  // sim frame of the draw
} throw_draw = {.thrower = -1};

// A thrower's move draws its shot on the frame it names, once.
static void start_throw_shot(const T6View *view) {
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6ViewFighter *thrower = &view->fighters[side];
        int set = thrower->move.set;
        if (thrower->throw_role != THROW_ROLE_THROWER || set >= T6_FIGHTER_COUNT) continue;
        for (int at = 0; at < throw_move_count[set]; at++) {
            const ThrowMove *throw_move = &throw_moves[set][at];
            if (throw_move->move != thrower->move.index || thrower->move_frame < throw_move->frame) continue;
            uint32_t frame = view->frame - (uint32_t)(thrower->move_frame - throw_move->frame);
            if (throw_draw.thrower == side && throw_draw.move == throw_move->move && throw_draw.frame == frame) continue;
            throw_draw.thrower = side, throw_draw.move = throw_move->move, throw_draw.frame = frame;
            const ThrowShotRow *row = draw_throw_shot(set, throw_move->list, on_right[side]);
            if (!row || row->keeps_fight_camera) continue;
            T6ThrowShotPlan plan = {drawn(row->yaw), drawn(row->pitch), drawn(row->fov), row->distance_scale, row->cut_in};
            t6_throw_shot_start(&throw_shot, side, plan, thrower->camera.throw_moves);
        }
    }
}

// A fighter of the throw still has a release property ahead in its move.
static bool releases_ahead(const T6View *view) {
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6ViewFighter *fighter = &view->fighters[side];
        int set = fighter->move.set;
        if (fighter->throw_role == THROW_ROLE_NONE || set >= T6_FIGHTER_COUNT) continue;
        for (int at = 0; at < release_frame_count[set]; at++) {
            const ReleaseFrame *release = &release_frames[set][at];
            if (release->move == fighter->move.index && release->frame > fighter->move_frame) return true;
        }
    }
    return false;
}

static const HitZoom *hit_zoom_of(int32_t category) {
    for (int at = 0; at < hit_zoom_count; at++) if (hit_zooms[at].category == category) return &hit_zooms[at];
    return NULL;
}

static float drawn_turn(const HitZoom *zoom, bool by_wall) {
    int total = 0;
    for (int at = 0; at < zoom->turn_count; at++) total += zoom->turns[at].weight;
    int draw = total > 0 ? rand() % total : 0;
    for (int at = 0; at < zoom->turn_count; at++) {
        draw -= zoom->turns[at].weight;
        if (draw < 0) return by_wall ? zoom->turns[at].wall_turn : zoom->turns[at].turn;
    }
    return 0;
}

// The hit zoom on screen: the camera on screen when the hit landed, swung about its target, closer, held still.
static struct {
    bool live;
    uint32_t stepped_frame, end_frame, counter_frame;
    OwCamera camera;
} zoom = {.counter_frame = UINT32_MAX};

// A clean hit by a fighter whose camera category has a hit zoom, in the fight.
static void start_hit_zoom(const T6View *view, OwCamera shown) {
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6ViewCamera *attacker = &view->fighters[side].camera, *victim = &view->fighters[1 - side].camera;
        const HitZoom *row = hit_zoom_of(attacker->category);
        if (!row || !attacker->hit_landed || attacker->hit_taken || !victim->hit_taken || victim->guarded) continue;
        if (row->counter_only && view->frame - zoom.counter_frame >= COUNTER_FRAMES) continue;
        OwVec3 back = {shown.position.x - shown.target.x, shown.position.y - shown.target.y, shown.position.z - shown.target.z};
        float length = sqrtf(back.x * back.x + back.y * back.y + back.z * back.z);
        if (length <= 0) return;
        float across = sqrtf(back.x * back.x + back.z * back.z) / length;
        float turn = drawn_turn(row, attacker->at_wall || victim->at_wall) * DEGREE * (on_right[side] ? 1 : -1);
        float bearing = atan2f(back.z, back.x) + turn, distance = row->distance * MM;
        OwVec3 direction = {across * cosf(bearing), back.y / length, across * sinf(bearing)};
        zoom.camera = (OwCamera){
            .position = {shown.target.x + direction.x * distance, shown.target.y + direction.y * distance, shown.target.z + direction.z * distance},
            .target = shown.target,
            .fov = row->fov * DEGREE,
        };
        zoom.live = true;
        zoom.end_frame = view->frame + (uint32_t)row->frames;
        return;
    }
}

static void step_hit_zoom(const T6View *view, OwCamera shown) {
    if (view->frame == zoom.stepped_frame) return;
    zoom.stepped_frame = view->frame;
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) if (view->fighters[side].camera.counter_hit) zoom.counter_frame = view->frame;
    if (zoom.live && view->frame >= zoom.end_frame) zoom.live = false;  // a cut back to the fight camera, which kept following
    if (!zoom.live && view->phase == T6_PHASE_FIGHT) start_hit_zoom(view, shown);
}

// The eye's offset from a line, square to it on the floor (mm).
static void side_of(OwVec3 eye, T6Vec3 point, T6Vec3 direction, float side[2]) {
    float x = eye.x / MM - point.x, z = eye.z / MM - point.z;
    float length_squared = direction.x * direction.x + direction.z * direction.z;
    float along = length_squared > 0 ? (x * direction.x + z * direction.z) / length_squared : 0;
    side[0] = x - along * direction.x;
    side[1] = z - along * direction.z;
}

static T6Vec3 fighters_line(const T6View *view, T6Vec3 *point) {
    const T6Vec3 *first = &view->fighters[0].position, *second = &view->fighters[1].position;
    *point = (T6Vec3){(first->x + second->x) * 0.5f, 0, (first->z + second->z) * 0.5f};
    return (T6Vec3){second->x - first->x, 0, second->z - first->z};
}

// A move shot (cut in), else a throw shot over the fight camera, else a hit zoom, else the fight camera.
OwCamera t6_camera(const T6View *view, float seconds) {
    OwCamera camera;
    float side[2];
    if (move_shot_camera(view, &camera)) {
        const T6Mat4 *first = &view->fighters[0].rig.root.world;
        side_of(camera.position, (T6Vec3){first->m[3][0], 0, first->m[3][2]}, (T6Vec3){0}, side);
        update_sides(view, side);
        follow.live = false;
        return camera;
    }
    if (view->snap) {  // a scene cut: fresh sides, then the fight camera cuts in
        update_sides(view, NULL);
        follow.live = false;
    }
    OwCamera fight = followed(fight_camera(view), seconds);
    if (view->phase == T6_PHASE_FIGHT) start_throw_shot(view);
    float weight = t6_throw_shot(&throw_shot, view, fight, releases_ahead(view), &camera);
    if (weight > 0) {
        camera = blended(fight, camera, weight);
        side_of(camera.position, throw_shot.line_point, throw_shot.line_direction, side);
        update_sides(view, side);
        return camera;
    }
    step_hit_zoom(view, fight);
    if (zoom.live) {
        T6Vec3 point, direction = fighters_line(view, &point);
        side_of(zoom.camera.position, point, direction, side);
        update_sides(view, side);
        return zoom.camera;
    }
    update_sides(view, NULL);
    return fight;
}
