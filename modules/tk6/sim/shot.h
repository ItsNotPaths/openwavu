// The shot: one point that grows from a bone, then flies free (hitbox code 0x31, the game's block +0xc8). Its mode picks the
// bone and the start offset; the code has no character checks.
#ifndef T6_SHOT_H
#define T6_SHOT_H

#include "sim/fighter.h"

// Properties: the line starts growing at the start point of its mode; it stops and flies free.
void t6_shot_start(const T6World *w, T6Fighter *f, uint16_t pushback);
void t6_shot_stop(T6Fighter *f);
// Step 5 of the move change: a grown shot flies free.
void t6_shot_move_change(T6Fighter *f);
// Step 10 of the movement step: the line grows by its script, or flies free.
void t6_shot_step(const T6World *w, T6Fighter *f);
// The tip on its bone this frame (with the special points).
void t6_shot_tip(T6Fighter *f);

#endif
