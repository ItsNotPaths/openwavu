// The motion driver and the step 13 hook of the pose motion.
#ifndef T5_MOTION_DRIVER_H
#define T5_MOTION_DRIVER_H

#include "sim/pose.h"
#include "sim/world.h"

// Step 13 of the pose motion (not paused): the limb rigs and the skeleton build with the blend, look-at (not in game mode 10),
// then the joint copies and the wall solve. The face and finger poses are left out:
// A bones 51 and up keep their bind pose (code-map D3).
void t5_motion_build(T5World *w, T5Fighter *f);

// The default hooks of the pose motion: the blend producer and t5_motion_build.
extern const T5MotionHooks t5_default_motion_hooks;

// with the default hooks (the pose callback of the first-frame pass).
void t5_pose_motion_default(T5World *w, T5Fighter *f);

// The pose motion of both fighters (when forced or not skipped), the first-frame cancels, the wall push, then
// the skeleton worlds. Reads w->force and force_update of the fighters. The sound and UI calls are left out.
void t5_motion_driver(T5World *w);

// The sim part of round init for the motion step: the blend countdown, the
// forced first update, and per fighter the limb, look and scale init. The rigs must be bound already.
void t5_motion_setup(T5World *w);

// The model init of one fighter (the sim part), once per round init: the limb, look and scale
// init and the face layer start. The rig must be bound already.
void t5_motion_setup_fighter(T5World *w, T5Fighter *f);

#endif
