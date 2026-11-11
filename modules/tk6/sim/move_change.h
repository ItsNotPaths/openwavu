// The move interpreter: the move clock of a fighter, and the change to its pending move.
#ifndef T6_MOVE_CHANGE_H
#define T6_MOVE_CHANGE_H

#include "sim/world.h"

// The move clock of f, or the change to its pending move. opp is f's opponent.
// The stats calls, the aura effects and the screen cull of objects are outside the sim.
void t6_move_tick(T6World *w, T6Fighter *f, T6Fighter *opponent);
// The end properties, the throws (connect or clash), then the move tick of every object.
void t6_apply_moves_pass(T6World *w);

#endif
