// The round flow of a match as data: the phases, the round init each one starts, the match rules and the round state.
// One standard match; the stock state machine and round init are the reference.
#ifndef T6_PHASE_H
#define T6_PHASE_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/input.h"
#include "sim/units.h"

typedef enum : uint8_t {
    T6_PHASE_NONE,       // no match runs: the round flow does nothing
    T6_PHASE_INTRO_1,    // side 1's intro move
    T6_PHASE_INTRO_2,    // side 2's intro move
    T6_PHASE_READY,      // the countdown
    T6_PHASE_FIGHT,
    T6_PHASE_KO,         // the round is decided: the KO fall, the time up
    T6_PHASE_FLASHBACK,  // the last seconds of a KO once more, the fighters frozen
    T6_PHASE_ROUND_END,  // the round win pose, then the next round
    T6_PHASE_MATCH_END,  // the match win pose
    T6_PHASE_OVER,       // the match is over: the host takes over
    T6_PHASE_COUNT,
} T6Phase;

// A set of phases, bit n for phase n (the param of the phase requirements).
typedef uint16_t T6PhaseSet;
[[nodiscard]] static inline bool t6_phase_in(T6PhaseSet set, T6Phase phase) { return (set >> phase & 1) != 0; }

// The param of the phase requirements (db edit): the phases it passes in on every frame, and one phase it passes in
// on its first frame only (NONE: none). param = every_frame + first_frame_of * T6_PHASE_FIRST_FRAME_UNIT.
enum { T6_PHASE_FIRST_FRAME_UNIT = 4096 };
static_assert(1 << T6_PHASE_COUNT <= T6_PHASE_FIRST_FRAME_UNIT);
typedef struct {
    T6PhaseSet every_frame;
    T6Phase first_frame_of;
} T6PhaseTest;
[[nodiscard]] static inline T6PhaseTest t6_phase_test_of(uint16_t param) {
    return (T6PhaseTest){(T6PhaseSet)(param % T6_PHASE_FIRST_FRAME_UNIT), (T6Phase)(param / T6_PHASE_FIRST_FRAME_UNIT)};
}

// The scene cuts that snap the pose into the new scene's start pose; each has its own snap length (constants.h).
typedef enum : uint8_t {
    T6_CUT_ENTRANCE,   // a scene start where one side has the entrance
    T6_CUT_ROUND,      // a round start, the next round, the reset between rounds
    T6_CUT_MATCH_END,  // the win pose after the last round
} T6SceneCut;

// A fighter by side, or a rule that names one. Every side in the round flow is T6_SIDE_1 or T6_SIDE_2.
typedef enum : uint8_t { T6_NOBODY, T6_SIDE_1, T6_SIDE_2, T6_EITHER, T6_WINNER } T6Who;

// Menu buttons pressed in a frame; the host fills them.
enum { T6_MENU_START = 1 << 0 };
typedef uint8_t T6MenuButtons;

typedef enum : uint8_t {
    T6_SKIP_NOBODY,
    T6_SKIP_ANY_PLAYER,   // any fighter on a pad
    T6_SKIP_OWNER_FIRST,  // the fighter the phase waits for when it is on a pad, else the other one when it is
} T6Skipper;

typedef struct {
    T6Skipper who;  // who may skip the phase (see T6Skipper)
    T6MenuButtons buttons;  // the menu buttons that skip it
} T6SkipRule;

// Move var 4 and the last round's outcome of the fighters.
typedef enum : uint8_t { T6_MARKS_KEPT, T6_MARKS_CLEARED, T6_MARKS_CLEARED_FIRST_ROUND } T6MarksRule;

// The round init a phase starts with: how the fighters are set up.
typedef struct {
    bool runs;               // the phase starts with a round init
    T6SceneCut cut;  // the scene cut that snaps the pose into the start pose
    bool new_round;          // the clock, the result and the decided flag start again; the input goes neutral
    bool counts_round;       // a round starts: it counts, the gaze snaps, the pads are not sampled
    bool on_entrance_point;  // both stand on the entrance point keeping their facing, turned by the scene turn; only the focus stays still
    T6Who focus;             // reset last
    bool other_away;         // the other fighter plays the away move
    bool nearest_start;      // the start record nearest to the fighters is the next one
    bool shifts;             // a fighter steps back by the root travel of its first move
    T6MarksRule marks;  // the last round's outcome and move marks: kept, cleared, or cleared in round 1 only
} T6RoundSetup;

// What a phase does with the fighters' input. Live is set as the phase begins (before its round init) and held on every later
// frame; locked is held from the second frame (the countdown: its round init leaves the first neutral); neutral is set once as
// the phase begins (it forgets the last input).
typedef enum : uint8_t {
    T6_PHASE_INPUT_KEPT,     // the mode the last phase left; the pads are read
    T6_PHASE_INPUT_LIVE,
    T6_PHASE_INPUT_LOCKED,
    T6_PHASE_INPUT_NEUTRAL,
    T6_PHASE_INPUT_UNREAD,   // neutral, and the pads are not read
    T6_PHASE_INPUT_FROZEN,   // the pads are not read and the fighters stand still: no movement, throws or cancels
    T6_PHASE_INPUT_COUNT,
} T6PhaseInput;

// One phase of a match. Frame counts start at 1 on the frame the phase begins.
typedef struct {
    T6RoundSetup setup;
    T6Frames frames;       // the frames the phase lasts; 0: no limit
    T6Frames min_frames;   // a wait or a skip ends it once its count passes this
    T6Who waits;           // ends when this fighter's move is finished
    T6SkipRule skip;  // a skip press ends the phase (see T6SkipRule)
    bool ends_on_fall;     // ends when a fighter falls (no health, out of the ring) or the clock runs out
    bool clock;            // the round clock runs
    bool at_once;          // a wait or a skip that ends it begins the next phase in that frame; else that frame is still
                           // this phase's (ended) and the next begins with the frame after
    T6Phase next;          // the result table may pick another; NONE: the match is over, the host takes the fighters back
    T6PhaseInput input;  // how the fighters' input is handled in this phase
    bool look_at;          // the fighters look at each other
    bool fight_pose;       // fight body: throws mix the body scales, the hips follow the floor; else a show pose
    bool arena;            // the arena holds the fighters together
} T6PhaseRow;

typedef enum : uint8_t { T6_AFTER_KO, T6_AFTER_LAST_ROUND } T6RoundOutcome;

// When a phase ends with this outcome, the next phase is `to` (else the row's next). First row that fits.
typedef struct {
    T6Phase from;  // the phase this row is for
    T6RoundOutcome when;  // the round ended in a KO (AFTER_KO), or it was the last round
    T6Phase to;  // the phase to go to
} T6ResultRow;

enum { T6_RESULT_ROWS = 3 };

typedef struct {
    T6PhaseRow phase[T6_PHASE_COUNT];  // one row per phase
    T6ResultRow result[T6_RESULT_ROWS];  // phase changes by round outcome; the first row that fits wins
} T6MatchFlow;

typedef enum : uint8_t {
    T6_DRAW_ONE_CAN_FINISH,   // a draw gives both a win, and takes it back from the trailing side when it would take the match
    T6_DRAW_BOTH_CAN_FINISH,  // a draw gives both a win
} T6DrawRule;

typedef struct {
    uint32_t wins_needed;  // round wins that take the match
    T6Frames round_time;   // the clock of a round
    bool untimed;          // the clock stands still
    T6DrawRule draw;  // what a draw does (see T6DrawRule)
    T6Who tie_winner;      // the side that takes a match tied on wins
    T6Ratio damage_scale;    // of every hit's damage
    T6Ratio pushback_scale;  // of every hit's pushback distance
    T6Ratio clean_hit_bonus; // of the damage, added on a hit of a fighter who stands, crouches or starts a jump
    T6Health rage_health;    // at or below this health a fighter is in rage
    T6Ratio rage_bonus;      // of the damage, added on every hit of a fighter in rage
    int32_t bounds_per_combo;  // bounds a combo may use
} T6MatchRules;

// Result bits of a round.
enum {
    T6_RESULT_TIME_OVER = 1 << 0, T6_RESULT_KO = 1 << 1, T6_RESULT_DOUBLE_KO = 1 << 2, T6_RESULT_PERFECT = 1 << 3,
    T6_RESULT_CLOSE_WIN = 1 << 4, T6_RESULT_DRAW = 1 << 5,
    T6_RESULT_NO_REPLAY = 1 << 6,  // a fighter's body rules skip the flashback (FUN_00209d70)
};

// The rollback state of the round flow.
typedef struct {
    T6Phase phase;  // the phase the flow is in
    bool ended;            // the phase is over: the next one begins with the next frame
    T6Frames frame;        // frames of the phase
    uint32_t round;        // rounds started
    uint32_t round_limit;  // the match ends when this many rounds have started; a draw takes one off
    T6Frames timer;        // left on the clock
    uint32_t result;       // T6_RESULT_* of the last round
    bool decided;          // the round is decided: health stops changing
    T6Who winner;          // the side that took the match; NOBODY before
} T6RoundState;

// A fighter's round marks: round wins and the outcome of the last round.
enum { T6_ROUND_LOST = -1, T6_ROUND_NONE = 0, T6_ROUND_WON = 1 };

#endif
