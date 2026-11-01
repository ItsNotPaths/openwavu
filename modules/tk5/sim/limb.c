#include "sim/limb.h"

#include <math.h>
#include <string.h>

#include "sim/bones.h"
#include "sim/hit.h"
#include "sim/math.h"
#include "sim/quat.h"
#include "sim/stage.h"
#include "sim/transition.h"

static const float EPSILON = 1e-5f;

typedef float Row[4];

static T5Vec4 *row(T5Mat4 *matrix, int index) { return (T5Vec4 *)matrix->m[index]; }
static const T5Vec4 *crow(const T5Mat4 *matrix, int index) { return (const T5Vec4 *)matrix->m[index]; }
static T5Vec3 translation(const T5Mat4 *matrix) { return vec3_of(*crow(matrix, 3)); }
static void copy_rows(T5Mat4 *to, const T5Mat4 *from, int count) { memcpy(to->m, from->m, (size_t)count * sizeof(Row)); }

// stack = matrix * stack on the matrix stack
static void premultiply(T5Mat4 *stack, const T5Mat4 *matrix) { t5_mat_multiply(stack, matrix); }

// --- floor

static const float CONTACT_R2 = 100.0f;
enum { CACHE_MATERIAL_SHIFT = 24 };  // T5FloorCache.kind keeps the material in bits 24..27
static uint32_t cache_kind(int32_t material) { return (uint32_t)material << CACHE_MATERIAL_SHIFT; }
static bool special_floor(uint32_t kind) { return kind >> CACHE_MATERIAL_SHIFT == T5_MATERIAL_OBJECT_FLOOR; }
enum { SPECIAL_FLOOR_LIST = 1 };  // the floor list that holds the special floor

// raise the point by the floor's excess over `level`; the push keeps 0.4 of the move
static void lift(T5Limb *limb, T5Vec4 *point, const T5Vec4 *start, float *probe_y, float *other_y, float level, float y) {
    float rise = level - y;  // how far the floor level is above the current height
    point->y += rise;
    if (other_y) *other_y = rise + *other_y;  // if a second probe height is given, raise it too
    *probe_y = *probe_y + rise;
    limb->push_step.y = 0.0f;
    t5_vec_subtract(&limb->push, point, start);  // push = how far the point has moved from where it started
    t5_vec_scale(&limb->push, &limb->push, 0.4f);  // the push keeps 0.4 of that move
}

bool t5_limb_floor(T5LimbState *limbs,  // keep a limb above the floor; true when the point was moved by 1 or more
    int32_t limb_index, float radius, T5Vec4 *point, const T5Vec4 *probe, const T5Vec4 *probe2,
                   bool paused, const T5World *w, float origin_y) {
    T5Limb *limb = &limbs->limb[limb_index];
    T5FloorCache *cache = &limbs->floor[limb_index];
    uint32_t bit = 1u << limb_index;
    T5Vec4 moved_point = *point, start, probe_at, probe2_at;
    t5_vec_add(&moved_point, &moved_point, &limb->offset);  // add the limb offset (hitbox aim shift) to the point
    moved_point.w = point->w;
    start = moved_point;
    t5_vec_add(&moved_point, &moved_point, &limb->push);
    t5_vec_add(&probe_at, probe, &limb->push);
    if (probe2) t5_vec_add(&probe2_at, probe2, &limb->push);
    if (!paused) {  // if the game is not paused
        t5_vec_scale(&limb->push_step, &limb->push, -0.3f);  // push step = minus 0.3 of the push
        t5_vec_add(&limb->push, &limb->push, &limb->push_step);
    }

    T5StageHeight floor =  // floor height and kind under the probe
        t5_stage_height(w, vec3_of(probe_at));
    cache->y = floor.y;
    cache->kind = cache_kind(floor.material);
    float level = cache->y + radius;  // the level the limb must stay above: floor plus radius
    T5Vec3 offset_xz = vec3_subtract(vec3_of(moved_point), limb->contact);
    bool near =  // near = within the contact distance (squared under 100) of the last contact point
        !(fmaf(offset_xz.z, offset_xz.z, offset_xz.x * offset_xz.x) >= CONTACT_R2);
    if (near && fabsf(level - limb->contact.y) > 10.0f) {  // if near the last contact and the floor level jumped over 10 from it
        level = limb->contact.y;  // ignore the jump and keep the old contact level
    } else {
        limb->contact = (T5Vec3){moved_point.x, level, moved_point.z};  // record this as the new contact point
    }
    if (!(probe_at.y >= level + 28.0f))  // under level plus 28: mark the limb near the floor
        limbs->below[0] |= bit;
    if (!(level <= probe_at.y))  // if the probe is under the level, lift the point up to it
        lift(limb, &moved_point, &start, &probe_at.y, probe2 ? &probe2_at.y : NULL, level, probe_at.y);

    if (probe2) {  // if there is a second probe
        float level2 = radius + origin_y;  // level of the second probe: stage origin floor plus radius
        if (near && !(fabsf(level2 - limb->contact.y) <= 10.0f))  // near and the level jumped over 10: use the last origin level
            level2 = limb->origin_level;
        else limb->origin_level = level2;
        if (probe2_at.y < level2 + 28.0f)  // second probe under level plus 28: mark near the floor
            limbs->below[0] |= bit;
        if (level2 > probe2_at.y)  // second probe under its level: lift the point up to it
            lift(limb, &moved_point, &start, &probe2_at.y, &probe_at.y, level2, probe2_at.y);
    }

    if (special_floor(cache->kind)) {  // if the floor under the probe is the special floor
        float y = point->y;
        if (near && fabsf(y - limb->special_y) <= 10.0f) {  // if near and the height is within 10 of the last special floor query
            limbs->below_special[0] |= limbs->below_special[1] & bit;
        } else {
            limb->special_y = y;
            cache->special_y =  // ask the stage for the special floor height under the probe
                t5_stage_special(w, vec3_of(probe_at), SPECIAL_FLOOR_LIST);
            if (!(probe_at.y >= radius + cache->special_y))  // under the special floor plus radius: mark near it
                limbs->below_special[0] |= bit;
        }
    }

    T5Vec4 moved;
    t5_vec_subtract(&moved, point, &moved_point);
    if (t5_vec_dot3(&moved, &moved) < 1.0f) return false;  // if the move is under 1 long, report no correction
    *point = moved_point;  // take the corrected position
    return true;
}

// --- two-bone solve

// Rotation about the unit axis by the angle with this cosine and sine (Rodrigues, row vectors), row 3 = translation.
static void axis_rotation(T5Mat4 *matrix, const T5Vec4 *axis, float cosine, float sine, const T5Vec4 *translation) {
    T5Vec4 scaled_axis;  // axis * (1 - cosine)
    t5_vec_scale(&scaled_axis, axis, 1.0f - cosine);
    const float *unit = axis->v, *scaled = scaled_axis.v;
    float zx = unit[2] * scaled[0];
    float xs = unit[0] * sine;
    float zs = unit[2] * sine;
    float ys = unit[1] * sine;
    float xy = unit[0] * scaled[1];
    float yz = unit[1] * scaled[2];
    t5_mat_identity(matrix);
    memcpy(matrix->m[0], (float[4]){fmaf(unit[0], scaled[0], cosine), xy + zs, zx - ys, unit[3]}, sizeof(Row));
    memcpy(matrix->m[1], (float[3]){xy - zs, fmaf(unit[1], scaled[1], cosine), yz + xs}, 3 * sizeof(float));
    memcpy(matrix->m[2], (float[3]){zx + ys, yz - xs, fmaf(unit[2], scaled[2], cosine)}, 3 * sizeof(float));
    *row(matrix, 3) = *translation;
}

// rotation about local z: rows (cosine, sine), (negative_sine, cosine)
static void z_rotation(T5Mat4 *matrix, float cosine, float sine, float negative_sine) {
    t5_mat_identity(matrix);
    matrix->m[0][0] = cosine;
    matrix->m[0][1] = sine;
    matrix->m[0][2] = 0.0f;
    matrix->m[1][0] = negative_sine;
    matrix->m[1][1] = cosine;
    matrix->m[1][2] = 0.0f;
    matrix->m[2][0] = matrix->m[2][1] = 0.0f;
    matrix->m[2][2] = 1.0f;
}

// Direction from upper's origin to the current chain end, in upper's parent space; `along1` is lower's
// share along upper's y (the code keeps the buffer, whose w lane later becomes the axis w).
static void chain_direction(T5Vec4 *direction, T5Vec4 *along1, const T5Mat4 *upper, const T5Mat4 *lower, float upper_length, float lower_length) {
    float sine_cosine[2];
    t5_fast_sincos(t5_fctiwz(t5_fast_atan2(-lower->m[0][1], lower->m[0][0])  // lower bone's bend as sine and cosine
        * 10430.3779f), sine_cosine);
    t5_vec_scale(direction, crow(upper, 0),  // direction = upper's x axis times (upper length plus lower length times cosine)
        fmaf(lower_length, sine_cosine[1], upper_length));
    t5_vec_scale(along1, crow(upper, 1), lower_length * sine_cosine[0]);  // along1 = upper's y axis times lower length times sine
    t5_vec_subtract(direction, direction, along1);  // subtract it: direction from upper's origin to the chain end
}

void t5_limb_two_bone(T5Mat4 *upper, T5Mat4 *lower, const T5Mat4 *parent, float upper_length, float lower_length,
                      const T5Vec4 *target, bool flip) {
    T5Vec4 to_target;
    t5_vec_subtract(&to_target, target, crow(parent, 3));  // vector from the parent's origin to the target
    T5Vec4 goal = {{t5_vec_dot3(&to_target, crow(parent, 0)),  // goal = target in the parent's space (dot with its axes)
        t5_vec_dot3(&to_target, crow(parent, 1)), t5_vec_dot3(&to_target, crow(parent, 2)), 1.0f}};
    float length_squared_difference =  // upper length squared minus lower length squared
        fmaf(upper_length, upper_length, -(lower_length * lower_length));

    // frame: x toward the current chain end, z = upper's z
    T5Vec4 direction, axis;
    chain_direction(&direction, &axis, upper, lower, upper_length, lower_length);  // direction to the chain end
    T5Vec4 scratch = direction;  // the code reads its y lane again below (a stale value)
    T5Mat4 frame;
    t5_mat_identity(&frame);
    float direction_squared = t5_vec_dot3(&direction, &direction);
    if (direction_squared < EPSILON) {  // if the chain end sits on upper's origin (direction too short)
        *row(&frame, 0) = *crow(upper, 1);  // frame x = upper's y axis
        *row(&frame, 1) = *crow(upper, 0);
        t5_vec_scale(row(&frame, flip ? 1 : 0), row(&frame, flip ? 1 : 0), -1.0f);
    } else {
        float direction_length = sqrtf(direction_squared);
        float direction_w = direction.w;
        t5_vec_scale(row(&frame, 0), &direction,  // frame x = direction made unit length (zero if zero length)
            direction_length != 0.0f ? 1.0f / direction_length : 0.0f);
        frame.m[0][3] = direction_w;
        t5_vec_cross(row(&frame, 1), crow(upper, 2), row(&frame, 0));  // frame y = upper's z axis crossed with frame x
    }
    *row(&frame, 2) = *crow(upper, 2);

    // turn the frame's x onto the goal
    T5Vec4 to_goal;
    t5_vec_subtract(&to_goal, &goal, crow(upper, 3));  // vector from upper's origin to the goal
    float goal_distance_squared = t5_vec_dot3(&to_goal, &to_goal);
    float goal_distance = 0.0f;
    if (goal_distance_squared >= EPSILON) {  // if the goal is not on upper's origin
        goal_distance = sqrtf(goal_distance_squared);
        t5_vec_scale(&to_goal, &to_goal, 1.0f / goal_distance);
        t5_vec_cross(&axis, row(&frame, 0), &to_goal);  // turn axis = frame x crossed with the goal direction
        scratch = axis;
        float sine_squared = t5_vec_dot3(&axis, &axis);
        if (sine_squared < EPSILON) {  // if frame x already points at the goal (axis too short)
            copy_rows(upper, &frame, 3);
        } else {
            float sine = sqrtf(sine_squared);
            float cosine = t5_vec_dot3(row(&frame, 0), &to_goal);  // cosine of the turn angle = frame x dot goal direction
            scratch.y = cosine;
            t5_vec_scale(&axis, &axis, 1.0f / sine);
            T5Mat4 rotation;
            axis_rotation(&rotation, &axis, cosine, sine, crow(upper, 3));  // rotation about the axis
            premultiply(&rotation, &frame);
            *upper = rotation;
        }
        for (int row_index = 0; row_index < 3; row_index++)  // set lower's three rows to identity
            memcpy(lower->m[row_index], (float[4]){row_index == 0, row_index == 1, row_index == 2, 0}, sizeof(Row));
    } else {  // else the goal is on upper's origin
        copy_rows(upper, &frame, 3);
        copy_rows(lower, &frame, 3);
    }

    // bend: law of cosines at both joints
    if (goal_distance >= upper_length + lower_length) return;  // goal at or past full reach: the chain stays straight, done
    if (goal_distance <= fabsf(upper_length - lower_length)) {  // if the goal is closer than the difference of the lengths
        t5_vec_scale(row(lower, 0), row(lower, 0), -1.0f);  // fold the lower bone back: negate its x row
        t5_vec_scale(row(lower, 1), row(lower, 1), -1.0f);
        return;
    }
    float two_distance = goal_distance + goal_distance;
    float upper_cosine =  // cosine of the upper joint's angle (law of cosines)
        (length_squared_difference + goal_distance_squared) / (upper_length * two_distance);
    float upper_sine = 0.0f;
    float upper_sine_negative = -0.0f;
    if (!(upper_cosine <= 1.0f)) upper_cosine = 1.0f;  // if the cosine is over 1 (or not a number), use 1
    else if (upper_cosine < -1.0f) upper_cosine = -1.0f;
    else {  // else
        float upper_sine_size = sqrtf(1.0f - upper_cosine * upper_cosine);
        upper_sine = flip ? -upper_sine_size : upper_sine_size;  // sine sign depends on flip
        upper_sine_negative = flip ? upper_sine_size : -upper_sine_size;
    }
    T5Mat4 bend;
    z_rotation(&bend, upper_cosine, upper_sine, upper_sine_negative);
    premultiply(upper, &bend);  // apply the bend to upper

    float lower_cosine =  // cosine of the lower joint's angle (law of cosines)
        (goal_distance_squared - length_squared_difference) / (lower_length * two_distance);
    float lower_sine = 0.0f;
    if (!(lower_cosine <= 1.0f)) lower_cosine = 1.0f;  // if the cosine is over 1 (or not a number), use 1
    else if (scratch.y < -1.0f) lower_cosine = -1.0f;  // the code tests the stale lane, not c2
    else lower_sine = sqrtf(1.0f - lower_cosine * lower_cosine);
    if (flip) lower_sine = -lower_sine;  // flip changes the sine sign
    float bend_sine = fmaf(upper_sine, lower_cosine, upper_cosine * lower_sine);  // sine of the upper and lower angles added
    float bend_cosine = fmaf(upper_cosine, lower_cosine, -(upper_sine * lower_sine));
    z_rotation(&bend, bend_cosine, -bend_sine, bend_sine);  // bend about z the opposite way by that combined angle
    premultiply(lower, &bend);
}

// --- leg and arm

static T5Bone *bones(const T5LimbRig *limb_rig) { return limb_rig->skeleton ? limb_rig->rig->bones_b : limb_rig->rig->bones_a; }
static const int8_t *parents(const T5LimbRig *limb_rig) { return limb_rig->skeleton ? limb_rig->skel->parent_b : limb_rig->skel->parent_a; }

void t5_limb_world_of(const T5LimbRig *limb_rig, int32_t bone) {
    T5Bone *rig_bones = bones(limb_rig);
    int8_t parent = parents(limb_rig)[bone];
    T5Mat4 world_matrix =  // parent's world matrix, or the rig root's if no parent
        parent < 0 ? limb_rig->rig->root.world : rig_bones[parent].world;
    t5_mat_multiply(&world_matrix, &rig_bones[bone].local);
    rig_bones[bone].world = world_matrix;
}

static T5Vec4 *world_position(const T5LimbRig *limb_rig, int32_t bone) { return row(&bones(limb_rig)[bone].world, 3); }

// point + now - before, lane by lane; w kept
static void follow(T5Vec4 *point, const T5Vec4 *now, const T5Vec4 *before) {
    float point_w = point->w;
    t5_vec_add(point, point, now);
    point->w = point_w;
    t5_vec_subtract(point, point, before);
    point->w = point_w;
}

// upper and lower solved to reach the end bone's (moved) position; the end keeps its world rotation
void t5_limb_reach(const T5LimbRig *limb_rig, int32_t upper, int32_t lower, int32_t end, int32_t segment, bool flip) {
    T5Bone *rig_bones = bones(limb_rig);
    int8_t base = parents(limb_rig)[upper];
    t5_limb_two_bone(&rig_bones[upper].local, &rig_bones[lower].local,  // solve upper and lower so the chain reaches the end bone
        &rig_bones[base].world, limb_rig->state->segment_length[segment],
                     limb_rig->state->segment_length[segment + 1], world_position(limb_rig, end), flip);
    t5_limb_world_of(limb_rig, upper);
    t5_limb_world_of(limb_rig, lower);
    t5_mat_relative_rotation(&rig_bones[end].local,  // end bone local = its world rotation relative to lower's world
        &rig_bones[end].world, &rig_bones[lower].world);
}

// Leg 0 (right) and 1 (left): its bones, the sole points under the foot, and the side the toe tip lies to (mm).
static const struct { uint8_t thigh, shin, foot, toe, sole, heel; float tip_z; } LEGS[2] = {
    {BONE_R_THIGH, BONE_R_SHIN, BONE_R_FOOT, BONE_R_TOE, 24, 23, 60.0f},
    {BONE_L_THIGH, BONE_L_SHIN, BONE_L_FOOT, BONE_L_TOE, 26, 25, -60.0f},
};
static const struct { uint8_t upper, forearm, hand; } ARMS_OF[2] = {
    {BONE_R_UPPER_ARM, BONE_R_FOREARM, BONE_R_HAND}, {BONE_L_UPPER_ARM, BONE_L_FOREARM, BONE_L_HAND},
};

void t5_limb_leg(const T5LimbRig *limb_rig, int32_t leg, T5Vec4 *before) {
    const typeof(LEGS[0]) *leg_bones = &LEGS[leg];
    T5Vec4 *foot = world_position(limb_rig, leg_bones->foot);
    *before = *foot;  // remember the foot position before the correction
    if (!t5_limb_floor(limb_rig->state, LIMB_R_FOOT + leg, 0.0f, foot, world_position(limb_rig, leg_bones->sole), world_position(limb_rig, leg_bones->heel), limb_rig->paused,
                       limb_rig->world, limb_rig->world->limb_env.floor.origin_y))
        return;
    t5_limb_reach(limb_rig, leg_bones->thigh, leg_bones->shin, leg_bones->foot, 0, true);  // bend thigh and shin to the foot
    follow(world_position(limb_rig, leg_bones->toe), foot, before);  // toe follows the foot's move
    follow(world_position(limb_rig, leg_bones->sole), foot, before);
}

void t5_limb_arm(const T5LimbRig *limb_rig, int32_t arm) {
    int32_t upper = ARMS_OF[arm].upper, hand = ARMS_OF[arm].hand;
    T5Vec4 *hand_at = world_position(limb_rig, hand);
    float radius =  // radius = 50 plus 100 times how upright the hand's x axis points
        fmaf(fabsf(bones(limb_rig)[hand].world.m[0][1]), 100.0f, 50.0f);
    if (t5_limb_floor(limb_rig->state, LIMB_R_HAND + arm, radius, hand_at, hand_at, NULL, limb_rig->paused, limb_rig->world, limb_rig->world->limb_env.floor.origin_y)) t5_limb_reach(limb_rig, upper, ARMS_OF[arm].forearm, hand, 2, false);
}

// --- neck, head, toes

void t5_limb_neck(const T5LimbRig *limb_rig) {
    T5Vec4 *neck = world_position(limb_rig, 3);
    if (!t5_limb_floor(limb_rig->state, LIMB_NECK,  // keep neck above floor (radius 120), stop if not moved
        120.0f, neck, neck, NULL, limb_rig->paused, limb_rig->world, limb_rig->world->limb_env.floor.origin_y)) return;
    T5Vec4 from_chest, local_offset;
    t5_vec_subtract(&from_chest, neck, world_position(limb_rig, 2));  // offset from the chest to the neck
    T5Mat4 inverse = bones(limb_rig)[1].world;
    t5_mat_inverse(&inverse);
    t5_vec_times_mat(&local_offset, &from_chest, &inverse);
    t5_mat_frame_turn_x(&bones(limb_rig)[2].local, &local_offset);  // turn the chest bone so it points along that offset
    for (int32_t bone = 2; bone <= 4; bone++)  // update world matrices of the chest, neck and head
        t5_limb_world_of(limb_rig, bone);
}

void t5_limb_head(const T5LimbRig *limb_rig) {
    T5LimbState *limbs = limb_rig->state;
    float *tilt = &limbs->heights.head_tilt;
    float probe_length = sqrtf(t5_vec_dot3(&limbs->head_probe, &limbs->head_probe));
    float inverse_probe_length = probe_length == 0.0f ? 0.0f : 1.0f / probe_length;
    T5Vec4 probe_at;
    t5_vec_times_mat(&probe_at, &limbs->head_probe, &bones(limb_rig)[BONE_HEAD].world);
    float start_y = probe_at.y;
    if (!limb_rig->paused) {  // if the game is not paused
        if (t5_limb_floor(limbs, LIMB_HEAD, limbs->head_probe_radius,  // floor moved the head probe
            &probe_at, &probe_at, NULL, false, limb_rig->world, limb_rig->world->limb_env.floor.origin_y)) {
            float sine = inverse_probe_length * fabsf(probe_at.y - start_y);  // lean sine = height change over probe length
            if (!(sine <= 0.866025388f)) sine = 0.866025388f;  // cap the sine at that of 60 degrees
            if (bones(limb_rig)[BONE_CHEST].world.m[1][1] < 0.0f) sine = -sine;  // flip if the chest's y axis points down
            float kept = *tilt * 0.7f;  // keep 0.7 of the old tilt
            *tilt = fmaf(t5_asin(sine), 0.3f, kept);  // add 0.3 of the new angle
        } else {
            *tilt = *tilt * 0.7f;  // the tilt fades by 0.7 each frame
        }
    }
    T5Mat4 tilt_turn;
    t5_mat_z_turn(&tilt_turn, *tilt);
    t5_mat_rotation_product(&bones(limb_rig)[BONE_NECK].local,  // apply the tilt to the neck bone
        &bones(limb_rig)[BONE_NECK].local, &tilt_turn);
}

void t5_limb_toe(const T5LimbRig *limb_rig, int32_t toe, const T5Vec4 *before, bool hold, float hold_angle) {
    const typeof(LEGS[0]) *leg_bones = &LEGS[toe];
    int32_t foot = leg_bones->foot, bone = leg_bones->toe, sole = leg_bones->sole;
    T5Bone *rig_bones = bones(limb_rig);
    world_position(limb_rig, sole)->y +=  // sole rises by as much as the foot was lifted
        world_position(limb_rig, foot)->y - before->y;
    T5Vec4 tip;
    t5_vec_times_mat(&tip,  // tip in world space: 120 ahead of the sole, tip_z to the side
        &(T5Vec4){{120, 0, leg_bones->tip_z, 1}}, &rig_bones[sole].world);
    float angle = hold_angle;
    if (!hold) {  // if the toe is not being held
        float floor_y = limb_rig->world->limb_env.floor.origin_y;
        if (!(floor_y > tip.y)) return;  // if the tip is not under the floor, nothing to do
        tip.y = floor_y;
        limb_rig->state->below[0] |= 1u << (LIMB_R_FOOT + toe);  // mark this foot as near the floor
        T5Mat4 inverse = rig_bones[sole].world;
        t5_mat_inverse(&inverse);
        t5_vec_times_mat(&tip, &tip, &inverse);
        angle =  // angle = how far the toe must bend up to put its tip on the floor
            t5_fast_atan2(tip.y / -rig_bones[foot].world.m[0][1], sqrtf(fmaf(tip.z, tip.z, tip.x * tip.x)));
    }
    T5Mat4 turn;
    t5_mat_z_turn(&turn, angle);
    t5_mat_rotation_product(&rig_bones[bone].local, &turn, &rig_bones[bone].local);  // apply it to the toe bone
}

// --- hip drop


// smoothed toward asin of the floor's rise over the distance from `from` to the base point at `level`
static float drop_twist(float twist, const T5Vec4 *from, T5Vec3 base, float level, float origin_y) {
    T5Vec4 from_floor = *from, base_at = {{base.x, level, base.z, 0.0f}}, reach;
    from_floor.y = origin_y;
    t5_vec_subtract(&reach, &base_at, &from_floor);
    float sine =  // sine of the floor slope = floor rise over the distance
        t5_asin((level - origin_y) / t5_length3(reach.x, reach.y, reach.z));
    float add;
    if (!(sine <= 1.0f)) add = 0.2f;  // if the sine is over 1 (or not a number), add 0.2
    else if (sine < -1.0f) add = -0.2f;  // if the sine is under minus 1, add minus 0.2
    else add = sine * 0.2f;  // else add 0.2 of the sine
    return fmaf(twist, 0.8f, add);  // keep 0.8 of the old twist and add the new amount
}

// take the candidate (floor level y) when it beats `best` and the drop; the code's two compare forms differ on NaN
static void raise_drop(float *best, float *level, float candidate, float y, float drop, bool nan_takes) {
    bool beats =  // beats = candidate is higher than best (compare form depends on nan_takes)
        nan_takes ? !(*best >= candidate) : *best < candidate;
    if (beats && !(candidate <= drop)) {  // if it beats best and is above the drop
        *best = candidate;
        *level = y;
    }
}

// the drop the body should have this frame (T5HipDrop)
static void update_drop(const T5LimbRig *limb_rig, T5LimbBody *body) {
    T5LimbState *limbs = limb_rig->state;
    const T5LimbEnv *env = &limb_rig->world->limb_env;
    const T5Floor *env_floor = &env->floor;
    const T5Bone *rig_bones = bones(limb_rig);
    T5HipDrop *hip = &limbs->drop;
    float right_foot_up = rig_bones[16].world.m[0][1], left_foot_up = rig_bones[20].world.m[0][1];  // how much the feet point up
    float low = right_foot_up < left_foot_up ? right_foot_up : left_foot_up;
    float bias = (low + low) + 1.0f;  // char 13 would take 0 here, but its check always says no
    if (bias < 0.0f) bias = limbs->heights.leg_reach * -bias;  // if the bias is negative, scale it by the leg reach
    float target =  // target = the opponent's last drop if set, else the floor at the stage origin
        body->hip_drop_from_opponent ? limb_rig->opponent->drop_last : env_floor->origin_y;
    if (env->hip_bias) target += bias;  // if hip bias is on, add the foot bias to the target
    if (target < 0.0f) {  // if the target is under zero
        target = env_floor->origin_y;
        if (!(target >= 0.0f)) target = 0.0f;
    }

    float y = hip->height + body->position_y;  // y = last drop height plus the body's y position
    hip->height = y;
    if (env->hip_snap || limb_rig->drop->reset) {  // if a round reset forces a snap or the drop was reset
        hip->height = target;
        limb_rig->drop->reset = 0;
    } else if (target >= y) {  // else if the target is at or above y (the floor rises)
        hip->fall_speed = 0.0f;
        hip->height = fmaf(y, 0.2f, target * 0.8f);  // height = 0.2 of y plus 0.8 of the target
    } else {
        hip->fall_speed = hip->fall_speed - 6.5333333f;  // fall speed grows by 6.5333
        if (target > hip->fall_speed + y)  // if the fall would pass the target, land exactly on it
            hip->fall_speed = target - y;
        hip->height = y + hip->fall_speed;
    }

    // the floor under the base, the shins against the stage floor
    T5FloorCache *hips_floor = &limbs->floor[LIMB_HIPS];
    T5Vec3 base = translation(&limb_rig->rig->root.local);  // the base position
    T5StageHeight floor = t5_stage_height(limb_rig->world, base);  // floor height and material under the base
    hips_floor->y = floor.y;
    hips_floor->kind = cache_kind(floor.material);
    // highest of: the floor under the base + 140, the shins over the stage floor + 130 (upright, no state bits)
    float best = env_floor->none_y, level = env_floor->none_y;  // best and level start at the no-floor height
    raise_drop(&best, &level,  // candidate: floor under the base minus base y plus 140
        (hips_floor->y - base.y) + 140.0f, hips_floor->y, hip->height, true);
    if (!(fabsf(rig_bones[13].world.m[0][1]) >= 0.707106769f) &&  // pelvis x axis over 45 degrees off vertical and body state 0
        body->state == 0) {
        float ground_y = env_floor->origin_y;
        raise_drop(&best, &level,  // candidate from the right shin: floor minus its height plus 130
            (ground_y - rig_bones[15].world.m[3][1]) + 130.0f, ground_y, hip->height, true);
        raise_drop(&best, &level,  // same for the left shin, other compare form
            (ground_y - rig_bones[19].world.m[3][1]) + 130.0f, ground_y, hip->height, false);
    }
    if (best <= 0.0f) {  // if no candidate won
        hip->pelvis_twist = hip->pelvis_twist * 0.8f;  // pelvis twist fades by 0.8
        hip->spine_twist = hip->spine_twist * 0.8f;
    } else {  // else a floor candidate won
        limbs->below[0] |= 1u << LIMB_HIPS;  // mark the hips as near the floor
        hip->height = best;
        hip->fall_speed = -6.5333333f;
        hip->pelvis_twist = drop_twist(hip->pelvis_twist,  // pelvis twist follows the floor slope, measured from the left foot
            (const T5Vec4 *)rig_bones[20].world.m[3], base, level, env_floor->origin_y);
        hip->spine_twist = drop_twist(hip->spine_twist,  // spine twist follows the floor slope, measured from the neck
            (const T5Vec4 *)rig_bones[3].world.m[3], base, level, env_floor->origin_y);
    }
    hip->height = hip->height - body->position_y;  // store the height without the body's y position
}

void t5_limb_drop(const T5LimbRig *limb_rig, T5LimbBody *body) {
    T5LimbState *limbs = limb_rig->state;
    T5FloorCache *hips_floor = &limbs->floor[LIMB_HIPS];
    T5HipDrop *hip = &limbs->drop;
    if (body->move->flags & 8) {  // the drop follows the floor under the anchor
        T5Vec4 anchor = {{body->anchor_x, 0.0f, body->anchor_z, 0.0f}};  // y, w: stack leftovers in the game
        T5StageHeight floor = t5_stage_height(limb_rig->world, vec3_of(anchor));
        hips_floor->y = hip->height = floor.y;  // drop height and cache height = the floor under the anchor
        hips_floor->kind = cache_kind(floor.material);
        if (special_floor(hips_floor->kind))  // if that floor is the special floor, look up its height
            hips_floor->special_y = t5_stage_special(limb_rig->world, vec3_of(anchor), SPECIAL_FLOOR_LIST);
        return;
    }
    if (!limb_rig->paused) update_drop(limb_rig, body);  // if not paused, update the drop height
    T5Rig *rig = limb_rig->rig;
    rig->root.local.m[3][1] = rig->root.local.m[3][1] + hip->height;  // raise the base's local y by the drop height
    rig->root.world.m[3][1] = rig->root.world.m[3][1] + hip->height;
    if (limb_rig->skeleton == 1) limb_rig->drop->drop_b = hip->height;  // on skeleton B, remember this drop
    if (special_floor(hips_floor->kind)) {  // if the hips stand on the special floor
        hips_floor->special_y =  // look up the special floor height under the base
            t5_stage_special(limb_rig->world, translation(&rig->root.local), SPECIAL_FLOOR_LIST);
        if (!(rig->root.local.m[3][1] >= hips_floor->special_y + 140.0f))  // under special floor plus 140: mark hips near it
            limbs->below_special[0] |= 1u << LIMB_HIPS;
    }
}

// --- the pass

static const T5Vec4 *bone_position(const T5Bone *rig_bones, int32_t bone) { return (const T5Vec4 *)rig_bones[bone].world.m[3]; }

// Bones 0..21 posed at `frame` of the anim, with A's translations, the root offset in place of bone 0's.
// The pose goes into the shared scratch rig (the blend producer reads its translations).
static T5Bone *predict_pose(const T5LimbRig *limb_rig, const T5LimbBody *body, float frame) {
    T5Bone *predicted = limb_rig->scratch;
    T5Vec4 channels[T5_CHANNELS];
    t5_anim_sample(body->anim, frame, channels, true);  // sample the animation at this frame
    t5_pose_scale_root(channels, body->scale_xz, body->scale_xz_add, body->scale_y);
    for (int32_t bone = 21; bone >= 0; bone--)  // copy A's bone translations into the scratch, bones 21 down to 0
        memcpy(predicted[bone].local.m[3], limb_rig->rig->bones_a[bone].local.m[3], sizeof(Row));
    memcpy(predicted[0].local.m[3],  // bone 0 translation = root offset channels added, minus the root's y (z negated)
        (float[4]){channels[0].x + channels[1].x, (channels[0].y + channels[1].y) - limb_rig->rig->root.local.m[3][1],
                                          -channels[0].z - channels[1].z, 1.0f}, sizeof(Row));
    t5_skel_pose(predicted, limb_rig->skel, channels);  // pose the skeleton bones from the channels
    t5_skel_world(predicted, limb_rig->skel->parent_a, &limb_rig->rig->root.world, 22);  // world matrices of the 22 bones
    return predicted;
}

static bool aims_with_limbs(uint16_t hit_level) {
    return hit_level == HIT_LEVEL_HIGH_A ||  // true for the high levels and no height
        hit_level == HIT_LEVEL_NO_HEIGHT || hit_level == HIT_LEVEL_HIGH_B;
}

// On a move's first frame: where each hand or foot hitbox will be at the last active frame (predicted), raised
// by the floor level, turned up or down by the height difference to the opponent; aim_offset[i] is the offset.
static void predict_aims(const T5LimbRig *limb_rig, const T5LimbBody *body) {
    static const struct { uint8_t bone, base, limb; } AIM_LIMB[4] = {
        {BONE_R_HAND, BONE_R_UPPER_ARM, LIMB_R_HAND}, {BONE_L_HAND, BONE_L_UPPER_ARM, LIMB_L_HAND},
        {BONE_R_FOOT, BONE_R_THIGH, LIMB_R_FOOT}, {BONE_L_FOOT, BONE_L_THIGH, LIMB_L_FOOT},
    };
    T5LimbState *limbs = limb_rig->state;
    const T5Move *move = body->move;
    float ground_y = limb_rig->world->limb_env.floor.origin_y;
    const T5Bone *predicted =  // pose at the last active frame of the move
        predict_pose(limb_rig, body, (float)(move->last_active - 1));
    for (int32_t slot = 0; slot < 2; slot++) {  // loop through the two hitbox slots
        limbs->aim_on[slot] = 1;
        int32_t aim_index = 0;
        const T5HitPoint end = move->hit_pair[slot].end;
        while (aim_index < 4 &&  // find which of the four limbs the end point is a bone of
            !(end.kind == HIT_POINT_BONE && AIM_LIMB[aim_index].bone == end.index)) aim_index++;
        if (aim_index == 4 || !aims_with_limbs(body->hit_level)) {  // if none matches, or the hit level does not aim
            limbs->aim_on[slot] = 0;
            continue;
        }
        limbs->aim_start = body->anim_time;
        T5Vec4 tip = *bone_position(predicted, AIM_LIMB[aim_index].bone);
        T5Vec4 base = *bone_position(predicted, AIM_LIMB[aim_index].base);
        T5Vec4 reach;
        tip.y = ground_y + tip.y;  // raise the tip by the floor height
        base.y = ground_y + base.y;
        limbs->aim_end[slot] = tip;
        t5_vec_subtract(&reach, &tip, &base);
        float reach_length = sqrtf(t5_vec_dot3(&reach, &reach));
        t5_vec_normalize(&reach, &reach);
        float rise =  // own neck height minus the opponent's neck height plus their drop
            (ground_y + limbs->heights.neck_height) - (limb_rig->opponent->heights.neck_height + limb_rig->opponent->drop.height);
        float pitch = t5_fast_atan2(rise, 1200.0f);  // pitch angle from that height difference over 1200
        if (!(pitch <= 0.52359879f)) pitch = 0.52359879f;  // cap the pitch at 30 degrees up
        else if (pitch < -0.52359879f) pitch = -0.52359879f;
        T5Vec4 axis = {{0, 1, 0, 0}}, turn;
        t5_vec_cross(&axis, &reach, &axis);  // turn axis = reach crossed with up
        axis.w = reach.w;
        t5_quat_axis_angle(&turn, pitch, &axis);
        T5Mat4 turn_matrix;
        t5_mat_identity(&turn_matrix);
        t5_quat_to_mat(&turn_matrix, &turn);
        t5_vec_times_mat(&reach, &reach, &turn_matrix);  // turn the reach by the pitch
        t5_vec_scale(&reach, &reach, reach_length);  // give it back its length
        t5_vec_add(&limbs->aim_goal[slot], &base, &reach);  // aim goal = base plus the turned reach
        t5_vec_subtract(&limbs->aim_offset[slot],  // aim offset = goal minus the plain end point
            &limbs->aim_goal[slot], &limbs->aim_end[slot]);
        limbs->aim_limb[slot] = AIM_LIMB[aim_index].limb;
    }
}

// offset = toward * weight + offset * (1 - weight)
static void lerp_offset(T5Vec4 *offset, const T5Vec4 *toward, float weight) {
    T5Vec4 x, y;
    t5_vec_scale(&x, toward, weight);
    t5_vec_scale(&y, offset, 1.0f - weight);
    t5_vec_add(offset, &x, &y);
}

// Limb offsets of the aiming slots: ease in before the active window, hold the aim in it, then shrink 1 a frame.
static void blend_aims(const T5LimbRig *limb_rig, const T5LimbBody *body) {
    T5LimbState *limbs = limb_rig->state;
    const T5Move *move = body->move;
    float now = body->anim_time;
    for (int32_t slot = 0; slot < 2; slot++) {  // loop through the two hitbox slots
        if (!limbs->aim_on[slot]) continue;  // skip slots with aim off
        T5Vec4 *offset = &limbs->limb[limbs->aim_limb[slot]].offset;
        float first = (float)move->first_active;
        if (now >= first) {  // if the move has reached its first active frame
            if (now < (float)move->last_active) {  // inside the active window
                *offset = limbs->aim_offset[slot];
            } else if (t5_vec_dot3(offset, offset) <= 1.0f) {  // after the window: if the offset is almost gone (1 long or less)
                *offset = (T5Vec4){{0, 0, 0, 0}};
            } else {
                T5Vec4 step;
                t5_vec_normalize(&step, offset);
                t5_vec_scale(&step, &step, 1.0f);
                t5_vec_subtract(offset, offset, &step);  // shrink the offset by 1
            }
        } else if (t5_transition_class(body->transition) == TRANSITION_CARRY) {  // before active: if a carry transition
            float weight = now / first;  // weight = how far the anim is toward the first active frame
            *offset = (T5Vec4){{0, 0, 0, 0}};
            lerp_offset(offset, &limbs->aim_offset[slot], weight);
        } else {
            float span = first - limbs->aim_start;  // time from when the aim was set to the first active frame
            if (span > EPSILON)  // if there is time, ease toward the aim offset by progress through it
                lerp_offset(offset, &limbs->aim_offset[slot], (now - limbs->aim_start) / span);
            else *offset = limbs->aim_offset[slot];  // else take the full aim offset at once
        }
    }
}

static void aim(const T5LimbRig *limb_rig, const T5LimbBody *body) {
    if (body->move->first_active == 0 ||  // no active frames or target airborne: aims off
        body->target_airborne) {
        limb_rig->state->aim_on[0] = limb_rig->state->aim_on[1] = 0;
        return;
    }
    if (body->frame2 <= 1) {  // on the first frame of a move
        predict_aims(limb_rig, body);
        if (t5_transition_class(body->transition) != TRANSITION_CARRY)  // unless the move came by a carry transition, stop
            return;
    }
    blend_aims(limb_rig, body);  // blend the limb offsets toward the aims
}

// turn bone (13 or 1) by `angle` about its world z, or the horizontal axis normal to its world x when x is not vertical
static void twist(const T5LimbRig *limb_rig, int32_t bone, float angle, const T5Mat4 *inverse_root) {
    if (fabsf(angle) <= EPSILON) return;  // ignore tiny angles
    T5Bone *twisted = &bones(limb_rig)[bone];
    const T5Mat4 *world_matrix = &twisted->world;
    T5Vec4 axis, axis_turn, world_turn;
    if (fabsf(world_matrix->m[0][1]) < 0.999989986f) {  // if the bone's x axis is not near vertical
        axis = (T5Vec4){{0, 1, 0, 0}};
        t5_vec_cross(&axis, crow(world_matrix, 0), &axis);  // axis = x axis crossed with up (horizontal, normal to x)
        axis.w = world_matrix->m[0][3];
    } else {
        axis = *crow(world_matrix, 2);  // axis = the bone's z axis
    }
    t5_quat_axis_angle(&axis_turn, angle, &axis);
    t5_mat_to_quat(&world_turn, world_matrix);
    t5_quat_multiply(&axis_turn, &world_turn, &axis_turn);  // combine the two turns
    t5_quat_to_mat(&twisted->local, &axis_turn);
    t5_mat_rotation_product(&twisted->local, &twisted->local, inverse_root);  // take out the root's rotation
}

static void worlds(const T5LimbRig *limb_rig, const int8_t *list, int32_t count) {
    for (int32_t index = 0; index < count; index++)  // update the world matrix of each bone in the list
        t5_limb_world_of(limb_rig, list[index]);
}

void t5_limb_pass(const T5LimbRig *limb_rig, T5LimbBody *body) {
    static const int8_t BODY[] =  // bones whose worlds are updated first
        {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20};
    static const int8_t LOWER[] =  // lower body bones, toes and extra points
        {0, 13, 14, 15, 16, 18, 19, 20, 17, 21, 23, 25, 24, 26};
    static const int8_t SPINE[] = {1, 2, 3, 4}, ARMS[] = {5, 9, 6, 10, 7, 11, 8, 12};
    if (body->off) return;  // if the limb pass is off for this fighter, stop
    T5LimbState *limbs = limb_rig->state;
    limbs->below_special[0] = 0;
    limbs->below[0] = 0;
    worlds(limb_rig, BODY, sizeof BODY);
    if (!limb_rig->paused) {  // if the game is not paused
        for (int32_t limb_index = T5_LIMB_COUNT - 1; limb_index >= 0; limb_index--)  // every limb offset shrinks by 0.9 a frame
            t5_vec_scale(&limbs->limb[limb_index].offset, &limbs->limb[limb_index].offset, 0.9f);
        aim(limb_rig, body);  // update the hitbox aims
    }
    t5_limb_drop(limb_rig, body);  // lower the body toward the floor

    T5Mat4 inverse_root = bones(limb_rig)[0].world;
    t5_mat_inverse(&inverse_root);
    twist(limb_rig, BONE_PELVIS, limbs->drop.pelvis_twist, &inverse_root);  // twist the pelvis by its twist
    twist(limb_rig, BONE_SPINE, limbs->drop.spine_twist, &inverse_root);
    worlds(limb_rig, LOWER, sizeof LOWER);  // update worlds of the lower body
    T5Vec4 foot[2];
    t5_limb_leg(limb_rig, 0, &foot[0]);  // right leg
    t5_limb_leg(limb_rig, 1, &foot[1]);
    t5_limb_toe(limb_rig, 0, &foot[0], body->hold, body->hold_angle[0]);
    t5_limb_toe(limb_rig, 1, &foot[1], body->hold, body->hold_angle[1]);
    worlds(limb_rig, SPINE, sizeof SPINE);
    t5_limb_neck(limb_rig);
    worlds(limb_rig, ARMS, sizeof ARMS);
    t5_limb_head(limb_rig);
    t5_limb_arm(limb_rig, 1);  // left arm
    t5_limb_arm(limb_rig, 0);
    if (limb_rig->skeleton == 1 && !(body->move->flags & 8)) {  // B's drop is not kept
        T5Mat4 *root_local = &limb_rig->rig->root.local, *root_world = &limb_rig->rig->root.world;
        root_local->m[3][1] = root_local->m[3][1] - limb_rig->drop->drop_b;  // take B's drop off the base's local y
        root_world->m[3][1] = root_world->m[3][1] - limb_rig->drop->drop_b;
    }
    for (uint32_t *bit_words = limbs->below;  // loop over the near floor words, then the special floor words
        bit_words <= limbs->below_special; bit_words += 4) {
        uint32_t now = bit_words[0], last = bit_words[1];
        bit_words[1] = now;
        bit_words[3] = last & ~now;  // fell = was near, now not
        bit_words[2] = now & ~last;  // rose = now near, was not
    }
}

// --- limb init, snapshot and the long world pass

static const float BASE_LIFT = 1150.0f;  // the base starts this far above the floor until the first drop update
static const float MIN_HEAD_END = 10.0f, HEAD_END = 150.0f;  // shortest head end length, and the replacement for a shorter one

// head probe point and radius from the head end point length; the fmuls are separate roundings
static void head_probe(T5LimbState *limbs, T5HeadProbe probe, float head_length) {
    limbs->head_probe =  // probe point: x and z scaled by the head end length
        (T5Vec4){{head_length * probe.x, 0.0f, head_length * probe.z, 1.0f}};
    limbs->head_probe_radius = head_length * probe.radius;
}

static void clear_limb(T5Limb *limb, float none_y) {
    limb->push = limb->push_step = limb->world_now = limb->world_previous = (T5Vec4){{0}};
    limb->contact.x =  // no contact yet: contact point and origin level are minus none_y
        limb->contact.y = limb->contact.z = limb->origin_level = -none_y;
    limb->offset = (T5Vec4){{0}};
    limb->special_y = none_y;
}

void t5_limb_init(const T5LimbRig *limb_rig, const T5LimbBody *body) {
    T5LimbState *limbs = limb_rig->state;
    T5Rig *rig = limb_rig->rig;
    T5LimbEnv *env = &limb_rig->world->limb_env;
    const T5Bone *rig_bones = bones(limb_rig);
    T5Mat4 *base = &rig->root.local, *root_world = &rig->root.world;
    T5Floor *env_floor = &env->floor;
    if (env->floor_origin) {  // if the origin floor follows the fighter
        env_floor->origin_y =  // origin floor height = floor under the fighter
            t5_stage_floor(limb_rig->world, (T5Vec3){body->position_x, body->position_y, body->position_z});
    }
    for (int slot = 0; slot < 2; slot++) {
        limbs->aim_on[slot] = limbs->aim_limb[slot] = 0;  // aim off, no aim limb
        limbs->aim_offset[slot] = limbs->aim_end[slot] = limbs->aim_goal[slot] = (T5Vec4){{0}};
    }
    limbs->aim_start = 0.0f;
    float lift = body->scale_base * BASE_LIFT;  // base lift = scale times 1150
    limbs->heights.base_lift = lift;
    limbs->heights.neck_height =  // neck height = base lift plus the chest and neck lengths
        (lift + rig_bones[2].local.m[3][0]) + rig_bones[3].local.m[3][0];
    float reach =  // leg length from the hip to the sole
        ((rig_bones[23].local.m[3][0] + rig_bones[16].local.m[3][0]) + rig_bones[15].local.m[3][0]) + rig_bones[14].local.m[3][0];
    limbs->heights.leg_reach = fmaf(body->scale_base, -BASE_LIFT, reach);
    float *head_z = &bones(limb_rig)[BONE_HEAD_END].local.m[3][2];  // head end point
    if (*head_z < MIN_HEAD_END) *head_z = HEAD_END;  // if the head end is too short, set it to 150
    limb_rig->drop->reset = 1;  // ask the next drop update to take its target at once
    for (int limb_index = 0; limb_index < T5_LIMB_COUNT; limb_index++) clear_limb(&limbs->limb[limb_index], env_floor->none_y);

    base->m[3][0] = root_world->m[3][0] = body->position_x;  // base x at the fighter's x
    base->m[3][2] = root_world->m[3][2] = body->position_z;
    float floor_y = t5_stage_floor(limb_rig->world, translation(base));  // floor height under the base
    limbs->drop.height = floor_y;
    base->m[3][1] =  // base y = floor plus the fighter's y plus the base lift
        root_world->m[3][1] = (floor_y + body->position_y) + BASE_LIFT;
    for (int limb_index = 0; limb_index < T5_LIMB_COUNT; limb_index++)  // every floor cache starts at the floor height
        limbs->floor[limb_index] = (T5FloorCache){0, floor_y, floor_y};
    limbs->drop.fall_speed = limbs->drop.pelvis_twist = limbs->drop.spine_twist = 0.0f;
    limbs->drop_last = floor_y;
    limbs->heights.head_tilt = 0.0f;
    static const int8_t SEGMENT_BONE[5] = {15, 16, 7, 8, 3};  // thigh, shin, upper arm, forearm, neck
    float *length = limbs->segment_length;
    for (int segment = 0; segment < 4; segment++)  // read the four segment lengths from the bones
        length[segment] = rig_bones[SEGMENT_BONE[segment]].local.m[3][0];
    limbs->neck_length = rig_bones[SEGMENT_BONE[4]].local.m[3][0];
    memset(limbs->below, 0, sizeof limbs->below);  // clear the near floor masks
    memset(limbs->below_special, 0, sizeof limbs->below_special);
    limb_rig->drop->drop_b = floor_y;
    head_probe(limbs, body->head_probe, *head_z);
}

void t5_limb_snapshot(T5LimbState *limbs, const T5Bone *rig_bones) {
    static const int8_t LIMB_BONE[T5_LIMB_COUNT] = {BONE_R_FOOT, BONE_L_FOOT, BONE_R_HAND, BONE_L_HAND, BONE_NECK, BONE_HEAD, BONE_HIPS};  // feet, hands, neck, head, hips
    for (int limb_index = 0; limb_index < T5_LIMB_COUNT; limb_index++)  // previous point = current point, for every limb
        limbs->limb[limb_index].world_previous = limbs->limb[limb_index].world_now;
    for (int limb_index = 0; limb_index < T5_LIMB_COUNT; limb_index++)  // current point = world position of the limb's bone
        limbs->limb[limb_index].world_now = *crow(&rig_bones[LIMB_BONE[limb_index]].world, 3);
    limbs->drop_last = limbs->drop.height;  // remember the hip drop of this frame
}

void t5_limb_worlds_long(const T5LimbRig *skeleton_a, const T5LimbRig *skeleton_b) {
    t5_skel_world_a_extra(skeleton_a->rig, skeleton_a->skel);  // world matrices of skeleton A, long form
    t5_limb_snapshot(skeleton_a->state, skeleton_a->rig->bones_a);
    t5_limb_snapshot(skeleton_b->state, skeleton_b->rig->bones_b);
}

// --- skeleton build (motion step 13)

static void run_hook(const T5RigHook *hook, T5Rig *rig) {
    if (hook->run) hook->run(hook->context, rig);
}

void t5_skel_build(T5Rig *rig, const T5Skeleton *skeleton, const T5Vec4 pose[T5_CHANNELS], const T5LimbRig *limbs_b,
                   const T5LimbRig *limbs_a, T5LimbBody *body, const T5BuildHooks *hooks) {
    rig->root.world = rig->root.local;  // root world = root local
    t5_skel_pose(rig->bones_a, skeleton, pose);
    run_hook(&hooks->blend, rig);  // run the blend step
    run_hook(&hooks->look, rig);  // run the look-at step
    t5_rig_rotations_to_b(rig);  // set B's rotations from A's
    t5_limb_pass(limbs_b, body);  // limb pass on B
    t5_limb_pass(limbs_a, body);  // limb pass on A
}
