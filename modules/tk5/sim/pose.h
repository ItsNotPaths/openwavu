// Fighter pose: the anim sample and root of the pose motion.
#ifndef T5_POSE_H
#define T5_POSE_H

#include <stdbool.h>

#include "sim/anim.h"
#include "sim/skel.h"
#include "sim/world.h"

// Sample `anim` at f->anim_time - 1 (keep_hips: bit 0 of the anim move's flags), scale the root by f's
// scales, and set bone0, bone1, root_offset and body_yaw.
void t5_pose_frame(T5Fighter *f, const T5Anim *anim, bool keep_hips,
                   T5Vec4 pose[T5_CHANNELS]);  // steps 3..5

// Body scale of f: scale_xz, scale_y and the vertical blend. A throw takes the partner's scale (0.8 / 0.2 mix); a rider
// (T5Move.rides_partner) is lifted by the partner's head height (not stock, docs/rewrite.md deviations).
void t5_body_scale(const T5World *w, T5Fighter *f);
void t5_fight_body_scale(const T5World *w, T5Fighter *f);  // the body scale of a fight pose


// What the motion step leaves to other slices. A null hook does nothing.
typedef struct {
    void (*producer)(T5World *w, T5Fighter *f);  // blend producer (step 7; t5_blend_producer in t5/blend.h, slice S6). Null: no producer
    // Step 13: t5_skel_build with t5_pose_blend and the look-at, then the walls (t5_motion_build). The face and finger poses
    // are not ported (D3). Runs with the root matrix and the base final.
    void (*build)(T5World *w, T5Fighter *f);
} T5MotionHooks;

// steps 1..12: body scale, anim sample and root, re-pivot, blend bookkeeping, root matrix, root motion by
// root_mode. Sets pose, bone0, bone1, body_yaw, position, base_position, previous_position, root_local and the root
// matrix; then step 13.
void t5_pose_motion(T5World *w, T5Fighter *f, const T5MotionHooks *hooks);

// The root matrix row 3 and the base position are one memory in the game: copy one to the other.
void t5_root_from_base(T5Fighter *f);
void t5_base_from_root(T5Fighter *f);

// The blend of the A locals of bones 1..21 by f->blend.delta times f->blend.ratio (while a blend runs), then the store of
// the A locals in f->stored. A T5BuildHooks.blend run: `fighter` is the T5Fighter.
void t5_pose_blend(void *fighter, T5Rig *rig);

#endif
