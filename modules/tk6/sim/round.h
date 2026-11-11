// The round flow of one standard match: a read-only table of phases, one pure step over it,
// and the round init each phase starts. Presentation, sound, camera, HUD, menus and the other game modes are not in the sim.
#ifndef T6_ROUND_H
#define T6_ROUND_H

#include "sim/world.h"

extern const T6MatchFlow T6_STANDARD_MATCH;
extern const T6MatchRules T6_STANDARD_RULES;  // wins needed, round time, side 1 wins a tie

// What the step reads of the fighters.
typedef struct {
    bool finished[T6_FIGHTER_COUNT];         // the move is finished
    bool player[T6_FIGHTER_COUNT];           // on a pad: may skip
    T6MenuButtons pressed[T6_FIGHTER_COUNT]; // menu buttons pressed this frame
    bool fallen[T6_FIGHTER_COUNT];           // no health, or out of the ring
} T6RoundView;

typedef struct {
    T6RoundState state;
    bool holds_input;  // the fighters take the phase's input mode
    bool scores;       // the fight is over: score the round
    T6Phase begins;    // a phase that begins in this frame (NONE: none)
} T6RoundStep;

T6RoundView t6_round_view(const T6World *w);
T6RoundStep t6_round_step(const T6MatchFlow *flow, T6MatchRules rules, T6RoundState round_state, T6RoundView view);  // s.frame counts this frame
bool t6_match_over(T6MatchRules rules, T6RoundState round_state,  // the rounds run out, or a side has the wins needed
                   int16_t wins_1, int16_t wins_2);
// The phase after an ended one: the result table, else the row's next.
T6Phase t6_next_phase(const T6MatchFlow *flow, T6RoundState round_state, bool match_over);

typedef struct { int16_t wins, last_round; } T6RoundMarks;  // wins so far; outcome of the last round
typedef struct {
    T6RoundState round;  // the round, decided with its result
    T6RoundMarks marks[T6_FIGHTER_COUNT];
} T6RoundScore;
uint32_t t6_round_result(T6RoundState round_state, const T6Fighter *first, const T6Fighter *second);  // T6_RESULT_* bits
T6RoundScore t6_score_round(T6MatchRules rules, T6RoundState round_state,  // more health wins; a draw gives both a win
                            const T6Fighter *first, const T6Fighter *second);

void t6_round_flow(T6World *w);                   // the default `round` hook
void t6_match_start(T6World *w);                  // the match begins with its first phase
void t6_round_begin(T6World *w, T6Phase phase);   // a phase begins with the next frame: its input, its round init, its release
void t6_round_input_mode(T6World *w, T6InputMode mode);  // both fighters
void t6_health_reset(T6Fighter *f);                      // full health for the next round

// The round init and its pieces.
void t6_round_init(T6World *w, T6RoundSetup setup);   // the default `round_init` hook
void t6_round_reset_models(T6World *w);              // the default `reset_models` hook
void t6_fighter_reset(T6World *w, T6Fighter *f, T6Fighter *opponent,  // reset one fighter for a round:
                      T6RoundSetup setup);                            // neutral input, start move, start spot, full health
void t6_round_nearest_start(T6World *w);             // the start record nearest to the fighters
void t6_round_place(T6World *w, T6RoundSetup setup);  // start positions and facing
void t6_round_floor_origin(T6World *w);              // floor height at the middle of the fighters
void t6_round_turn(T6World *w);                      // both fighters turn by the scene turn
int t6_round_focus(const T6World *w, T6RoundSetup setup);  // the side of the focus fighter
void t6_round_stand_at(T6Fighter *f, float x, float z);      // position, previous position, base and root at x, z

#endif
