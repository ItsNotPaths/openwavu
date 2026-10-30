// The move blend producer: it starts and stops the blend that eases the pose across a move change.
// At a start it samples two poses and stores their difference in f->blend.delta; the pose motion consumes it.
#ifndef T5_BLEND_H
#define T5_BLEND_H

#include <stdint.h>

#include "sim/fighter.h"
#include "sim/units.h"

// The hook for T5MotionHooks.producer. While w->blend_snap_left is above zero it resets the fighter; otherwise it stops and
// starts the blend by the move state, then runs the clock or samples the poses of a start.
void t5_blend_producer(T5World *w, T5Fighter *f);

// T5SceneCut (phase.h): the round and scene transitions that snap the pose.

// Called by the round and scene transitions. The pose snaps for the length of the cut; t5_blend_snap_step counts it down
// once per frame, after the poses.
void t5_scene_cut(T5World *w, T5SceneCut cut);
void t5_blend_snap_step(T5World *w);

void t5_blend_snapshot(T5Fighter *f);  // prev_move = move, root_local = bone1
void t5_blend_reset(T5Fighter *f);     // snapshot, the blend off, f->pose_scratch = the A locals
void t5_blend_clock(T5Fighter *f);     // one step of the clock of a running blend
int16_t t5_blend_pending_start_frame(const T5Fighter *f);  // the frame of the pending move the transition starts at

// A blend to start: a mode and the length asked for. BLEND_OFF: none.
typedef struct {
    enum T5BlendMode mode;
    T5BlendSpan asked;
} T5BlendStart;

[[nodiscard]] T5BlendStart t5_blend_start_in(const T5World *w, const T5Fighter *f);       // after a move change
[[nodiscard]] T5BlendStart t5_blend_start_out(const T5World *w, const T5Fighter *f);      // at the end of a move
[[nodiscard]] T5BlendStart t5_blend_start_pending(const T5World *w, const T5Fighter *f);  // toward a pending move
void t5_blend_start(T5Fighter *f, T5BlendStart start);  // takes a start (none: nothing)

#endif
