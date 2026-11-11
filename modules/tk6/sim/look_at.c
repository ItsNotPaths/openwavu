// The look-at: what the hips, neck and head turn toward, and the smoothed aim of the neck and head.
// Left out: the eyes (cosmetic, gamerender/face.c) and the track flag only they read.
#include <math.h>
#include <string.h>

#include "sim/bones.h"
#include "sim/constants.h"
#include "sim/look.h"
#include "sim/math.h"
#include "sim/quat.h"
#include "sim/state.h"

enum { FACE_OFFSET_BONE = 96 };  // a face bone; its z offset moves the eye point forward

static const T6Vec4 UP = {{0.0f, 1.0f, 0.0f, 1.0f}};
static const T6Vec4 NECK_AXIS_AHEAD = {{0.0f, LOOK_AHEAD, 0.0f, 1.0f}};
static const T6Vec4 HEAD_AXIS_AHEAD = {{LOOK_AHEAD, 0.0f, 0.0f, 1.0f}};
static const T6Vec4 HIPS_FORWARD = {{0.0f, 0.0f, HIPS_AHEAD, 1.0f}};

static T6Vec4 translation(const T6Mat4 *matrix) {
    T6Vec4 vector;
    memcpy(vector.v, matrix->m[3], sizeof vector.v);
    return vector;
}

static T6Mat4 moved_to(T6Mat4 matrix, T6Vec4 origin) {
    memcpy(matrix.m[3], origin.v, sizeof origin.v);
    return matrix;
}

// --- what the fighter sees

// The point the fighter looks from: the neck local moved forward by the head and face offsets, carried by the chest world of
// the last frame (the worlds are not rebuilt yet).
static T6Vec4 eye_point(const T6Rig *rig) {
    T6Mat4 neck = rig->bones_a[BONE_NECK].local, stack = rig->bones_a[BONE_CHEST].world;
    neck.m[3][0] = neck.m[3][0] + (rig->bones_a[BONE_HEAD].local.m[3][0] + rig->bones_a[FACE_OFFSET_BONE].local.m[3][2]);
    t6_mat_multiply(&stack, &neck);  // carry the neck point by the chest world
    return translation(&stack);
}

static T6AngleTrack track(T6AngleTrack last, float now) { return (T6AngleTrack){t6_wrap_full(now - last.last), now}; }

// The chest yaw off the facing. Stock subtracts the facing in binary steps, not radians.
static float chest_yaw(const T6Mat4 *chest, float facing) {
    return t6_wrap_full(t6_fast_atan2(chest->m[1][0], chest->m[1][2]) - facing);
}

static float spine_tip(const T6Rig *rig) { return rig->bones_a[BONE_SPINE].world.m[0][1]; }

// --- when the fighter looks

typedef struct {
    bool look_on;  // aim at the opponent (else along the own neck and head)
    bool lock;     // lock on: the hips follow the opponent
} Gaze;

static bool in_look_window(const T6Move *move, int32_t frame) {
    return move->first_active == 0 || (move->last_active <= frame && move->length - LOOK_END_WINDOW.ticks <= frame);
}

static bool before_lock_window(const T6Fighter *f, const T6Move *move) {
    return move->first_active != 0 && f->frame < move->last_active && f->frame < f->can_act_frame - LOOK_LOCK_WINDOW.ticks;
}

// A NaN spine tip passes this test (fcmpu, blt).
static bool locks_on(const T6Fighter *f, const T6Rig *rig, const T6Move *move) {
    if (spine_tip(rig) < LOOK_UPRIGHT_MIN || f->health <= 0 || f->can_lock_look == 0) return false;
    return !before_lock_window(f, move);  // lock only once the early part of the move is over
}

static Gaze gaze_of(const T6World *w, const T6Fighter *f, const T6Rig *rig) {
    Gaze gaze = {false, false};  // by default look along the own body, no lock
    const T6Move *move = t6_move_at(w, f->move);
    bool looks = t6_phase_row(w).look_at && move != NULL && (move->flags & T6_MOVE_LOOKS) != 0;
    if (looks && f->health > 0) {  // alive and the move looks: pick look and lock from the move timing
        gaze.look_on = in_look_window(move, f->frame);
        gaze.lock = locks_on(f, rig, move);
    }
    if (f->look_snap) gaze.look_on = true;  // a snap request forces looking at the opponent
    return gaze;
}

static int32_t look_weight(int32_t weight, bool look_on, bool snap) {
    if (snap) return LOOK_WEIGHT_FULL;  // snap: full look at once
    if (look_on) {  // looking: fade in one step a frame, up to full
        if (weight < LOOK_WEIGHT_FULL) return weight + 1;
        return weight;
    }
    if (weight - LOOK_WEIGHT_FADE < 0) return 0;  // not looking: fade out, never below zero
    return weight - LOOK_WEIGHT_FADE;
}

// --- targets

typedef struct {
    T6Vec4 neck, head;
} Targets;

// The opponent's head seen from `eyes`, the line to it turned by `tilt` about the level axis across it.
static T6Vec4 opponent_target(float tilt, T6Vec4 eyes, T6Vec4 opponent_head) {
    T6Vec4 offset = vec4_subtract(opponent_head, eyes);
    T6Vec4 axis = UP;
    T6Vec4 head_turn;
    T6Vec4 tipped;
    T6Mat4 turn = {};
    t6_vec_cross(&axis, &offset, &UP);  // axis: level line across the line to the opponent
    t6_vec_normalize(&axis, &axis);
    t6_quat_axis_angle(&head_turn, tilt, &axis);  // tilt the line up or down about that axis
    t6_quat_to_mat(&turn, &head_turn);
    offset.w = 0.0f;
    t6_vec_times_mat(&tipped, &offset, &turn);
    T6Vec4 target = vec4_add(eyes, tipped);  // the tilted line from the eyes gives the aim point
    target.w = 1.0f;
    return target;
}

// A point along the axis `ahead` of a bone, from `eyes`
static T6Vec4 along_bone(const T6Mat4 *bone_world, T6Vec4 eyes, T6Vec4 ahead) {
    T6Mat4 frame = moved_to(*bone_world, eyes);  // the bone orientation, placed at the eyes
    T6Vec4 out;
    t6_vec_times_mat(&out, &ahead, &frame);
    return out;
}

static Targets targets_of(const T6LookState *look, const T6Rig *rig, T6Vec4 eyes, T6Vec4 opponent_head, bool look_on) {
    if (look_on) {  // looking: both aim at the opponent
        T6Vec4 targets = opponent_target(look->gaze_tilt, eyes, opponent_head);
        return (Targets){targets, targets};
    }
    return (Targets){along_bone(&rig->bones_a[BONE_NECK].world, eyes, NECK_AXIS_AHEAD),  // not looking: straight ahead
                     along_bone(&rig->bones_a[BONE_HEAD].world, eyes, HEAD_AXIS_AHEAD)};
}

static T6Vec4 hips_ahead(const T6Rig *rig, float yaw) {
    T6Mat4 turn;
    T6Vec4 ahead;
    t6_mat_identity(&turn);
    t6_mat_rotate_y(&turn, t6_rad_to_angle_round(yaw));  // turn the forward point by the yaw
    t6_vec_times_mat(&ahead, &HIPS_FORWARD, &turn);
    T6Vec4 target = vec4_add(ahead, translation(&rig->bones_a[BONE_PELVIS].world));  // far point ahead of the pelvis
    target.w = 1.0f;
    return target;
}

// The hips turn toward the opponent when locked on, else ahead: along the body (thrown, not fighting, tipped over or KO),
// along the look yaw (a guard or a move that turns the hips that way), or along the facing.
static T6Vec4 hips_target(const T6World *w, const T6Fighter *f, const T6Rig *rig, T6Vec4 head_target, Gaze gaze, float facing) {
    bool tipped = !(spine_tip(rig) >= LOOK_UPRIGHT_MIN);  // NaN is tipped here
    if (t6_in_throw(f->throw.chain) || !t6_phase_row(w).look_at || tipped || f->health <= 0) return hips_ahead(rig, f->body_yaw);
    const T6Move *move = t6_move_at(w, f->move);
    bool along_look = (move != NULL && (move->flags & T6_MOVE_STATE_4) != 0) || t6_state_has(f->state, STATE_GUARD_BITS);
    if (along_look) return hips_ahead(rig, f->look_yaw);  // guard or hips-turning move: hips ahead along the look yaw
    if (!gaze.lock) return hips_ahead(rig, facing);  // not locked on: hips ahead along the facing
    T6Vec4 target = head_target;  // locked on: hips aim at the opponent, at pelvis height
    target.y = rig->bones_a[BONE_PELVIS].world.m[3][1];
    return target;
}

// --- neck and head

// The aim of a direction in the frame of the parent bone: the yaw from y toward z, the pitch toward -x
static T6AimState aim_of(T6Vec4 direction) {
    float yaw = t6_fast_atan2(direction.z, direction.y);  // sideways turn of the direction
    float pitch = t6_fast_atan2(-direction.x, t6_length_xz(direction.y, direction.z));  // up or down turn of the direction
    return (T6AimState){yaw, pitch, t6_aim_zone(yaw)};
}

T6Vec4 t6_look_seen_from(const T6Mat4 *frame_world, T6Vec4 eyes, T6Vec4 target) {
    T6Mat4 frame = moved_to(*frame_world, eyes);
    T6Vec4 direction = vec4_subtract(target, eyes);
    direction.w = 0.0f;
    t6_mat_transpose(&frame);
    t6_vec_times_mat(&direction, &direction, &frame);
    return direction;
}

// Aims one bone: steps its state toward the target, turns its local by it, and rebuilds its world. Mutates the rig.
static T6AimState aim_bone(T6Rig *rig, const T6Skeleton *skel, T6AimJoint joint, T6AimState last, T6Vec4 target,
                           T6Vec4 eyes, int32_t weight, T6AimFrame aim_frame) {
    T6AimState seen = aim_of(t6_look_seen_from(&rig->bones_a[joint.parent].world, eyes, target));
    T6AimState next = seen;
    next.zone = t6_aim_zone_kept(last.zone, seen.zone);  // a target behind keeps its side until in front again
    if (weight > 0) {  // look has some weight: step the aim and turn the bone by it
        next = t6_aim_step(joint, last, seen, aim_frame).aim;
        rig->bones_a[joint.bone].local = t6_aim_turn(joint, rig->bones_a[joint.bone].local, next.yaw, next.pitch, weight);
    }
    t6_skel_bone_world(rig, skel->parent_a, joint.bone);  // rebuild the bone world, so the next bone aims from it
    return next;
}

static const T6Fighter *opponent_of(const T6World *w, const T6Fighter *f) { return w->fighters[(uint16_t)f->side_index == 0]; }

void t6_look_at(T6World *w, T6Fighter *f, const T6LimbRig *limb_rig) {
    T6Rig *rig = limb_rig->rig;
    T6Vec4 opponent_head = translation(&opponent_of(w, f)->rig.bones_a[BONE_NECK].world);
    T6Vec4 eyes = eye_point(rig);
    t6_skel_world_a(rig, limb_rig->skel);  // rebuild the worlds before aiming

    float facing = t6_angle_to_rad(f->facing);  // the look-at's angles are radians
    T6LookState *look = &f->look;
    const T6Mat4 *chest = &rig->bones_a[BONE_CHEST].world;
    look->chest_yaw = track(look->chest_yaw, chest_yaw(chest, facing));  // track how fast the chest turns sideways
    look->chest_pitch = track(look->chest_pitch, t6_asin(-chest->m[1][1]));  // track how fast the chest tips up or down

    bool snap = f->look_snap;
    Gaze gaze = gaze_of(w, f, rig);
    Targets targets = targets_of(look, rig, eyes, opponent_head, gaze.look_on);
    look->weight = look_weight(look->weight, gaze.look_on, snap);  // fade the look in or out
    t6_look_hips(w, f, limb_rig, gaze.lock, hips_target(w, f, rig, targets.head, gaze, facing));
    f->look_yaw = t6_wrap_full(look->hips.yaw + f->body_yaw);  // hips turn, off the body yaw, kept as the look yaw

    T6AimFrame aim_frame = {.fast = snap, .lock = gaze.lock, .look_on = gaze.look_on, .snap = snap, .hips = look->hips,
                    .chest_yaw_change = look->chest_yaw.change, .chest_pitch_change = look->chest_pitch.change};
    look->neck = aim_bone(rig, limb_rig->skel, T6_AIM_NECK, look->neck, targets.neck, eyes, look->weight, aim_frame);
    look->head = aim_bone(rig, limb_rig->skel, t6_aim_head(f->gaze), look->head, targets.head, eyes, look->weight, aim_frame);
    f->look_snap = false;  // the snap request is used up
}

T6LookAim t6_look_aim(const T6World *w, const T6Fighter *f) {
    T6Vec4 eyes = eye_point(&f->rig);
    Gaze gaze = gaze_of(w, f, &f->rig);
    T6Vec4 opponent_head = translation(&opponent_of(w, f)->rig.bones_a[BONE_NECK].world);
    return (T6LookAim){eyes, targets_of(&f->look, &f->rig, eyes, opponent_head, gaze.look_on).head, gaze.look_on, gaze.lock};
}
