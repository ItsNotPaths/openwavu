// The move interpreter (code-map 6): the move clock of a fighter, and the change to its pending move.
#ifndef T5_MOVE_CHANGE_H
#define T5_MOVE_CHANGE_H

#include "sim/world.h"

// The move clock of f, or the change to its pending move. opp is f's opponent.
// The stats calls, the aura effects and the screen cull of objects are outside the sim.
void t5_move_tick(T5World *w, T5Fighter *f, T5Fighter *opponent);
// The end properties, the throws (connect or clash), then the move tick of every object.
void t5_apply_moves_pass(T5World *w);

#endif
