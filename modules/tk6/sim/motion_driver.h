// The motion driver and the step 13 hook of the pose motion.
#ifndef T6_MOTION_DRIVER_H
#define T6_MOTION_DRIVER_H

#include "sim/pose.h"
#include "sim/world.h"

// Step 13 of the pose motion (not paused): the limb rigs and the skeleton build with the blend, look-at (not in game mode 10),
// then the joint copies and the wall solve. The face and finger poses are left out:
// A bones 51 and up keep their bind pose.
void t6_motion_build(T6World *w, T6Fighter *f);

// The default hooks of the pose motion: the blend producer and t6_motion_build.
extern const T6MotionHooks t6_default_motion_hooks;

// with the default hooks (the pose callback of the first-frame pass).
void t6_pose_motion_default(T6World *w, T6Fighter *f);

// The pose motion of both fighters (when forced or not skipped), the first-frame cancels, the wall push, then
// the skeleton worlds. Reads w->force and force_update of the fighters. The sound and UI calls are left out.
void t6_motion_driver(T6World *w);

// The sim part of round init for the motion step: the blend countdown, the
// forced first update, and per fighter the limb, look and scale init. The rigs must be bound already.
void t6_motion_setup(T6World *w);

// The model init of one fighter (the sim part), once per round init: the limb, look and scale
// init and the face layer start. The rig must be bound already.
void t6_motion_setup_fighter(T6World *w, T6Fighter *f);

#endif
