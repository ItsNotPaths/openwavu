// Look state and the aim of single bones: the neck and head turn and the hips.
#include "sim/look.h"

#include <math.h>
#include <string.h>

#include "sim/bones.h"
#include "sim/constants.h"
#include "sim/math.h"
#include "sim/quat.h"
#include "sim/units.h"

void t6_look_init(T6Fighter *f) {
    f->look_snap = false;  // no jump to the target is pending
    f->look = (T6LookState){.gaze_tilt = f->gaze.tilt, .hips_upper = T6_AIM_HIPS.limits.yaw_max,  // hips limits start wide
                           .hips_lower = T6_AIM_HIPS.limits.yaw_min};
    f->look_yaw = t6_wrap_full(t6_angle_to_rad(f->facing));  // the look starts along the facing
}

void t6_look_snap(T6World *w) {
    for (int index = 0; index < T6_FIGHTER_COUNT; index++) w->fighters[index]->look_snap = true;  // both jump to their target
}

void t6_look_limits(T6Fighter *f, float upper, float lower) {
    f->look.hips_upper = upper;  // set how far the hips may turn either way
    f->look.hips_lower = lower;
}

// --- the aimed joints and their turn rules

const T6AimJoint T6_AIM_HIPS = {
    .bone = BONE_HIPS, .parent = BONE_PELVIS,  // the hips turn, measured from the pelvis
    .limits = {.yaw_min = -LOOK_HIPS_LIMIT, .yaw_max = LOOK_HIPS_LIMIT},  // the hips turn this far each way, no pitch
    .rate = HIPS_RATE, .fast_rate = HIPS_RATE_FREE,  // share of the gap closed per frame: normal, and fast
};
const T6AimJoint T6_AIM_NECK = {
    .bone = BONE_NECK, .parent = BONE_CHEST, .pitch_axis = AXIS_Z, .yaw_axis = AXIS_X,  // the neck turns on the chest
    .limits = {-AIM_YAW_LIMIT, AIM_YAW_LIMIT, AIM_PITCH_DOWN, AIM_PITCH_UP, AIM_PITCH_HOLD},  // sideways, down, up, pitch hold
    .rate = AIM_RATE, .fast_rate = AIM_RATE_SNAP,  // share of the gap closed per frame: normal, and snapping
    .pitches = true, .stops_behind = true,  // looks up and down too, and holds its limit when the target is behind
    .chest_speeds_up = true, .leads_hips = true,  // goes faster against the chest, takes the hips lead
};
const T6AimJoint T6_AIM_HEAD = {
    .bone = BONE_HEAD, .parent = BONE_NECK, .pitch_axis = AXIS_Y, .yaw_axis = AXIS_Z,  // the head turns on the neck
    .fixed_count = 2, .fixed = {{AXIS_Z, QUARTER_TURN.bits}, {AXIS_Y, QUARTER_TURN.bits}},  // fixed quarter turns, after aim
    .limits = {-AIM_YAW_LIMIT, AIM_YAW_LIMIT, AIM_PITCH_DOWN, AIM_PITCH_UP, AIM_PITCH_HOLD},  // sideways, down, up, pitch hold
    .rate = AIM_RATE, .fast_rate = AIM_RATE_SNAP,  // share of the gap closed per frame: normal, and snapping
    .pitches = true, .stops_behind = true,  // looks up and down too, and holds its limit when the target is behind
    .chest_speeds_up = true, .leads_hips = true,  // goes faster against the chest, takes the hips lead
};

T6AimJoint t6_aim_head(T6Gaze gaze) {
    T6AimJoint head = T6_AIM_HEAD;
    if (gaze.head_turn.bits != 0) {  // this character holds the head turned a bit extra
        head.fixed[head.fixed_count] = (T6Turn){AXIS_Y, gaze.head_turn.bits};  // add it after the fixed turns
        head.fixed_count++;
    }
    return head;
}

static T6Mat4 axis_turn(T6Turn turn) {
    T6Mat4 matrix;
    t6_mat_identity(&matrix);
    if (turn.axis == AXIS_X) t6_mat_rotate_x(&matrix, turn.steps);  // turn about whichever axis the turn names
    if (turn.axis == AXIS_Y) t6_mat_rotate_y(&matrix, turn.steps);
    if (turn.axis == AXIS_Z) t6_mat_rotate_z(&matrix, turn.steps);
    return matrix;
}

// matrix, then the turn
static T6Mat4 then_turn(T6Mat4 matrix, T6Turn turn) {
    T6Mat4 turned = axis_turn(turn);
    t6_mat_multiply(&turned, &matrix);  // put the turn on top of the matrix
    return turned;
}

T6Mat4 t6_aim_turn(T6AimJoint joint, T6Mat4 pose, float yaw, float pitch, int32_t weight) {
    T6Mat4 aim = axis_turn((T6Turn){joint.pitch_axis, t6_rad_to_angle_round(pitch)});  // up-down turn first
    aim = then_turn(aim, (T6Turn){joint.yaw_axis, t6_rad_to_angle_round(yaw)});  // then the sideways turn
    for (int fixed_index = 0; fixed_index < joint.fixed_count; fixed_index++)  // then the fixed turns of the joint
        aim = then_turn(aim, joint.fixed[fixed_index]);
    T6Vec4 aim_turn, pose_turn;
    t6_mat_to_quat(&aim_turn, &aim);  // turn both as quaternions so they can blend
    t6_mat_to_quat(&pose_turn, &pose);
    t6_quat_blend(&aim_turn, (float)weight * (1.0f / (float)LOOK_WEIGHT_FULL), &pose_turn, &aim_turn);  // pose to aim, by weight
    T6Mat4 out = pose;
    t6_quat_to_mat(&out, &aim_turn);  // write the blended turn into the pose matrix
    return out;
}

// --- zones

enum T6AimZone t6_aim_zone(float yaw) {
    if (yaw < -AIM_BEHIND) return AIM_ZONE_BEHIND_LEFT;  // far to the left: behind on the left
    if (yaw > AIM_BEHIND) return AIM_ZONE_BEHIND_RIGHT;  // far to the right: behind on the right
    if (yaw > 0.0f) return AIM_ZONE_RIGHT;  // in front on the right
    return AIM_ZONE_LEFT;  // also NaN
}

bool t6_aim_crosses_behind(enum T6AimZone last, enum T6AimZone now) {
    return (now == AIM_ZONE_BEHIND_RIGHT && last == AIM_ZONE_BEHIND_LEFT) ||  // went from behind one side to behind the other
           (now == AIM_ZONE_BEHIND_LEFT && last == AIM_ZONE_BEHIND_RIGHT);
}

// A target behind keeps its zone until it is in front again, so the aim does not flip sides behind the back.
enum T6AimZone t6_aim_zone_kept(enum T6AimZone last, enum T6AimZone now) {
    if (!t6_aim_behind(now) || !t6_aim_behind(last)) return now;  // in front now or before: take the new zone
    return last;  // still behind: keep the old zone
}

// NaN and an empty range take the upper limit, as the game's compares do.
float t6_aim_clamp(float value, float low, float high) {
    float out = value;
    if (out < low) out = low;  // too low: raise to the lower limit
    if (!(out < high)) out = high;  // too high: cut to the upper limit
    return out;
}

// --- the aim step

// `rate` of the way, twice that (at most all of it) while the chest turns the other way faster than the step.
static float chase(T6AimJoint joint, float from, float target, float chest_change, float rate) {
    float gap = target - from;  // how far there is still to go
    float step = rate;
    if (joint.chest_speeds_up && chest_change * gap < 0.0f &&  // the chest turns the other way,
        fabsf(chest_change) > rate * fabsf(gap))  // faster than the step covers
        step = rate + rate;  // so go twice as far
    if (!(step < 1.0f)) step = 1.0f;  // never past the target
    return fmaf(step, gap, from);  // go that share of the gap
}

static float hips_lead(float yaw, T6AimFrame aim_frame) {
    if (aim_frame.lock && yaw * aim_frame.hips.goal < 0.0f)  // locked on, and the hips head the other way
        return yaw + (aim_frame.hips.goal - aim_frame.hips.yaw);
    return yaw;
}

static float yaw_goal(T6AimJoint joint, float yaw, enum T6AimZone last, enum T6AimZone now) {
    if (joint.stops_behind && now == AIM_ZONE_BEHIND_RIGHT && last == AIM_ZONE_BEHIND_RIGHT)  // stays behind on the right
        return joint.limits.yaw_max;  // so hold at the right limit
    if (joint.stops_behind && now == AIM_ZONE_BEHIND_LEFT && last == AIM_ZONE_BEHIND_LEFT)  // stays behind on the left
        return joint.limits.yaw_min;  // so hold at the left limit
    return t6_aim_clamp(yaw, joint.limits.yaw_min, joint.limits.yaw_max);  // otherwise aim at the yaw kept inside the limits
}

static float pitch_step(T6AimJoint joint, T6AimState last, T6AimState seen, float pitch, float yaw_now, T6AimFrame aim_frame, float rate) {
    if (joint.stops_behind && t6_aim_behind(seen.zone)) pitch = 0.0f;  // target behind: look level
    T6AimLimits limits = joint.limits;
    bool waits = aim_frame.look_on && !aim_frame.snap &&  // while looking on and not snapping, the pitch waits if
                 (fabsf(yaw_now - last.yaw) > limits.pitch_hold ||  // the yaw still moves much,
                  fabsf(pitch - last.pitch) < limits.pitch_hold);  // or the pitch changes little
    if (waits) return last.pitch;  // keep the old pitch
    return chase(joint, last.pitch, t6_aim_clamp(pitch, limits.pitch_down, limits.pitch_up),  // ease toward the pitch
                 aim_frame.chest_pitch_change, rate);
}

T6AimNext t6_aim_step(T6AimJoint joint, T6AimState last, T6AimState seen, T6AimFrame aim_frame) {
    float yaw = seen.yaw, pitch = seen.pitch;
    if (joint.leads_hips) yaw = hips_lead(yaw, aim_frame);  // add the hips lead to the aim
    if (t6_aim_crosses_behind(last.zone, seen.zone)) {  // target swung behind from one side to the other
        yaw = last.yaw;
        pitch = last.pitch;
    }
    float rate = joint.rate;
    if (aim_frame.fast) rate = joint.fast_rate;  // fast mode closes more of the gap
    float goal = yaw_goal(joint, yaw, last.zone, seen.zone);
    T6AimState next = {chase(joint, last.yaw, goal, aim_frame.chest_yaw_change, rate),  // yaw eases toward the goal
                       last.pitch, t6_aim_zone_kept(last.zone, seen.zone)};
    if (joint.pitches)  // only joints that look up and down step their pitch
        next.pitch = pitch_step(joint, last, seen, pitch, next.yaw, aim_frame, rate);
    return (T6AimNext){next, goal};
}

// --- hips

static const T6Vec4 DOWN = {{0.0f, -1.0f, 0.0f, 0.0f}};

// The yaw of the pelvis in the pose, off the body yaw; a pose turned more than a quarter counts as straight.
static float pelvis_offset(const T6Mat4 *pelvis, float body_yaw) {
    float offset = t6_wrap_full(t6_fast_atan2(-pelvis->m[1][0], -pelvis->m[1][2]) - body_yaw);  // pelvis turn in the pose
    if (fabsf(offset) > T6_HALF_PI) return 0.0f;  // more than a quarter turn counts as straight
    return offset;
}

// The hips aim steps off the pelvis offset; the state holds it off the body yaw.
static T6HipsAim hips_step(const T6LookState *look, float heading, float offset, bool fast) {
    T6AimJoint joint = T6_AIM_HIPS;
    joint.limits.yaw_min = look->hips_lower - offset;  // the limits are off the body yaw, so move them by the pelvis turn
    joint.limits.yaw_max = look->hips_upper - offset;
    T6AimState last = {t6_wrap_full(look->hips.yaw - offset), 0.0f, look->hips.zone};  // the old hips yaw, off the pelvis
    T6AimNext next = t6_aim_step(joint, last, (T6AimState){heading, 0.0f, t6_aim_zone(heading)},  // aim at the heading, no pitch
                                 (T6AimFrame){.fast = fast});
    return (T6HipsAim){t6_wrap_full(offset + next.aim.yaw), t6_wrap_full(offset + next.yaw_goal), next.aim.zone};  // add offset
}

// Not locked on, in a move without active frames, the hips turn fast.
static bool hips_fast(const T6World *w, const T6Fighter *f, bool lock) {
    return !lock && t6_move_at(w, f->move)->first_active == 0;
}

static T6Mat4 hips_turned(T6Mat4 hips, float yaw) {
    T6Vec4 turn, hips_quaternion;
    t6_quat_axis_angle(&turn, yaw, &DOWN);  // a turn about the vertical
    t6_mat_to_quat(&hips_quaternion, &hips);
    t6_quat_multiply(&hips_quaternion, &hips_quaternion, &turn);  // apply it to the hips
    t6_quat_to_mat(&hips, &hips_quaternion);
    return hips;
}

static const uint8_t TRUNK[] = {BONE_HIPS, BONE_SPINE, BONE_CHEST, BONE_NECK, BONE_HEAD, BONE_PELVIS};

// Mutates the rig: the hips local and the worlds and legs under it.
void t6_look_hips(const T6World *w, T6Fighter *f, const T6LimbRig *limb_rig, bool lock, T6Vec4 target) {
    T6Bone *bones_a = limb_rig->rig->bones_a;
    const T6Mat4 *pelvis = &bones_a[T6_AIM_HIPS.parent].world;
    float offset = pelvis_offset(pelvis, f->body_yaw);  // how far the pelvis is turned off the body yaw
    T6Vec4 pelvis_at;
    memcpy(pelvis_at.v, pelvis->m[3], sizeof pelvis_at.v);  // where the pelvis is
    T6Vec4 to_target = vec4_subtract(target, pelvis_at);  // from the pelvis to the target
    float heading = t6_wrap_full(t6_wrap_full(t6_fast_atan2(to_target.x, to_target.z) - f->body_yaw) - offset);  // target heading
    f->look.hips = hips_step(&f->look, heading, offset, hips_fast(w, f, lock));  // step the hips toward it

    bones_a[T6_AIM_HIPS.bone].local = hips_turned(bones_a[T6_AIM_HIPS.bone].local, f->look.hips.yaw);  // turn the hips bone
    for (size_t index = 0; index < sizeof TRUNK; index++)  // rebuild the world poses of the trunk bones
        t6_limb_world_of(limb_rig, TRUNK[index]);
    t6_limb_reach(limb_rig, BONE_R_THIGH, BONE_R_SHIN, BONE_R_FOOT, 0, true);  // solve the right leg again under the hips
    t6_limb_reach(limb_rig, BONE_L_THIGH, BONE_L_SHIN, BONE_L_FOOT, 0, true);  // and the left leg
}
