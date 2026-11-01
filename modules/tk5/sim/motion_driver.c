#include "sim/motion_driver.h"

#include <assert.h>
#include <string.h>

#include "sim/blend.h"
#include "sim/constants.h"
#include "sim/collision.h"
#include "sim/fighter.h"
#include "sim/look.h"
#include "sim/move.h"

enum { GAME_MODE_FREE_CAMERA = 10 };  // a viewer mode: no look-at

// The persistent limb globals stay in the world; none_y and the mode flags are read fresh.
static void refresh_limb_env(T5World *w) {
    T5LimbEnv *env = &w->limb_env;  // the world's shared limb env
    env->floor.none_y = -w->stage_depth;  // no-floor height: minus the stage depth
    env->hip_snap = w->force != 0;  // snap the hips when the world is forced
    env->hip_bias = !t5_phase_row(w).fight_pose;  // bias the hips by foot height unless this is a fight pose
}

// --- the limb rigs and the fighter fields the limb code reads

typedef struct { T5LimbRig skeleton_a, skeleton_b; T5LimbBody body; } Limbs;  // the A and B limb rigs and the body data

static T5LimbBody limb_body(const T5World *w, const T5Fighter *f) {
    const T5Fighter *target = t5_object(w, f->target);  // the target fighter
    return (T5LimbBody){  // pack the fighter's limb inputs
        .off = f->limbs_off,
        .frame2 = f->frame2,
        .anim_time = f->anim_time,
        .hit_level = f->hit_level,
        .transition = f->applied_transition,
        .move = t5_move_at(w, f->move),  // the current move
        .target_airborne = t5_off_ground(target),  // is the target off the ground
        .position_y = f->position.y,
        .anchor_x = f->previous_position.x,  // the anchor is the position at the start of the frame
        .anchor_z = f->previous_position.z,
        .bone1_y = f->bone1.y,
        .hip_drop_from_opponent = f->hip_drop_from_opponent,
        .in_window = f->in_air_window,  // in the air window of its move
        .state = f->state,
        .anim = t5_anim_at(w, f->anim_move),  // the anim of the anim move
        .scale_xz = f->scale_xz,
        .scale_xz_add = f->scale_xz_add,
        .scale_y = f->scale_y,
        .position_x = f->position.x,
        .position_z = f->position.z,
        .scale_base = f->scale_base,
        .head_probe = f->body.head_probe,
    };
}

static Limbs limbs_of(T5World *w, T5Fighter *f) {  // gather the limb rigs and inputs of one fighter
    const T5Fighter *peer = w->fighters[(uint16_t)f->side_index == 0];  // the other fighter
    refresh_limb_env(w);  // refresh the env first
    const T5Skeleton *skeleton = &w->data[f->data]->skeleton;  // the skeleton of the fighter's model data
    return (Limbs){  // both limb rigs and the body
        .skeleton_a = {&f->rig, skeleton, 0, &f->limbs_a, &peer->limbs_a, w, false, f->pose_scratch, &f->limb_drop},
        .skeleton_b = {&f->rig, skeleton, 1, &f->limbs, &peer->limbs, w, false, f->pose_scratch, &f->limb_drop},
        .body = limb_body(w, f),
    };
}

// The wall solve and the requirements read the world positions of the A bones as the fighter's joints.
static void copy_joints(T5Fighter *f) {
    for (int bone = 0; bone < T5_BONES_A; bone++)  // copy each A bone's world position to joints
        memcpy(f->joints[bone].v, f->rig.bones_a[bone].world.m[3], sizeof f->joints[bone].v);
}

// --- step 13

typedef struct { T5World *w; T5Fighter *f; T5LimbRig limb_rig; } LookCall;  // what the look hook needs

static void look_hook(void *context, T5Rig *rig) {
    LookCall *call = context;
    (void)rig;
    if (call->w->mode != GAME_MODE_FREE_CAMERA) t5_look_at(call->w, call->f, &call->limb_rig);  // look unless in free camera
}

void t5_motion_build(T5World *w, T5Fighter *f) {  // build one fighter's motion
    Limbs limbs = limbs_of(w, f);
    LookCall call = {w, f, limbs.skeleton_a};  // the look hook gets this fighter and the A rig
    T5BuildHooks hooks = {.blend = {t5_pose_blend, f}, .look = {look_hook, &call}};  // the blend hook and the look hook
    t5_skel_build(&f->rig, limbs.skeleton_a.skel, f->pose, &limbs.skeleton_b, &limbs.skeleton_a,  // build with the hooks
                  &limbs.body, &hooks);
    t5_base_from_root(f);  // the hip drop moved the root
    copy_joints(f);  // save the joints from the new bones
    t5_wall_solve(w, f);  // find the wall contacts and the push
}

const T5MotionHooks t5_default_motion_hooks = {.producer = t5_blend_producer, .build = t5_motion_build};  // blend, then build

void t5_pose_motion_default(T5World *w, T5Fighter *f) { t5_pose_motion(w, f, &t5_default_motion_hooks); }  // default hooks

// --- the motion driver

// The gate of the pose motion and of the world pass: forced, or not held back by the move step.
static bool motion_runs(const T5World *w, int side) {
    const T5Fighter *f = w->fighters[side];
    bool forced = w->force != 0 || f->force_update;  // forced by the world or by the fighter's flag
    return forced || (!f->skip_motion && f->update_divider != -1);  // not skipped, and the divider is not inactive
}

// (the A worlds with the face and finger bones, the limb snapshots), then the B worlds
static void settle_worlds(T5World *w, T5Fighter *f) {  // settle the worlds of one fighter
    Limbs limbs = limbs_of(w, f);
    t5_limb_worlds_long(&limbs.skeleton_a, &limbs.skeleton_b);  // A worlds in long form and the limb snapshots
    t5_skel_world_b(&f->rig, limbs.skeleton_a.skel);  // B worlds
    copy_joints(f);  // save the joints from the new A worlds
}

void t5_motion_driver(T5World *w) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++)  // loop through fighters, pose each one that runs
        if (motion_runs(w, side)) t5_pose_motion_default(w, w->fighters[side]);
    t5_first_frame_pass(w, t5_pose_motion_default);  // first-frame cancels; poses the moves that start
    t5_wall_apply(w);  // apply the wall pushes
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) t5_root_from_base(w->fighters[side]);  // the wall push moved the base
    for (int side = 0; side < T5_FIGHTER_COUNT; side++)  // loop through fighters, settle each one that runs
        if (motion_runs(w, side)) settle_worlds(w, w->fighters[side]);
    t5_blend_snap_step(w);  // count the snap down one frame
}

// --- round init

// The bind pose of the model (the inline part of the model init): the rig as the host bound it, but the B translations stay.
static void rebind(const T5World *w, T5Fighter *f) {
    float kept[T5_BONES_B][4];
    for (int bone = 0; bone < T5_BONES_B; bone++)  // save the B translations
        memcpy(kept[bone], f->rig.bones_b[bone].local.m[3], sizeof kept[bone]);
    f->rig = w->data[f->data]->bind;
    for (int bone = 0; bone < T5_BONES_B; bone++)  // put the saved B translations back
        memcpy(f->rig.bones_b[bone].local.m[3], kept[bone], sizeof kept[bone]);
}

void t5_motion_setup_fighter(T5World *w, T5Fighter *f) {  // setup one fighter's rig, limbs, look and scale
    rebind(w, f);  // bind the model's rig
    Limbs limbs = limbs_of(w, f);
    t5_skel_world_b(&f->rig, limbs.skeleton_a.skel);  // B world matrices
    f->bone1 = (T5Vec3){};  // clear the hip translation
    t5_limb_init(&limbs.skeleton_a, &limbs.body);  // init the A limbs
    t5_limb_init(&limbs.skeleton_b, &limbs.body);  // init the B limbs
    t5_base_from_root(f);  // take the base from the root
    t5_look_init(f);  // init the look-at
    f->scale_xz = f->scale_base;  // start the body at its base scale
    f->scale_y = f->scale_base;
    f->previous_scale_y = f->scale_base;  // the previous y scale starts at base too
    f->scale_blend = 0;  // no scale blend running
    t5_limb_worlds_long(&limbs.skeleton_a, &limbs.skeleton_b);  // A worlds and limb snapshots
    copy_joints(f);  // save the joints
}

void t5_motion_setup(T5World *w) {  // round start: setup both fighters
    assert(w->stage != NULL);  // a stage must be loaded
    t5_scene_cut(w, T5_CUT_ROUND);  // start the round's pose snap
    w->force = 1;  // force a full update this frame
    w->limb_env.floor_origin = true;  // floor the origin under the fighters
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) t5_motion_setup_fighter(w, w->fighters[side]);  // setup each fighter
}
