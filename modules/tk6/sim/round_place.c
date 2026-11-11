// Where the fighters stand at the start of a round.
#include <math.h>

#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/motion.h"
#include "sim/pose.h"
#include "sim/round.h"
#include "sim/stage.h"
#include "sim/vec.h"

static const float FALLBACK_X = 1000.0f;       // the fallback line when the stage has no start points
static const float SIDE_DISTANCE = 2000.0f;    // side 2 stands this far from side 1, toward its table point

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

// Both fighters on one entrance point, facing one way (the scene starts and the match end).
static void place_on_entrance(T6World *w) {
    int32_t count = w->stage->start[T6_START_ENTRANCE].count;  // number of entrance records
    if (count == 0) {  // no entrance records: fall back to the origin
        w->start_record = 0;
        for (int side = 0; side < T6_FIGHTER_COUNT; side++) {  // loop through both fighters
            t6_round_stand_at(w->fighters[side], 0.0f, 0.0f);  // stand at x 0, z 0
            face(w->fighters[side], 0, 0.0f);  // face angle 0
        }
        return;
    }
    int32_t index = record_index(w, count);  // wrapped start record
    T6StartPoint point = w->stage->start[T6_START_ENTRANCE].points[index];  // the entrance point for that record
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        t6_round_stand_at(w->fighters[side], point.position.x, point.position.z);  // stand on the point's x and z
        face_raw(w->fighters[side], point.turn);
    }
}

// Side 1 on its table point, side 2 two thousand units from it toward its own table point.
static void place_on_lines(T6World *w) {
    T6Fighter *first_fighter = w->fighters[0], *second_fighter = w->fighters[1];
    int32_t count = w->stage->start[T6_START_SIDE_1].count;  // number of side 1 records
    if (count == 0) {  // no records: use the fallback line
        w->start_record = 0;
        t6_round_stand_at(first_fighter, -FALLBACK_X, 0.0f);  // side 1 at -FALLBACK_X, z 0
        face_snapped(first_fighter, (int16_t)t6_fctiwz(t6_atan2(-FALLBACK_X, 0.0f) * T6_RAD_TO_ANGLE));  // face atan2(-1000, 0)
        t6_round_stand_at(second_fighter, FALLBACK_X, 0.0f);  // side 2 at FALLBACK_X, z 0
        face_snapped(second_fighter, (int16_t)t6_fctiwz(t6_atan2(FALLBACK_X, 0.0f) * T6_RAD_TO_ANGLE));  // face atan2(1000, 0)
        return;
    }
    int32_t index = record_index(w, count);  // wrapped start record
    T6StartPoint first = w->stage->start[T6_START_SIDE_1].points[index];  // side 1 and side 2 points for that record
    T6StartPoint second = w->stage->start[T6_START_SIDE_2].points[index];
    t6_round_stand_at(first_fighter, first.position.x, first.position.z);  // stand side 1 on its point
    face_raw(first_fighter, first.turn);
    T6Vec4 from = {{first.position.x, 0.0f, first.position.z, 1.0f}}, to = {{second.position.x, 0.0f, second.position.z, 1.0f}};
    T6Vec4 along, unit, step, end;
    t6_vec_subtract(&along, &to, &from);
    float length = t6_length3(along.x, along.y, along.z);
    float inverse = 0.0f;
    if (length != 0.0f) inverse = 1.0f / length;  // 1 / length, unless zero
    t6_vec_scale(&unit, &along, inverse);  // unit: the direction from side 1 to side 2
    t6_vec_scale(&step, &unit, SIDE_DISTANCE);  // a fixed distance along that direction
    step.w = 0.0f;  // clear w so step is only an offset
    t6_vec_add(&end, &from, &step);  // end: side 1 point moved along step
    t6_round_stand_at(second_fighter, end.x, end.z);  // stand side 2 at end
    face_raw(second_fighter, second.turn);
}

void t6_round_place(T6World *w, T6RoundSetup setup) {
    if (setup.on_entrance_point) place_on_entrance(w);  // entrance layout if the setup asks
    else place_on_lines(w);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        T6Fighter *f = w->fighters[side];
        f->position.y = 0.0f;  // put on the ground, no tilt
        f->root_angle_x = 0;  // no tilt on x
        f->root_angle_z = 0;
    }
}

void t6_round_nearest_start(T6World *w) {
    const T6Fighter *first = w->fighters[0], *second = w->fighters[1];
    int32_t count = w->stage->start[T6_START_SIDE_1].count;  // number of side 1 records
    if (count <= 0) return;  // no records: nothing to pick
    float best = w->stage_depth;  // best distance so far, starts at stage depth
    float mid_z = (first->base_position.z + second->base_position.z) * 0.5f;  // the middle between the two fighters
    float mid_x = (first->base_position.x + second->base_position.x) * 0.5f;
    for (int32_t record = 0; record < count; record++) {  // loop through every start record
        T6Vec3 first_start = w->stage->start[T6_START_SIDE_1].points[record].position;  // this record's two points
        T6Vec3 second_start = w->stage->start[T6_START_SIDE_2].points[record].position;
        float offset_z = mid_z - ((first_start.z + second_start.z) * 0.5f);  // gap between the two middles
        float offset_x = mid_x - ((first_start.x + second_start.x) * 0.5f);
        float distance = t6_length_xz(offset_x, offset_z);  // ground distance of that gap
        if (best > distance) {  // closer than the best so far
            best = distance;
            w->start_record = record;  // this record is the best
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
