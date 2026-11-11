// The decide pass: at the end of the frame each object picks the move it plays next.
#ifndef T6_DECIDE_H
#define T6_DECIDE_H

#include <stdbool.h>

#include "sim/world.h"

// T6Fighter.reaction_facing (`PROP_REACTION_TURNED`, `PROP_REACTION_LOOK`): where a reaction starts facing.
enum T6ReactionFacing : uint8_t {
    REACTION_FACING_HIT,     // toward the hit
    REACTION_FACING_TURNED,  // turned half a circle: the reaction turns the fighter around
    REACTION_FACING_LOOK,    // the look direction; the reaction turns with its anim
};

// T6Fighter.launch_index: the generic launches of a fighter hit in the air (moves T6_ALIAS_LAUNCH + entry).
enum T6LaunchEntry : int16_t {
    LAUNCH_PLAIN, LAUNCH_LOW, LAUNCH_DOWN_FRONT_RIGHT, LAUNCH_DOWN_BACK_LEFT, LAUNCH_RIGHT, LAUNCH_LEFT,
};

// on the requirement layer: the cancel list that starts at `first` in data slot `set`, scanned at `frame`.
// The group cancels and input sequences come from the moveset_scan slot of f; input_window gets the T6_OPTION_INPUT flag.
const T6Cancel *t6_cancel_walk(T6World *w, T6Fighter *f, const T6Fighter *opponent, uint32_t set, uint32_t first, int32_t frame,
                               bool *input_window);
// The first-frame cancels of f (T6_OPTION_FIRST_FRAME).
enum T6FirstFrame {
    FIRST_FRAME_NONE,     // no move start, or no first-frame cancel passed
    FIRST_FRAME_TAKEN,    // a move was scheduled: it starts this frame
    FIRST_FRAME_MATCHED,  // entries passed without one that stops the scan
};
enum T6FirstFrame t6_first_frame_select(T6World *w, T6Fighter *f, T6Fighter *opponent);
// The reaction move of a hit from the reaction list of f (the attacker is not read).
void t6_reaction_move(T6World *w, T6Fighter *f);
// The generic launch of a fighter hit in the air, by the side of the hit.
void t6_juggle_reaction(const T6World *w, T6Fighter *f);
// The KO move (T6_ALIAS_KO) of a fighter with no health left.
void t6_ko_move(T6World *w, T6Fighter *f);
// The main cancel scan of a fighter, with the lookahead past a move end. opp is f's opponent.
void t6_scan_cancels(T6World *w, T6Fighter *f, T6Fighter *opponent);
// A fighter that was hit answers with the first option 2 cancel of its move that is in its window and
// passes its input and requirements (a reversal). `opponent` is the attacker.
void t6_reversal(T6World *w, T6Fighter *f, T6Fighter *opponent);
// Both fighters, in turn order.
void t6_reversals_pass(T6World *w);
// One object: the reaction to a hit or the cancel scan, the KO move, the throw link.
void t6_decide_object(T6World *w, T6Fighter *f);
// Latch the frame and the moveset of every object, then decide each fighter (in the order of
// t6_fighter_order) and the extras.
void t6_decide_pass(T6World *w);

#endif
