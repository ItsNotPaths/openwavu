// The decide pass (code-map 5, 15): at the end of the frame each object picks the move it plays next.
#ifndef T5_DECIDE_H
#define T5_DECIDE_H

#include <stdbool.h>

#include "sim/world.h"

// T5Fighter.reaction_facing (`PROP_REACTION_TURNED`, `PROP_REACTION_LOOK`): where a reaction starts facing.
enum T5ReactionFacing : uint8_t {
    REACTION_FACING_HIT,     // toward the hit
    REACTION_FACING_TURNED,  // turned half a circle: the reaction turns the fighter around
    REACTION_FACING_LOOK,    // the look direction; the reaction turns with its anim
};

// T5Fighter.launch_index: the generic launches of a fighter hit in the air (moves T5_ALIAS_LAUNCH + entry).
enum T5LaunchEntry : int16_t {
    LAUNCH_PLAIN, LAUNCH_LOW, LAUNCH_DOWN_FRONT_RIGHT, LAUNCH_DOWN_BACK_LEFT, LAUNCH_RIGHT, LAUNCH_LEFT,
};

// on the requirement layer: the cancel list that starts at `first` in data slot `set`, scanned at `frame`.
// The group cancels and input sequences come from the moveset_scan slot of f; input_window gets the T5_OPTION_INPUT flag.
const T5Cancel *t5_cancel_walk(T5World *w, T5Fighter *f, const T5Fighter *opponent, uint32_t set, uint32_t first, int32_t frame,
                               bool *input_window);
// The first-frame cancels of f (T5_OPTION_FIRST_FRAME).
enum T5FirstFrame {
    FIRST_FRAME_NONE,     // no move start, or no first-frame cancel passed
    FIRST_FRAME_TAKEN,    // a move was scheduled: it starts this frame
    FIRST_FRAME_MATCHED,  // entries passed without one that stops the scan
};
enum T5FirstFrame t5_first_frame_select(T5World *w, T5Fighter *f, T5Fighter *opponent);
// The reaction move of a hit from the reaction list of f (the attacker is not read).
void t5_reaction_move(T5World *w, T5Fighter *f);
// The generic launch of a fighter hit in the air, by the side of the hit.
void t5_juggle_reaction(const T5World *w, T5Fighter *f);
// The KO move (T5_ALIAS_KO) of a fighter with no health left.
void t5_ko_move(T5World *w, T5Fighter *f);
// The main cancel scan of a fighter, with the lookahead past a move end. opp is f's opponent.
void t5_scan_cancels(T5World *w, T5Fighter *f, T5Fighter *opponent);
// A fighter that was hit answers with the first option 2 cancel of its move that is in its window and
// passes its input and requirements (a reversal). `opponent` is the attacker.
void t5_reversal(T5World *w, T5Fighter *f, T5Fighter *opponent);
// Both fighters, in turn order.
void t5_reversals_pass(T5World *w);
// One object: the reaction to a hit or the cancel scan, the KO move, the throw link.
void t5_decide_object(T5World *w, T5Fighter *f);
// Latch the frame and the moveset of every object, then decide each fighter (in the order of
// t5_fighter_order) and the extras.
void t5_decide_pass(T5World *w);

#endif
