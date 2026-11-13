// Where the fighters stand at the start of a round.
#include <math.h>

#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/motion.h"
#include "sim/pose.h"
#include "sim/round.h"
#include "sim/stage.h"
#include "sim/vec.h"

static const T6StartPoint NO_START = {};  // a stage without start records: the origin, no turn

// The start index is signed and wraps by the record count.
static int32_t record_index(const T6World *w, int32_t count) {
    int32_t index = w->start_record;  // the saved start record number
    return index - t6_divw(index, count) * count;  // subtract the whole counts that fit in index
}

// The yaw of the game's binary angle for a facing in radians, and back (the placement writes both).
static int16_t angle_of(float radians) { return t6_rad_to_angle65535(t6_turn_positive(radians)); }  // wrap, then binary angle

// The game keeps the root row 3 and the base position in one memory: a write of one is a write of both.
void t6_round_stand_at(T6Fighter *f, float x, float z) {
    f->position.x = x;  // put them at x, z: position, previous and base
    f->position.z = z;
    f->previous_position.x = x;
    f->previous_position.z = z;
    f->base_position.x = x;
    f->base_position.z = z;
    t6_root_from_base(f);  // copy the base into the root matrix
}

static void face(T6Fighter *f, int16_t angle, float radians) {
    f->move_yaw = angle;  // move yaw and facing take the angle, look and body yaw the radians
    f->facing = angle;
    f->look_yaw = radians;
    f->body_yaw = radians;
}

static void face_raw(T6Fighter *f, float radians) { face(f, angle_of(radians), radians); }  // to binary angle, then face
static void face_snapped(T6Fighter *f, int16_t angle) { face(f, angle, t6_angle65535_to_rad(angle)); }  // to radians, then face

// The record the start index picks from a list, or NO_START when the list is empty.
static T6StartPoint start_point(T6World *w, int32_t list) {
    int32_t count = w->stage->start[list].count;
    if (count == 0) {
        w->start_record = 0;
        return NO_START;
    }
    return w->stage->start[list].points[record_index(w, count)];
}

// Both fighters on one entrance point, facing against its turn (the scene starts and the match end).
static void place_on_entrance(T6World *w) {
    T6StartPoint point = start_point(w, T6_START_ENTRANCE);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        t6_round_stand_at(w->fighters[side], point.position.x, point.position.z);
        face_raw(w->fighters[side], -point.turn);
    }
}

// (hole tk6-start-kinds :tags (tk6 sim) :sev polish) the game's placement kinds are not modelled: Azazel (model 0x26) in kinds 3 and 4 starts at 1500, kind 5 at 1.75 times the offset, kind 9 reads posf table 2, kinds 11..13, 21, 23, 24 place by other code (tk6decomp data.md posf).
// Side 1 at the start offset along x, side 2 at minus it, both turned by the centre's turn and moved onto it
// (FUN_001c548c, row vectors: x times (cos, 0, -sin)).
static void place_on_line(T6World *w) {
    T6StartPoint centre = start_point(w, T6_START_CENTRE);
    float sine = t6_sin(centre.turn), cosine = t6_cos(centre.turn);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        float along = side == 0 ? w->stage->start_offset : -w->stage->start_offset;
        float offset_x = along * cosine, offset_z = -along * sine;
        t6_round_stand_at(w->fighters[side], centre.position.x + offset_x, centre.position.z + offset_z);
        // Our fix: the game takes atan2 of the world position, which only faces the fighters at each other when the
        // centre is the origin; stages 02 (z 3750) and 09 (x -2000) are not. The offset alone faces them on every stage.
        face_snapped(w->fighters[side], (int16_t)t6_fctiwz(t6_atan2(offset_x, offset_z) * T6_RAD_TO_ANGLE));
    }
}

void t6_round_place(T6World *w, T6RoundSetup setup) {
    if (setup.on_entrance_point) place_on_entrance(w);  // entrance layout if the setup asks
    else place_on_line(w);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        T6Fighter *f = w->fighters[side];
        f->position.y = 0.0f;  // put on the ground, no tilt
        f->root_angle_x = 0;  // no tilt on x
        f->root_angle_z = 0;
    }
}

void t6_round_nearest_start(T6World *w) {
    const T6Fighter *first = w->fighters[0], *second = w->fighters[1];
    T6StartList centres = w->stage->start[T6_START_CENTRE];
    float best = w->stage_depth;  // best distance so far, starts at stage depth
    float mid_z = (first->base_position.z + second->base_position.z) * 0.5f;  // the middle between the two fighters
    float mid_x = (first->base_position.x + second->base_position.x) * 0.5f;
    for (int32_t record = 0; record < centres.count; record++) {
        T6Vec3 centre = centres.points[record].position;
        float distance = t6_length_xz(mid_x - centre.x, mid_z - centre.z);
        if (best > distance) {
            best = distance;
            w->start_record = record;
        }
    }
}

void t6_round_floor_origin(T6World *w) {
    if (!w->limb_env.floor_origin) return;  // floor origin off: nothing to do
    const T6Fighter *first = w->fighters[0], *second = w->fighters[1];
    w->limb_env.floor.origin_y = t6_stage_floor(w,  // floor height at the midpoint of the fighters
        vec3_scale(vec3_add(first->position, second->position), 0.5f));
}

void t6_round_turn(T6World *w) {
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        T6Fighter *f = w->fighters[side];
        f->move_yaw = (int16_t)(f->move_yaw + w->scene_turn);  // add the scene turn to move yaw and facing
        f->facing = (int16_t)(f->facing + w->scene_turn);
    }
}
