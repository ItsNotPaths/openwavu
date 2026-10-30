// steps 1, 2 and 6..12: root motion, blend bookkeeping and the blend of A locals (code-map 16.1, 16.3).
// The pause test is false for every call from the battle frame, so the paused branches are left out.
#include <math.h>
#include <string.h>

#include "sim/bones.h"
#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/pose.h"
#include "sim/stage.h"

static float negated_radians(int16_t angle) { return t5_angle_to_rad((int16_t)-angle); }
static bool blend_active(const T5MoveBlend *blend) {  // has a mode and time left
    return blend->mode != BLEND_OFF && blend->length.clock > 0;
}

// The root matrix row 3 is the base position in the game: one memory. The port keeps two copies and
// copies at the points where the game's other code changes one of them.
void t5_root_from_base(T5Fighter *f) {
    memcpy(f->rig.root.local.m[3], &f->base_position, sizeof f->base_position);
    f->rig.root.local.m[3][3] = f->base_position_w;
}

void t5_base_from_root(T5Fighter *f) {
    memcpy(&f->base_position, f->rig.root.local.m[3], sizeof f->base_position);
    f->base_position_w = f->rig.root.local.m[3][3];
}

// Step 6: sample the anim one clock step back and move the anchor so the base stays where it is.
static void repivot(const T5World *w, T5Fighter *f) {
    f->pivot_request = 0;
    float sample_time =  // anim time one clock step back
        fmaf((float)f->speed, -(1.0f / CLOCK_PER_FRAME), f->anim_time_at_clock) - 1.0f;
    if (sample_time < 0.0f) sample_time = 0.0f;
    T5Vec4 root[2];
    t5_anim_sample_root(&f->keys, t5_anim_at(w, f->anim_move), sample_time, root);  // root channels then, scaled to body size
    t5_pose_scale_root(root, f->scale_xz, f->scale_xz_add, f->scale_y);
    float root_x = root[0].x + root[1].x;  // the anim's root offset on the ground plane: both root channels added
    float root_z = root[0].z + root[1].z;
    const T5MoveBlend *blend = &f->blend;
    if (blend_active(blend)) {  // an active blend adds its offset, scaled by how far along it is
        float ratio = (float)blend->done.clock / (float)blend->length.clock;
        root_z = fmaf(ratio, blend->offset.z, root_z);
        root_x = fmaf(ratio, blend->offset.x, root_x);
    }
    float yaw = negated_radians(f->move_yaw);  // turn the offset by the move yaw, then place the anchor so the base does not move
    float sine = t5_sin(yaw);
    float cosine = t5_cos(yaw);
    f->position.z = f->base_position.z - fmaf(root_x, sine, -(root_z * cosine));
    f->position.x = f->base_position.x - fmaf(root_x, cosine, root_z * sine);
}

// Step 8: a blend toward a pending move right after a blend out resumes from the ratio the blend out reached.
static void blend_bookkeeping(T5MoveBlend *blend) {
    if (blend->mode == BLEND_TO_PENDING && blend->previous_mode == BLEND_OUT)  // take over from the ended blend out
        blend->resume = 1;
    else if (blend->resume != 0 && blend->mode != BLEND_TO_PENDING) blend->resume = 0;  // any other mode ends the takeover
    blend->previous_mode = blend->mode;  // keep this frame's mode for the next frame
}

// Step 9: the root matrix from the root angles and the facing; it keeps the old base position until step 11.
static void root_matrix(T5Fighter *f) {
    float euler[3] = {t5_angle_to_rad(f->root_angle_x), t5_angle_to_rad(f->facing), t5_angle_to_rad(f->root_angle_z)};
    t5_root_from_base(f);
    t5_mat_euler_zyx(&f->rig.root.local, euler);
    f->base_position_w = f->rig.root.local.m[3][3];  // the matrix is rebuilt from the identity: w is 1
}

static float blend_position(const T5MoveBlend *blend) {  // blend progress 0 to 1; a takeover runs from the saved ratio to 1
    float total = (float)blend->length.clock, elapsed = (float)blend->done.clock;
    if (blend->resume == 0) return elapsed / total;
    return fmaf((1.0f - blend->saved_ratio) / total, elapsed, blend->saved_ratio);
}

// Step 10: the hip translation with the blend offset, stored in root_local; returned for step 12. A move that follows the
// floor blends no lift, and its root_local height is the height over the floor.
static T5Vec3 hip_offset(const T5World *w, T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    bool follows_floor = (move->flags & T5_MOVE_FOLLOWS_FLOOR) != 0;
    T5MoveBlend *blend = &f->blend;
    T5Vec3 local = f->bone1;
    if (blend_active(blend)) {
        blend->ratio = blend_position(blend);  // blending: move the ratio on and fade the hip offset in
        if (follows_floor) blend->offset.y = 0.0f;  // a floor-following move blends no lift
        else if (f->change_hips != 0) blend->offset = (T5Vec3){};
        local.x = fmaf(blend->offset.x, blend->ratio, local.x);  // hips += offset * ratio
        local.y = fmaf(blend->offset.y, blend->ratio, local.y);
        local.z = fmaf(blend->offset.z, blend->ratio, local.z);
    } else {
        blend->ratio = 1.0f;  // no blend: full ratio
    }
    f->root_local = local;
    if (follows_floor && f->root_mode != T5_ROOT_HEIGHT_ONLY)  // height over the floor
        f->root_local.y = f->position.y - t5_stage_floor(w, f->position);
    return local;
}

// Step 12: on the ground the base walks by the anim root (turned by the move yaw) and the hip offset (turned by the facing);
// height only moves y; a launch leaves base_position at position.
static void root_motion(T5Fighter *f, T5Vec3 hips) {
    float move_cosine = t5_cos(negated_radians(f->move_yaw));  // anim root is turned by the move yaw, hips by the facing
    float move_sine = t5_sin(negated_radians(f->move_yaw));
    float facing_cosine = t5_cos(negated_radians(f->facing));
    float facing_sine = t5_sin(negated_radians(f->facing));
    T5Vec3 anim_root = f->bone0;  // bone0 is this frame's anim root step
    T5Vec3 *base = &f->base_position, *previous = &f->previous_position;
    if (f->root_mode == T5_ROOT_GROUND) {  // on the ground: the base walks on x and z and up on y
        base->x += fmaf(move_sine, anim_root.z,  // the anim root step and the hips step, each turned into the world
                        fmaf(facing_sine, hips.z, fmaf(facing_cosine, hips.x, move_cosine * anim_root.x)));
        base->y += hips.y + anim_root.y;
        base->z += (fmaf(facing_sine, hips.x, move_sine * anim_root.x) - facing_cosine * hips.z) - move_cosine * anim_root.z;
        previous->y += anim_root.y;  // previous gets the anim root step only, without the hips
        previous->z += fmaf(move_sine, anim_root.x, -(move_cosine * anim_root.z));
        previous->x += fmaf(move_cosine, anim_root.x, move_sine * anim_root.z);
    } else if (f->root_mode == T5_ROOT_HEIGHT_ONLY) {  // in the air: only the height moves
        base->y += hips.y + anim_root.y;
        previous->y += anim_root.y;
    }
}

void t5_pose_motion(T5World *w, T5Fighter *f, const T5MotionHooks *hooks) {
    t5_body_scale(w, f);  // scale the body, then count the scale blend down
    if (f->scale_blend > 0) f->scale_blend--;
    bool keep_hips = (t5_move_at(w, f->anim_move)->flags & T5_MOVE_KEEP_HIPS) != 0;  // some moves keep the sampled hips
    t5_pose_frame(&f->keys, f, t5_anim_at(w, f->anim_move), keep_hips, f->pose);
    if (f->pivot_request != 0) repivot(w, f);  // a re-pivot was asked for
    if (hooks != NULL && hooks->producer != NULL) hooks->producer(w, f);  // the producer hook can start or stop a blend
    blend_bookkeeping(&f->blend);
    root_matrix(f);
    T5Vec3 hips = hip_offset(w, f);
    f->base_position = f->position;  // base and previous position start from the fighter's position this frame
    f->previous_position = f->position;
    root_motion(f, hips);  // move the base by the root mode
    t5_root_from_base(f);
    if (hooks != NULL && hooks->build != NULL) hooks->build(w, f);  // then build the skeleton (hook)
}

// --- the blend of A locals , then the store

static float inverse_or_zero(float length) {
    if (length == 0.0f) return 0.0f;  // a zero length gives zero, not a division
    return 1.0f / length;
}

// Rows 0 and 1 of the local plus the delta times `ratio`, made orthonormal; row 2 = row 0 x row 1.
static void blend_bone(T5Mat4 *local, const T5Mat4 *delta, float ratio) {
    T5Vec4 blended[3], row[3], second_rest, along;  // blend each of the three rows toward the delta by ratio
    for (int row_index = 0; row_index < 3; row_index++) {
        t5_vec_scale(&blended[row_index], (const T5Vec4 *)delta->m[row_index], ratio);
        t5_vec_add(&blended[row_index], &blended[row_index], (const T5Vec4 *)local->m[row_index]);
        blended[row_index].w = 0.0f;
    }
    t5_vec_scale(&row[0], &blended[0],  // row 0: normalize
                 inverse_or_zero(t5_length3(blended[0].x, blended[0].y, blended[0].z)));
    row[0].w = 0.0f;
    t5_vec_scale(&along, &row[0], t5_vec_dot3(&blended[1], &row[0]));  // row 1: drop the part along row 0, normalize
    t5_vec_subtract(&second_rest, &blended[1], &along);
    t5_vec_scale(&row[1], &second_rest, inverse_or_zero(t5_length3(second_rest.x, second_rest.y, second_rest.z)));
    row[1].w = 0.0f;
    t5_vec_cross(&row[2], &row[0], &row[1]);  // row 2 is perpendicular to both
    row[2].w = row[0].w;
    for (int row_index = 0; row_index < 3; row_index++) memcpy(local->m[row_index], row[row_index].v, sizeof row[row_index].v);
}

// The hips (bone 0) are not blended.
void t5_pose_blend(void *fighter, T5Rig *rig) {
    T5Fighter *f = fighter;
    T5MoveBlend *blend = &f->blend;
    if (blend->mode != BLEND_OFF)  // hips (bone 0) are skipped; every other bone blends toward the pose delta
        for (int bone = BONE_SPINE; bone < T5_POSE_BONES; bone++)  // blend each bone by the current ratio
            blend_bone(&rig->bones_a[bone].local, &blend->delta[bone], blend->ratio);
    for (int bone = 0; bone < T5_POSE_BONES; bone++) f->stored[bone] = rig->bones_a[bone].local;  // store all bones' locals
    if (blend->mode == BLEND_OUT) blend->saved_ratio = blend->ratio;  // for a blend that takes over
}
