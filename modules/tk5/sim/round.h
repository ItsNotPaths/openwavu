// The round flow of one standard match (docs/rewrite.md, round flow): a read-only table of phases, one pure step over it,
// and the round init each phase starts. Presentation, sound, camera, HUD, menus and the other game modes are not in the sim.
#ifndef T5_ROUND_H
#define T5_ROUND_H

#include "sim/world.h"

// (hole round-mokujin :tags (port tk5mod alpha) :sev gap) Mokujin  saves, restores and re-rolls its move set per round: not ported, and the round end does not wait for its reload.
// (hole round-match-setup :tags (port tk5mod alpha) :sev gap) the match setup, the mode rules and the start health are not ported: the host sets T5World.rules, no_damage and max_health, then calls t5_match_start.
extern const T5MatchFlow T5_STANDARD_MATCH;
extern const T5MatchRules T5_STANDARD_RULES;  // wins needed, round time, side 1 wins a tie

// What the step reads of the fighters.
typedef struct {
    bool finished[T5_FIGHTER_COUNT];         // the move is finished
    bool player[T5_FIGHTER_COUNT];           // on a pad: may skip
    T5MenuButtons pressed[T5_FIGHTER_COUNT]; // menu buttons pressed this frame
    bool fallen[T5_FIGHTER_COUNT];           // no health, or out of the ring
} T5RoundView;

typedef struct {
    T5RoundState state;
    bool holds_input;  // the fighters take the phase's input mode
    bool scores;       // the fight is over: score the round
    T5Phase begins;    // a phase that begins in this frame (NONE: none)
} T5RoundStep;

T5RoundView t5_round_view(const T5World *w);
T5RoundStep t5_round_step(const T5MatchFlow *flow, T5MatchRules rules, T5RoundState round_state, T5RoundView view);  // s.frame counts this frame
bool t5_match_over(T5MatchRules rules, T5RoundState round_state,  // the rounds run out, or a side has the wins needed
                   int16_t wins_1, int16_t wins_2);
// The phase after an ended one: the result table, else the row's next.
T5Phase t5_next_phase(const T5MatchFlow *flow, T5RoundState round_state, bool match_over);

typedef struct { int16_t wins, last_round; } T5RoundMarks;  // wins so far; outcome of the last round
typedef struct {
    T5RoundState round;  // the round, decided with its result
    T5RoundMarks marks[T5_FIGHTER_COUNT];
} T5RoundScore;
uint32_t t5_round_result(T5RoundState round_state, const T5Fighter *first, const T5Fighter *second);  // T5_RESULT_* bits
T5RoundScore t5_score_round(T5MatchRules rules, T5RoundState round_state,  // more health wins; a draw gives both a win
                            const T5Fighter *first, const T5Fighter *second);

void t5_round_flow(T5World *w);                   // the default `round` hook
void t5_match_start(T5World *w);                  // the match begins with its first phase
void t5_round_begin(T5World *w, T5Phase phase);   // a phase begins with the next frame: its input, its round init, its release
void t5_round_input_mode(T5World *w, T5InputMode mode);  // both fighters
void t5_health_reset(T5Fighter *f);                      // full health for the next round

// The round init and its pieces.
void t5_round_init(T5World *w, T5RoundSetup setup);   // the default `round_init` hook
void t5_round_reset_models(T5World *w);              // the default `reset_models` hook
void t5_fighter_reset(T5World *w, T5Fighter *f, T5Fighter *opponent,  // reset one fighter for a round:
                      T5RoundSetup setup);                            // neutral input, start move, start spot, full health
void t5_round_nearest_start(T5World *w);             // the start record nearest to the fighters
void t5_round_place(T5World *w, T5RoundSetup setup);  // start positions and facing
void t5_round_floor_origin(T5World *w);              // floor height at the middle of the fighters
void t5_round_turn(T5World *w);                      // both fighters turn by the scene turn
int t5_round_focus(const T5World *w, T5RoundSetup setup);  // the side of the focus fighter
void t5_round_stand_at(T5Fighter *f, float x, float z);      // position, previous position, base and root at x, z

#endif
