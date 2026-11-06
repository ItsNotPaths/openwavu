// The phase table of a standard match and the step over it. Stock: the state machine, the result, the
// match decision of state 5 and the round inits of states 1, 2, 9 and the outer machine (docs/rewrite.md).
#include "sim/round.h"

#include <assert.h>

#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/frame.h"
#include "sim/math.h"

static constexpr T5SkipRule START_SKIPS_ANY_PLAYER = {T5_SKIP_ANY_PLAYER, T5_MENU_START};
static constexpr T5SkipRule START_SKIPS_OWNER_FIRST = {T5_SKIP_OWNER_FIRST, T5_MENU_START};

const T5MatchFlow T5_STANDARD_MATCH = {
    .phase = {
        [T5_PHASE_INTRO_1] = {  // side 1 plays their entrance move; ends when it finishes or START is pressed
            .setup = {.runs = true, .cut = T5_CUT_ENTRANCE, .new_round = true, .on_entrance_point = true, .focus = T5_SIDE_1,
                      .other_away = true, .marks = T5_MARKS_CLEARED},
            .waits = T5_SIDE_1, .skip = START_SKIPS_OWNER_FIRST, .at_once = true, .next = T5_PHASE_INTRO_2,
        },
        [T5_PHASE_INTRO_2] = {  // same for side 2
            .setup = {.runs = true, .cut = T5_CUT_ENTRANCE, .new_round = true, .on_entrance_point = true, .focus = T5_SIDE_2,
                      .other_away = true, .marks = T5_MARKS_CLEARED},
            .waits = T5_SIDE_2, .skip = START_SKIPS_OWNER_FIRST, .at_once = true, .next = T5_PHASE_READY,
        },
        [T5_PHASE_READY] = {  // the countdown: a new round, inputs locked
            .setup = {.runs = true, .cut = T5_CUT_ROUND, .new_round = true, .counts_round = true, .focus = T5_SIDE_1,
                      .marks = T5_MARKS_CLEARED_FIRST_ROUND},
            .frames = READY_FRAMES, .at_once = true, .next = T5_PHASE_FIGHT, .input = T5_PHASE_INPUT_LOCKED,
            .look_at = true, .fight_pose = true, .arena = true,
        },
        [T5_PHASE_FIGHT] = {  // the fight: clock runs, inputs live, ends when a fighter falls or time runs out
            .ends_on_fall = true, .clock = true, .next = T5_PHASE_KO, .input = T5_PHASE_INPUT_LIVE,
            .look_at = true, .fight_pose = true, .arena = true,
        },
        [T5_PHASE_KO] = {  // the KO fall or time up pose for a fixed time
            .frames = KO_FRAMES, .next = T5_PHASE_ROUND_END, .look_at = true, .fight_pose = true, .arena = true,
        },
        [T5_PHASE_FLASHBACK] = {  // the KO replayed with the fighters frozen; any player can skip with START
            .frames = FLASHBACK_FRAMES, .skip = START_SKIPS_ANY_PLAYER, .next = T5_PHASE_ROUND_END,
            .input = T5_PHASE_INPUT_FROZEN, .fight_pose = true,
        },
        [T5_PHASE_ROUND_END] = {  // the win pose; ends when either move finishes or START; the next round follows
            .setup = {.runs = true, .cut = T5_CUT_ROUND, .focus = T5_SIDE_1, .nearest_start = true, .shifts = true},
            .frames = ROUND_END_FRAMES, .min_frames = SETUP_FRAMES, .waits = T5_EITHER, .skip = START_SKIPS_ANY_PLAYER,
            .next = T5_PHASE_READY, .input = T5_PHASE_INPUT_NEUTRAL,
        },
        [T5_PHASE_MATCH_END] = {  // the match win pose; waits for the winner's move or START
            .setup = {.runs = true, .cut = T5_CUT_MATCH_END, .on_entrance_point = true, .focus = T5_WINNER, .nearest_start = true},
            .frames = MATCH_END_FRAMES, .min_frames = SETUP_FRAMES, .waits = T5_WINNER, .skip = START_SKIPS_ANY_PLAYER,
            .next = T5_PHASE_OVER, .input = T5_PHASE_INPUT_UNREAD,
        },
        [T5_PHASE_OVER] = {},  // no next: the match is over
    },
    .result = {
        {T5_PHASE_KO, T5_AFTER_KO, T5_PHASE_FLASHBACK},  // a KO plays the flashback
        {T5_PHASE_KO, T5_AFTER_LAST_ROUND, T5_PHASE_MATCH_END},  // last round: no flashback, straight to match end
        {T5_PHASE_FLASHBACK, T5_AFTER_LAST_ROUND, T5_PHASE_MATCH_END},  // last round after the flashback: match end
    },
};

const T5MatchRules T5_STANDARD_RULES = {.wins_needed = DEFAULT_WINS_NEEDED, .round_time = DEFAULT_ROUND_TIME, .tie_winner = T5_SIDE_1};

enum { PERFECT_PERCENT = 100, CLOSE_WIN_PERCENT = 5 };

T5PhaseRow t5_phase_row(const T5World *w) {
    if (w->flow == NULL) return (T5PhaseRow){};  // no match flow loaded: an empty row
    return w->flow->phase[w->round.phase];
}

// --- the input of a phase

typedef struct {
    bool at_begin;    // the mode is set as the phase begins
    bool held;        // the mode is set on every frame after its first
    T5InputMode mode;
    bool reads_pads;  // the input pass runs
    bool moves;       // the fighters move, throw and cancel
} InputRule;

static const InputRule INPUT_RULES[T5_PHASE_INPUT_COUNT] = {
    [T5_PHASE_INPUT_KEPT] = {.reads_pads = true, .moves = true},
    [T5_PHASE_INPUT_LIVE] = {.at_begin = true, .held = true, .mode = T5_INPUT_LIVE, .reads_pads = true, .moves = true},
    [T5_PHASE_INPUT_LOCKED] = {.held = true, .mode = T5_INPUT_LOCKED, .reads_pads = true, .moves = true},
    [T5_PHASE_INPUT_NEUTRAL] = {.at_begin = true, .mode = T5_INPUT_NEUTRAL, .reads_pads = true, .moves = true},
    [T5_PHASE_INPUT_UNREAD] = {.at_begin = true, .mode = T5_INPUT_NEUTRAL, .moves = true},
    [T5_PHASE_INPUT_FROZEN] = {},
};

static InputRule input_rule(T5PhaseRow row) { return INPUT_RULES[row.input]; }

bool t5_phase_reads_pads(const T5World *w) { return input_rule(t5_phase_row(w)).reads_pads; }
bool t5_phase_frozen(const T5World *w) { return !input_rule(t5_phase_row(w)).moves; }

// --- the step

static int index_of(T5Who side) {
    if (side == T5_SIDE_2) return 1;  // side 2 is fighter 1
    return 0;  // side 1 is fighter 0
}

static int fighter_of(T5Who who, T5Who winner) {
    if (who == T5_WINNER) return index_of(winner);  // WINNER means whoever took the match
    return index_of(who);
}

int t5_round_focus(const T5World *w, T5RoundSetup setup) { return fighter_of(setup.focus, w->round.winner); }

static int other_side(int side) { return T5_FIGHTER_COUNT - 1 - side; }  // the opponent's index

static bool presses(T5RoundView view, int side, T5MenuButtons buttons) {  // that side is a player and pressed the button
    return view.player[side] && (view.pressed[side] & buttons) != 0;
}

static bool skipped(T5SkipRule rule, int owner, T5RoundView view) {
    if (rule.who == T5_SKIP_ANY_PLAYER)  // any player pressing the button skips
        return presses(view, 0, rule.buttons) || presses(view, 1, rule.buttons);
    if (rule.who != T5_SKIP_OWNER_FIRST) return false;  // no skip rule
    if (view.player[owner]) return presses(view, owner, rule.buttons);  // phase owner is a player: only they can skip
    return presses(view, other_side(owner), rule.buttons);  // else the other fighter can skip, if they are a player
}

static bool waited(T5Who who, T5Who winner, T5RoundView view) {
    if (who == T5_NOBODY) return false;  // waits for nobody
    if (who == T5_EITHER) return view.finished[0] || view.finished[1];  // either fighter's move finished
    return view.finished[fighter_of(who, winner)];  // that fighter's move finished
}

// A phase that begins the next at once is over in the frame after its last; else in its last, which it keeps (ended).
static bool out_of_frames(T5PhaseRow row, T5Frames count) {
    if (row.frames.ticks == 0) return false;  // no frame limit
    if (row.at_once) return t5_frames_past(count.ticks, row.frames);  // over in the frame after the last
    return count.ticks >= row.frames.ticks;  // over in the last frame
}

static bool phase_over(T5PhaseRow row, T5RoundState round_state, T5RoundView view) {
    if (row.ends_on_fall && (view.fallen[0] || view.fallen[1] || round_state.timer.ticks <= 0))  // ends on a fall or timeout
        return true;
    if (!t5_frames_past(round_state.frame.ticks, row.min_frames)) return false;  // too early for a wait or skip to end it
    if (skipped(row.skip, fighter_of(row.waits, round_state.winner), view)  // a skip press
        || waited(row.waits, round_state.winner, view))  // or the awaited fighter's finished move ends the phase
        return true;
    return out_of_frames(row, round_state.frame);  // else the phase ends when its frames run out
}

T5RoundStep t5_round_step(const T5MatchFlow *flow, T5MatchRules rules, T5RoundState round_state, T5RoundView view) {
    T5RoundStep out = {.state = round_state};  // start from the unchanged state
    if (round_state.phase == T5_PHASE_NONE) return out;  // no match running
    T5PhaseRow row = flow->phase[round_state.phase];
    out.holds_input = input_rule(row).held && out.state.frame.ticks > 1;  // held-input phases set it each frame after the first
    if (row.clock && !rules.untimed) out.state.timer.ticks--;  // the round clock ticks down
    if (!phase_over(row, out.state, view)) return out;  // the phase goes on
    out.scores = row.ends_on_fall;  // the fight ending scores the round
    if (row.at_once) out.begins = t5_next_phase(flow, out.state, false);  // the next phase begins in this frame
    else out.state.ended = true;  // this frame stays in the phase; the next phase begins next frame
    return out;
}

static bool below(int16_t wins, uint32_t need) { return (uint32_t)(int32_t)wins < need; }  // cmplw of a sign-extended count

bool t5_match_over(T5MatchRules rules, T5RoundState round_state, int16_t wins_1, int16_t wins_2) {
    return !(round_state.round < round_state.round_limit &&  // match over when the rounds run out
             below(wins_1, rules.wins_needed) && below(wins_2, rules.wins_needed));  // or a side has the wins needed
}

static bool outcome_holds(T5RoundOutcome when, T5RoundState round_state, bool match_over) {
    if (when == T5_AFTER_KO) return (round_state.result & T5_RESULT_KO) != 0;  // the round ended in a KO
    return match_over;  // after the last round: the match is over
}

T5Phase t5_next_phase(const T5MatchFlow *flow, T5RoundState round_state, bool match_over) {
    for (int side = 0; side < T5_RESULT_ROWS; side++) {  // the first result row that fits decides the next phase
        T5ResultRow row = flow->result[side];
        if (row.from == round_state.phase && outcome_holds(row.when, round_state, match_over))  // row fits: go to its phase
            return row.to;
    }
    return flow->phase[round_state.phase].next;  // no row fits: the normal next phase
}

// --- what the step reads

static bool move_finished(const T5World *w, const T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    uint32_t length = 0;
    if (move != NULL) length = move->length;  // no move found: length 0
    return (int32_t)length <= f->frame + 1 || f->marked_finished != 0;  // last frame, or a move property marked it finished
}

static bool out_of_ring(const T5Fighter *f) {  // ring out: too far from the stage origin on the ground plane
    return t5_length_xz(f->base_position.x, f->base_position.z) >= RING_OUT_DISTANCE;
}

T5RoundView t5_round_view(const T5World *w) {
    T5RoundView view = {};
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        const T5Fighter *f = w->fighters[side];
        view.finished[side] = move_finished(w, f);  // their move is finished
        view.player[side] = t5_input_pad_driven(&f->input);  // a player is a fighter on a pad
        view.pressed[side] = f->menu_pressed;  // menu buttons pressed this frame
        view.fallen[side] = f->health == 0 || out_of_ring(f);  // no health left or out of the ring
    }
    return view;
}

// --- the score of a round

static uint16_t health_percent(const T5Fighter *f) {  // at least 1 while alive
    uint16_t percent = t5_health_percent((T5Health){f->health}, (T5Health){f->max_health});
    if (percent == 0 && f->health > 0) return 1;  // a fighter still alive never shows 0
    return percent;
}

uint32_t t5_round_result(T5RoundState round_state, const T5Fighter *first, const T5Fighter *second) {
    bool alive = first->health != 0 && second->health != 0;  // both fighters have health left
    uint32_t timeout = 0;
    if (round_state.timer.ticks < 1 && alive) timeout = T5_RESULT_TIME_OVER;  // the clock ran out with both alive
    if (first->health == 0 && second->health == 0)  // both down: double KO draw
        return T5_RESULT_DRAW | T5_RESULT_DOUBLE_KO | T5_RESULT_KO;
    if (alive && health_percent(first) == health_percent(second))  // both alive, same health percent: a draw
        return timeout | T5_RESULT_DRAW;
    const T5Fighter *winner = first, *loser = second;
    if (second->health >= first->health) {  // side 2 wins a tie of the raw health
        winner = second;
        loser = first;
    }
    if (loser->health != 0) return timeout;  // the loser still stands: no KO, only time over if the clock ran out
    if (health_percent(winner) == PERFECT_PERCENT) return T5_RESULT_PERFECT | T5_RESULT_KO;  // KO with full health left: perfect
    if (health_percent(winner) < CLOSE_WIN_PERCENT && t5_input_pad_driven(&winner->input))  // close win: low-health KO by player
        return T5_RESULT_CLOSE_WIN | T5_RESULT_KO;
    return T5_RESULT_KO;  // a plain KO
}

static T5RoundMarks won(T5RoundMarks marks) { return (T5RoundMarks){(int16_t)(marks.wins + 1), T5_ROUND_WON}; }
static T5RoundMarks lost(T5RoundMarks marks) { return (T5RoundMarks){marks.wins, T5_ROUND_LOST}; }

// A draw gives a win to both sides; the draw rule may take one back. The round limit shrinks by one.
static T5RoundScore draw(T5MatchRules rules, T5RoundScore round_score) {
    int lead = 0;
    T5RoundMarks first = round_score.marks[0], second = round_score.marks[1];
    if (first.wins < second.wins  // leader is ahead on wins,
        || (first.wins == second.wins && rules.tie_winner == T5_SIDE_2))  // or the tie winner when equal
        lead = 1;
    int trail = other_side(lead);  // the other side
    round_score.round.round_limit--;
    T5RoundMarks leader = {(int16_t)(round_score.marks[lead].wins + 1), T5_ROUND_LOST};  // both get a win, marked lost first
    T5RoundMarks trailer = {(int16_t)(round_score.marks[trail].wins + 1), T5_ROUND_LOST};
    if (rules.draw == T5_DRAW_ONE_CAN_FINISH) {  // only one side may take the match on a draw
        if (!below(leader.wins, rules.wins_needed)) leader.last_round = T5_ROUND_WON;  // leader reaches wins needed: marked won
        if (!below(trailer.wins, rules.wins_needed)) trailer.wins--;  // the trailer would reach it too: take their win back
    } else if (!below(leader.wins, rules.wins_needed) && below(trailer.wins, rules.wins_needed)) {
        leader.last_round = T5_ROUND_WON;  // only the leader reaches the wins needed: marked won
    }
    round_score.marks[lead] = leader;
    round_score.marks[trail] = trailer;
    return round_score;
}

static T5Who match_winner(T5MatchRules rules, T5RoundMarks first, T5RoundMarks second) {
    if (first.wins > second.wins) return T5_SIDE_1;
    if (first.wins < second.wins) return T5_SIDE_2;
    return rules.tie_winner;  // equal wins: the tie rule picks
}

T5RoundScore t5_score_round(T5MatchRules rules, T5RoundState round_state, const T5Fighter *first, const T5Fighter *second) {
    T5RoundScore round_score = {.round = round_state,  // start from the current wins and last round outcomes
                                .marks = {{first->wins, first->last_round}, {second->wins, second->last_round}}};
    round_score.round.decided = true;  // the round is decided: health stops changing
    round_score.round.result = t5_round_result(round_state, first, second);
    if ((round_score.round.result & T5_RESULT_DRAW) != 0) {  // a draw: both sides get a win
        round_score = draw(rules, round_score);
    } else if (first->health > second->health) {  // side 1 has more health: side 1 takes the round
        round_score.marks[0] = won(round_score.marks[0]);
        round_score.marks[1] = lost(round_score.marks[1]);
    } else if (first->health < second->health) {  // side 2 has more health: side 2 takes the round
        round_score.marks[1] = won(round_score.marks[1]);
        round_score.marks[0] = lost(round_score.marks[0]);
    }
    if (t5_match_over(rules, round_score.round, round_score.marks[0].wins, round_score.marks[1].wins))  // match ends this round
        round_score.round.winner = match_winner(rules, round_score.marks[0], round_score.marks[1]);
    return round_score;
}

// --- the round flow on the world

void t5_round_input_mode(T5World *w, T5InputMode mode) {  // for the fighters
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) t5_input_set_mode(&w->fighters[side]->input, mode);
}

void t5_health_reset(T5Fighter *f) { f->health = f->max_health; }  // back to full health

// The match is over: the fighters move again and the forced update bits are gone.
static void release(T5World *w) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        w->fighters[side]->skip_motion = 0;
        w->fighters[side]->force_update = false;
    }
}

// `frame`: 1 when the phase begins in this frame (its round init sees its first frame), 0 when it begins with the next.
static void begin(T5World *w, T5Phase phase, int32_t frame) {
    T5PhaseRow row = w->flow->phase[phase];
    InputRule input = input_rule(row);
    w->round.phase = phase;
    w->round.frame = (T5Frames){frame};
    w->round.ended = false;  // the phase has not ended yet
    if (input.at_begin) t5_round_input_mode(w, input.mode);  // some phases set the input mode as they begin
    if (row.setup.runs) t5_hooks.round_init(w, row.setup);  // this phase sets the fighters up (round init)
    if (row.next == T5_PHASE_NONE) release(w);  // last phase: give the fighters back
}

void t5_round_begin(T5World *w, T5Phase phase) { begin(w, phase, 0); }  // begins with the next frame

void t5_match_start(T5World *w) {
    assert(w->stage != NULL);
    w->round = (T5RoundState){.round_limit = 2 * w->rules.wins_needed - 1};  // fresh state; most rounds a match can take
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        w->fighters[side]->wins = 0;
        w->fighters[side]->last_round = T5_ROUND_NONE;
    }
    t5_round_begin(w, T5_PHASE_INTRO_1);  // the match starts with the intro of side 1
}

static bool match_over(const T5World *w) { return t5_match_over(w->rules, w->round, w->fighters[0]->wins, w->fighters[1]->wins); }

static void score(T5World *w) {
    T5RoundScore round_score = t5_score_round(w->rules, w->round, w->fighters[0], w->fighters[1]);  // score, copy to fighters
    w->round = round_score.round;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        w->fighters[side]->wins = round_score.marks[side].wins;
        w->fighters[side]->last_round = round_score.marks[side].last_round;
    }
}

// (hole round-flow-cues :tags (tk5mod round-show audio)) the round flow sends no cues: announcer (round call, KO, perfect, time up, win/lose/draw by 0x3b3d0, played at end_frame 0x82, winner name; "ready"/"fight" records not found), music start and fade (0x9ee48).
void t5_round_flow(T5World *w) {
    if (w->flow == NULL || w->round.phase == T5_PHASE_NONE) return;  // no match running
    if (w->round.ended) begin(w, t5_next_phase(w->flow, w->round, match_over(w)), 1);  // last frame ended the phase: begin next
    else w->round.frame.ticks++;  // count this frame of the phase
    T5PhaseRow row = t5_phase_row(w);
    T5RoundStep step = t5_round_step(w->flow, w->rules, w->round, t5_round_view(w));  // what this frame does to the phase
    w->round = step.state;
    if (step.holds_input) t5_round_input_mode(w, input_rule(row).mode);  // set the held input mode again
    if (step.scores) score(w);  // the fight just ended: score the round
    if (step.begins != T5_PHASE_NONE) begin(w, step.begins, 1);  // the phase is over and the next begins in this frame
}
