// The move blend producer: it starts and stops the blend that eases the pose across a move change.
// At a start it samples two poses and stores their difference in f->blend.delta; the pose motion consumes it.
#ifndef T6_BLEND_H
#define T6_BLEND_H

#include <stdint.h>

#include "sim/fighter.h"
#include "sim/units.h"

// The hook for T6MotionHooks.producer. While w->blend_snap_left is above zero it resets the fighter; otherwise it stops and
// starts the blend by the move state, then runs the clock or samples the poses of a start.
void t6_blend_producer(T6World *w, T6Fighter *f);

// T6SceneCut (phase.h): the round and scene transitions that snap the pose.

// Called by the round and scene transitions. The pose snaps for the length of the cut; t6_blend_snap_step counts it down
// once per frame, after the poses.
void t6_scene_cut(T6World *w, T6SceneCut cut);
void t6_blend_snap_step(T6World *w);

void t6_blend_snapshot(T6Fighter *f);  // prev_move = move, root_local = bone1
void t6_blend_reset(T6Fighter *f);     // snapshot, the blend off, f->pose_scratch = the A locals
void t6_blend_clock(T6Fighter *f);     // one step of the clock of a running blend
int16_t t6_blend_pending_start_frame(const T6Fighter *f);  // the frame of the pending move the transition starts at

// A blend to start: a mode and the length asked for. BLEND_OFF: none.
typedef struct {
    enum T6BlendMode mode;
    T6BlendSpan asked;
} T6BlendStart;

[[nodiscard]] T6BlendStart t6_blend_start_in(const T6World *w, const T6Fighter *f);       // after a move change
[[nodiscard]] T6BlendStart t6_blend_start_out(const T6World *w, const T6Fighter *f);      // at the end of a move
[[nodiscard]] T6BlendStart t6_blend_start_pending(const T6World *w, const T6Fighter *f);  // toward a pending move
void t6_blend_start(T6Fighter *f, T6BlendStart start);  // takes a start (none: nothing)

#endif
