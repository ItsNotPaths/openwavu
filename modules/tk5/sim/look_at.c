// The look-at: what the hips, neck and head turn toward, and the smoothed aim of the neck and head.
// Left out: the eyes (cosmetic) and what only they read (the track flag, the aim point, the head frame).
#include <math.h>
#include <string.h>

#include "sim/bones.h"
#include "sim/constants.h"
#include "sim/look.h"
#include "sim/math.h"
#include "sim/quat.h"
#include "sim/state.h"

enum { FACE_OFFSET_BONE = 96 };  // a face bone; its z offset moves the eye point forward

static const T5Vec4 UP = {{0.0f, 1.0f, 0.0f, 1.0f}};
static const T5Vec4 NECK_AXIS_AHEAD = {{0.0f, LOOK_AHEAD, 0.0f, 1.0f}};
static const T5Vec4 HEAD_AXIS_AHEAD = {{LOOK_AHEAD, 0.0f, 0.0f, 1.0f}};
static const T5Vec4 HIPS_FORWARD = {{0.0f, 0.0f, HIPS_AHEAD, 1.0f}};

static T5Vec4 translation(const T5Mat4 *matrix) {
    T5Vec4 vector;
    memcpy(vector.v, matrix->m[3], sizeof vector.v);
    return vector;
}

static T5Mat4 moved_to(T5Mat4 matrix, T5Vec4 origin) {
    memcpy(matrix.m[3], origin.v, sizeof origin.v);
    return matrix;
}

// --- what the fighter sees

// The point the fighter looks from: the neck local moved forward by the head and face offsets, carried by the chest world of
// the last frame (the worlds are not rebuilt yet).
static T5Vec4 eye_point(const T5Rig *rig) {
    T5Mat4 neck = rig->bones_a[BONE_NECK].local, stack = rig->bones_a[BONE_CHEST].world;
    neck.m[3][0] = neck.m[3][0] + (rig->bones_a[BONE_HEAD].local.m[3][0] + rig->bones_a[FACE_OFFSET_BONE].local.m[3][2]);
    t5_mat_multiply(&stack, &neck);  // carry the neck point by the chest world
    return translation(&stack);
}

static T5AngleTrack track(T5AngleTrack last, float now) { return (T5AngleTrack){t5_wrap_full(now - last.last), now}; }

// The chest yaw off the facing. Stock subtracts the facing in binary steps, not radians (deviations table).
static float chest_yaw(const T5Mat4 *chest, float facing) {
    return t5_wrap_full(t5_fast_atan2(chest->m[1][0], chest->m[1][2]) - facing);
}

static float spine_tip(const T5Rig *rig) { return rig->bones_a[BONE_SPINE].world.m[0][1]; }

// --- when the fighter looks

typedef struct {
    bool look_on;  // aim at the opponent (else along the own neck and head)
    bool lock;     // lock on: the hips follow the opponent
} Gaze;

static bool in_look_window(const T5Move *move, int32_t frame) {
    return move->first_active == 0 || (move->last_active <= frame && move->length - LOOK_END_WINDOW.ticks <= frame);
}

static bool before_lock_window(const T5Fighter *f, const T5Move *move) {
    return move->first_active != 0 && f->frame < move->last_active && f->frame < f->can_act_frame - LOOK_LOCK_WINDOW.ticks;
}

// A NaN spine tip passes this test (fcmpu, blt).
static bool locks_on(const T5Fighter *f, const T5Rig *rig, const T5Move *move) {
    if (spine_tip(rig) < LOOK_UPRIGHT_MIN || f->health <= 0 || f->can_lock_look == 0) return false;
    return !before_lock_window(f, move);  // lock only once the early part of the move is over
}

static Gaze gaze_of(const T5World *w, const T5Fighter *f, const T5Rig *rig) {
    Gaze gaze = {false, false};  // by default look along the own body, no lock
    const T5Move *move = t5_move_at(w, f->move);
    bool looks = t5_phase_row(w).look_at && move != NULL && (move->flags & T5_MOVE_LOOKS) != 0;
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
    T5Vec4 neck, head;
} Targets;

// The opponent's head seen from `eyes`, the line to it turned by `tilt` about the level axis across it.
static T5Vec4 opponent_target(float tilt, T5Vec4 eyes, T5Vec4 opponent_head) {
    T5Vec4 offset = vec4_subtract(opponent_head, eyes);
    T5Vec4 axis = UP;
    T5Vec4 head_turn;
    T5Vec4 tipped;
    T5Mat4 turn = {};
    t5_vec_cross(&axis, &offset, &UP);  // axis: level line across the line to the opponent
    t5_vec_normalize(&axis, &axis);
    t5_quat_axis_angle(&head_turn, tilt, &axis);  // tilt the line up or down about that axis
    t5_quat_to_mat(&turn, &head_turn);
    offset.w = 0.0f;
    t5_vec_times_mat(&tipped, &offset, &turn);
    T5Vec4 target = vec4_add(eyes, tipped);  // the tilted line from the eyes gives the aim point
    target.w = 1.0f;
    return target;
}

// A point along the axis `ahead` of a bone, from `eyes`
static T5Vec4 along_bone(const T5Mat4 *bone_world, T5Vec4 eyes, T5Vec4 ahead) {
    T5Mat4 frame = moved_to(*bone_world, eyes);  // the bone orientation, placed at the eyes
    T5Vec4 out;
    t5_vec_times_mat(&out, &ahead, &frame);
    return out;
}

static Targets targets_of(const T5LookState *look, const T5Rig *rig, T5Vec4 eyes, T5Vec4 opponent_head, bool look_on) {
    if (look_on) {  // looking: both aim at the opponent
        T5Vec4 targets = opponent_target(look->gaze_tilt, eyes, opponent_head);
        return (Targets){targets, targets};
    }
    return (Targets){along_bone(&rig->bones_a[BONE_NECK].world, eyes, NECK_AXIS_AHEAD),  // not looking: straight ahead
                     along_bone(&rig->bones_a[BONE_HEAD].world, eyes, HEAD_AXIS_AHEAD)};
}

static T5Vec4 hips_ahead(const T5Rig *rig, float yaw) {
    T5Mat4 turn;
    T5Vec4 ahead;
    t5_mat_identity(&turn);
    t5_mat_rotate_y(&turn, t5_rad_to_angle_round(yaw));  // turn the forward point by the yaw
    t5_vec_times_mat(&ahead, &HIPS_FORWARD, &turn);
    T5Vec4 target = vec4_add(ahead, translation(&rig->bones_a[BONE_PELVIS].world));  // far point ahead of the pelvis
    target.w = 1.0f;
    return target;
}

// The hips turn toward the opponent when locked on, else ahead: along the body (thrown, not fighting, tipped over or KO),
// along the look yaw (a guard or a move that turns the hips that way), or along the facing.
static T5Vec4 hips_target(const T5World *w, const T5Fighter *f, const T5Rig *rig, T5Vec4 head_target, Gaze gaze, float facing) {
    bool tipped = !(spine_tip(rig) >= LOOK_UPRIGHT_MIN);  // NaN is tipped here
    if (t5_in_throw(f->throw.chain) || !t5_phase_row(w).look_at || tipped || f->health <= 0) return hips_ahead(rig, f->body_yaw);
    const T5Move *move = t5_move_at(w, f->move);
    bool along_look = (move != NULL && (move->flags & T5_MOVE_STATE_4) != 0) || t5_state_has(f->state, STATE_GUARD_BITS);
    if (along_look) return hips_ahead(rig, f->look_yaw);  // guard or hips-turning move: hips ahead along the look yaw
    if (!gaze.lock) return hips_ahead(rig, facing);  // not locked on: hips ahead along the facing
    T5Vec4 target = head_target;  // locked on: hips aim at the opponent, at pelvis height
    target.y = rig->bones_a[BONE_PELVIS].world.m[3][1];
    return target;
}

// --- neck and head

// The aim of a direction in the frame of the parent bone: the yaw from y toward z, the pitch toward -x
static T5AimState aim_of(T5Vec4 direction) {
    float yaw = t5_fast_atan2(direction.z, direction.y);  // sideways turn of the direction
    float pitch = t5_fast_atan2(-direction.x, t5_length_xz(direction.y, direction.z));  // up or down turn of the direction
    return (T5AimState){yaw, pitch, t5_aim_zone(yaw)};
}

// The direction from `eyes` to `target` in the frame of the parent bone, placed at the eyes.
static T5Vec4 seen_from(const T5Mat4 *parent_world, T5Vec4 eyes, T5Vec4 target) {
    T5Mat4 frame = moved_to(*parent_world, eyes);
    T5Vec4 direction = vec4_subtract(target, eyes);
    direction.w = 0.0f;
    t5_mat_transpose(&frame);
    t5_vec_times_mat(&direction, &direction, &frame);
    return direction;
}

// Aims one bone: steps its state toward the target, turns its local by it, and rebuilds its world. Mutates the rig.
static T5AimState aim_bone(T5Rig *rig, const T5Skeleton *skel, T5AimJoint joint, T5AimState last, T5Vec4 target,
                           T5Vec4 eyes, int32_t weight, T5AimFrame aim_frame) {
    T5AimState seen = aim_of(seen_from(&rig->bones_a[joint.parent].world, eyes, target));
    T5AimState next = seen;
    next.zone = t5_aim_zone_kept(last.zone, seen.zone);  // a target behind keeps its side until in front again
    if (weight > 0) {  // look has some weight: step the aim and turn the bone by it
        next = t5_aim_step(joint, last, seen, aim_frame).aim;
        rig->bones_a[joint.bone].local = t5_aim_turn(joint, rig->bones_a[joint.bone].local, next.yaw, next.pitch, weight);
    }
    t5_skel_bone_world(rig, skel, joint.bone);  // rebuild the bone world, so the next bone aims from it
    return next;
}

void t5_look_at(T5World *w, T5Fighter *f, const T5LimbRig *limb_rig) {
    T5Rig *rig = limb_rig->rig;
    const T5Fighter *opponent = w->fighters[(uint16_t)f->side_index == 0];  // the other fighter
    T5Vec4 opponent_head = translation(&opponent->rig.bones_a[BONE_NECK].world);
    T5Vec4 eyes = eye_point(rig);
    t5_skel_world_a(rig, limb_rig->skel);  // rebuild the worlds before aiming

    float facing = t5_angle_to_rad(f->facing);  // the look-at's angles are radians
    T5LookState *look = &f->look;
    const T5Mat4 *chest = &rig->bones_a[BONE_CHEST].world;
    look->chest_yaw = track(look->chest_yaw, chest_yaw(chest, facing));  // track how fast the chest turns sideways
    look->chest_pitch = track(look->chest_pitch, t5_asin(-chest->m[1][1]));  // track how fast the chest tips up or down

    bool snap = f->look_snap;
    Gaze gaze = gaze_of(w, f, rig);
    Targets targets = targets_of(look, rig, eyes, opponent_head, gaze.look_on);
    look->weight = look_weight(look->weight, gaze.look_on, snap);  // fade the look in or out
    t5_look_hips(w, f, limb_rig, gaze.lock, hips_target(w, f, rig, targets.head, gaze, facing));
    f->look_yaw = t5_wrap_full(look->hips.yaw + f->body_yaw);  // hips turn, off the body yaw, kept as the look yaw

    T5AimFrame aim_frame = {.fast = snap, .lock = gaze.lock, .look_on = gaze.look_on, .snap = snap, .hips = look->hips,
                    .chest_yaw_change = look->chest_yaw.change, .chest_pitch_change = look->chest_pitch.change};
    look->neck = aim_bone(rig, limb_rig->skel, T5_AIM_NECK, look->neck, targets.neck, eyes, look->weight, aim_frame);
    look->head = aim_bone(rig, limb_rig->skel, t5_aim_head(f->gaze), look->head, targets.head, eyes, look->weight, aim_frame);
    f->look_snap = false;  // the snap request is used up
}
