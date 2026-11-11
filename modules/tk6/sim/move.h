// Movement: the step of a fighter each frame and the pass over the fighters.
// Files: move.c (the step in game order, the passes), root_motion.c (position, turn and pushback), move_timers.c (counters,
// move end, the timers of hits), projectile.c (the shots, step 10: projectile.h). The guard stance is
// guard.c (guard.h). The face and hand calls of the game step are left out of move.c.
#ifndef T6_MOVE_H
#define T6_MOVE_H

#include "sim/world.h"

// --- root_motion.c

// Steps 0..9: entry, gravity, approach slide, launch and landing, forward push, drift, offset push, turn, spin, pushback.
void t6_move_motion(T6World *w, T6Fighter *f);

// Step 12: the turn around bone `pivot_bone` by the facing change since entry (`old_facing`), and the per-frame countdown of
// `cancel_lock`. Runs after the facing step.
void t6_move_pivot(T6Fighter *f);

// A displacement script, the shape of a pushback: `frames` frames of a constant step, then `curve_frames` entries of a curve read one a
// frame. The step of a frame is the sum of both.
typedef struct { T6Ref curve; int16_t frames, curve_frames; } T6Script;  // curve: cursor of the next entry; both counts run down
typedef struct { T6Script next; float step; } T6ScriptStep;  // next: script state after the frame; step: distance this frame
// `curve_bonus` is added to each curve entry if it is not zero.
T6ScriptStep t6_script_step(const T6World *w, T6Script script, float distance, float curve_bonus);

// --- move_timers.c

// Step 13: the timers, the active hitboxes, airborne, move end and touchdown, the throw and juggle counters. Runs after the pivot.
void t6_move_counters(const T6World *w, T6Fighter *f);

// Step 16: the forced counter hit and the repeat streak run out.
void t6_move_hit_timers(T6Fighter *f, const T6Fighter *opponent);
// Step 20: whether the fighter can leave the move (can_act).
void t6_move_update_can_act(const T6World *w, T6Fighter *f);
// Step 21: slow motion runs the fighter on every update_divider-th frame.
void t6_move_update_skip(const T6World *w, T6Fighter *f);

// --- move.c

// The whole step in game order.
void t6_move_step(T6World *w, T6Fighter *f);

// The step for the fighters (not while frozen) and the extras.
void t6_movement_pass(T6World *w);

// called by the motion driver: the first-frame cancels of the fighters. `pose` stands for the pose motion
// (the motion port plugs the full one). It runs after a taken or matched cancel, unless skip_motion or an inactive
// update_divider holds it back; the force_update bit of the fighter overrides that.
typedef void (*T6PoseMotion)(T6World *w, T6Fighter *f);
void t6_first_frame_pass(T6World *w, T6PoseMotion pose);

#endif
