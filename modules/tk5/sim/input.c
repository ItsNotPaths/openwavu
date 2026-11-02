#include "sim/input.h"

#include <string.h>

#include "sim/constants.h"

enum {
    DIRECTION_BIT_15 = 1 << 15,  // the game's direction mask keeps it; nothing sets it
    DIRECTIONS_COMPARED = ((T5_DIRECTION_NEW_PRESS << 1) - 1) | DIRECTION_BIT_15,  // all bits up to NEW_PRESS
};

static constexpr uint16_t HELD_GROUP = T5_BUTTONS_ALL << T5_HELD_SHIFT;  // the four held-button bits of the button word

// Extradata of a cancel.
enum { EXTRA_UNLOCKS_COMMAND = 1 << 18, EXTRA_NO_MOVE = 16383 };

// Shoulder sets inside a direction word: pressed (new) and held, two bits each. The command match also reads them from
// the top nibble of the button word (no sample sets it).
enum {
    SHOULDER_SHIFT = 4, SHOULDER_BITS = 2, DIRECTION_SHOULDER_NEW_SHIFT = 11, DIRECTION_SHOULDER_HELD_SHIFT = 13,
    BUTTON_SHOULDER_NEW_SHIFT = 12, BUTTON_SHOULDER_HELD_SHIFT = 14,
};

// Numpad: key = NUMPAD_NEUTRAL + NUMPAD_ROW * up + forward, key 5 is neutral, rows are 3 wide.
enum { NUMPAD_NEUTRAL = 5, NUMPAD_ROW = 3 };

// --- side

void t5_side_update(T5Input *input) {
    input->side = input->camera_side;  // the fighter's screen side follows the host's camera side
    input->side_copy = input->camera_side;
}

void t5_side_latch(T5Input *first, T5Input *second) {
    first->side_latched = first->side;  // freeze the side for this frame; directions decode against it
    second->side_latched = second->side;
}

// --- fighter state around the frame

void t5_input_set_mode(T5Input *input, T5InputMode mode) {
    input->mode = mode;
    if (mode == T5_INPUT_NEUTRAL) input->previous_input = (T5StdInput){0};  // neutral forgets the last pad state
}

void t5_input_round_start(T5Input *input) {
    input->side = input->side_latched = T5_SIDE_LEFT;  // every round starts on the left
    input->latch_asked = T5_BUTTONS_NONE;  // no throw-break check has asked about punches yet
}

void t5_input_round_end(T5Input *input, T5Side start_side) {
    input->first_punch = T5_BUTTONS_NONE;  // forget the first punch
    input->camera_side = start_side;  // back to the starting side
}

bool t5_input_ask_first_punch(T5Input *input, T5ButtonSet punches) {
    input->latch_asked = punches;  // once asked, first_punch stops following the pad after the first punch
    return input->first_punch == punches;  // true if the first punch press was exactly these punches
}

// --- sample and decode

typedef struct {
    uint16_t buttons,  // button word: bits 0-3 pressed this frame, 4-7 held, 8-11 not held; one bit each for LP, RP, LK, RK
        direction_held,  // numpad bit of the direction held now (neutral is its own bit), shoulder bits on top
        direction_new;   // numpad bit of the direction entered this frame; NO_CHANGE if none
} Words;

static Words words_of(const T5Input *input) { return (Words){input->buttons, input->direction_held, input->direction_new}; }

void t5_history_clear(T5History *history) {
    if (history) memset(history, 0, sizeof *history);  // wipe the ring and the change log
}

void t5_input_neutral(T5Input *input, T5History *history, T5StdInput pad) {
    input->direction_new = 0;  // no direction entered
    input->direction_held = T5_DIRECTION_N;  // stick centered
    input->buttons = 0;  // nothing pressed, held or released
    input->previous_input = pad;  // next frame's presses compare against this pad
    t5_history_clear(history);  // neutral also erases the input history
}

// The input of a frame against the last one.
typedef struct {
    T5StdInput now;
    T5ButtonSet pressed;  // held now, not held in the last frame
    bool directions_entered;  // the stick differs from the last frame
    uint8_t side;         // decode side; above RIGHT skips the direction decode
} Sample;

// Practice record and playback are not ported. Control above NONE_4 reads stack garbage in
// the game; here it gives no input.
static T5StdInput source_input(const T5Input *input, const T5InputEnv *env) {
    const T5InputHook *hook = NULL;
    switch (input->control) {
    case T5_CONTROL_PAD: return env->pad;  // a human: the pad of this side
    case T5_CONTROL_CPU: hook = &env->cpu; break;  // the CPU AI writes the input
    case T5_CONTROL_SCRIPT: hook = &env->script; break;  // a script writes the input
    default: break;
    }
    if (hook && hook->read) return hook->read(hook->context);  // ask the CPU or script for this frame's input
    return (T5StdInput){0};  // no source, no input
}

static int sign(int8_t axis) {
    if (axis > 0) return 1;  // up or screen right
    if (axis < 0) return -1;  // down or screen left
    return 0;  // centered
}

// Forward is toward the opponent: screen right on the left side.
static uint16_t direction_of(T5StdInput input, uint8_t side) {
    int forward = sign(input.horizontal);  // +1 screen right, -1 screen left
    if (side == T5_SIDE_RIGHT) forward = -forward;  // on the right the opponent is to the left, so flip
    return (uint16_t)(1 << (NUMPAD_NEUTRAL + NUMPAD_ROW * sign(input.vertical)  // numpad key as a bit: up or down moves a row,
                            + forward));  // forward or back moves a column
}

typedef struct {
    uint16_t held, entered;
} Directions;

// A direction is entered when the stick differs from the last frame. `entered` is NO_CHANGE when nothing changed,
// and N when the stick went back to neutral.
static Directions decode_directions(Sample sample, uint16_t previous_direction_held) {
    Directions directions = {T5_DIRECTION_N, T5_DIRECTION_N};  // start as neutral held, neutral entered
    if (sample.side == T5_SIDE_LEFT || sample.side == T5_SIDE_RIGHT) {  // a real side: decode the stick
        directions.held = direction_of(sample.now, sample.side);  // direction held now, relative to the opponent
        if (sample.directions_entered) directions.entered = directions.held;  // stick moved: this direction is newly entered
    }
    if (directions.entered == T5_DIRECTION_N &&  // unless the stick just returned to neutral from a direction,
        ((previous_direction_held & T5_DIRECTION_N) || directions.held != T5_DIRECTION_N))
        directions.entered = T5_DIRECTION_NO_CHANGE;  // report no change
    return directions;
}

static T5ButtonSet first_punch_of(Sample sample) {
    const T5ButtonSet punches = T5_BUTTON_1 | T5_BUTTON_2;  // left and right punch
    if ((sample.now.held & punches) == punches && (sample.pressed & punches)) return punches;  // both down, one new: both count
    if (sample.pressed & T5_BUTTON_1) return T5_BUTTON_1;  // left punch pressed this frame
    if (sample.pressed & T5_BUTTON_2) return T5_BUTTON_2;  // right punch pressed this frame
    return T5_BUTTONS_NONE;  // no punch pressed
}

static uint16_t button_word(Sample sample) {
    T5ButtonSet pressed = sample.pressed & T5_BUTTONS_ALL;  // face buttons that went down this frame
    T5ButtonSet held = sample.now.held & T5_BUTTONS_ALL;  // face buttons that are down (includes the new presses)
    T5ButtonSet not_held = ~held & T5_BUTTONS_ALL;  // face buttons that are up
    return (uint16_t)(pressed << T5_PRESSED_SHIFT | held << T5_HELD_SHIFT  // pack: pressed bits 0-3, held 4-7,
                      | not_held << T5_NOT_HELD_SHIFT);  // not held 8-11
}

static uint16_t shoulder_word(Sample sample) {
    unsigned pressed = sample.pressed >> SHOULDER_SHIFT;  // L1 and R1 pressed this frame, as two bits
    unsigned held = sample.now.held >> SHOULDER_SHIFT;  // L1 and R1 held
    return (uint16_t)(pressed << DIRECTION_SHOULDER_NEW_SHIFT  // pressed pair above the direction bits,
                      | held << DIRECTION_SHOULDER_HELD_SHIFT);  // held pair after it
}

static Words decode_words(Sample sample, uint16_t previous_direction_held) {
    Directions directions = decode_directions(sample, previous_direction_held);  // held and newly entered direction
    uint16_t shoulders = shoulder_word(sample);  // L1 and R1 ride along in both direction words
    return (Words){button_word(sample),  // face buttons
                   (uint16_t)(directions.held | shoulders),  // direction held now
                   (uint16_t)(directions.entered | shoulders)};  // direction entered this frame
}

static void log_change(T5History *history, Words words) {
    bool unchanged;
    if (history->log_held_only) {  // log only what is held: presses and entries do not count as changes
        words.buttons &= HELD_GROUP;  // keep the held buttons only
        words.direction_new = 0;  // ignore the entered direction
        unchanged = words.buttons == (history->log_last_buttons & HELD_GROUP)  // same buttons and direction as the last entry
                    && words.direction_held == history->log_last_direction_held;
    } else {
        unchanged = words.buttons == history->log_last_buttons  // same buttons, direction held and direction entered
                    && words.direction_held == history->log_last_direction_held
                    && words.direction_new == history->log_last_direction_new;
    }
    if (unchanged) return;  // nothing new this frame: add no log entry
    history->log_buttons[history->log_next] = history->log_last_buttons = words.buttons;
    history->log_direction_held[history->log_next] = history->log_last_direction_held = words.direction_held;
    history->log_direction_new[history->log_next] = history->log_last_direction_new = words.direction_new;
    history->log_next = (uint8_t)((history->log_next + 1) % T5_CHANGE_LOG_SIZE);  // the log is a short ring
}

static void history_push(T5History *history, Words words) {
    log_change(history, words);  // the change log sees every frame
    history->buttons[history->next] = words.buttons;  // store this frame's three words in the ring
    history->direction_held[history->next] = words.direction_held;
    history->direction_new[history->next] = words.direction_new;
    history->next++;  // a byte: wraps after 256 frames and overwrites the oldest
}

static bool pad_sampled(T5Control control) { return control == T5_CONTROL_PAD || control == T5_CONTROL_CPU; }  // use the camera

void t5_input_sample(T5Input *input, T5History *history, const T5InputEnv *env) {
    if (pad_sampled(input->control)) t5_side_update(input);  // pad and CPU fighters take the camera's side

    Sample sample = {.now = source_input(input, env), .side = T5_SIDE_LEFT};  // this frame's input; others decode as on the left
    if (input->control == T5_CONTROL_PAD) sample.side = input->side_latched;  // a pad decodes by the latched screen side
    if (env->ko) sample.now = (T5StdInput){0};  // a knocked out fighter gets no input
    sample.pressed = sample.now.held & ~input->previous_input.held;  // pressed: held now and not held last frame
    sample.directions_entered = sample.now.vertical != input->previous_input.vertical  // the stick moved since last frame
                                || sample.now.horizontal != input->previous_input.horizontal;
    if (input->control == T5_CONTROL_PAD && env->unpause) {  // a button held through the pause is no press
        sample.pressed = T5_BUTTONS_NONE;  // no new presses
        sample.directions_entered = true;  // the held direction counts as newly entered
    }

    if (input->latch_asked == T5_BUTTONS_NONE || input->first_punch == T5_BUTTONS_NONE)  // not asked yet, or no punch seen yet
        input->first_punch = first_punch_of(sample);  // keep following the first punch pressed
    Words words = decode_words(sample, input->direction_held);  // turn the pad state into the three input words
    input->buttons = words.buttons;  // pressed, held, not held
    input->direction_held = words.direction_held;  // direction held
    input->direction_new = words.direction_new;  // direction entered
    input->previous_input = sample.now;  // next frame compares against this
    if (input->mode == T5_INPUT_LOCKED) t5_input_neutral(input, history, sample.now);  // locked: input is read, then wiped
    if (history) history_push(history, words_of(input));  // record this frame (neutral words if locked)
}

void t5_input_frame(T5Input *input, T5History *history, const T5InputEnv *env) {
    if (input->mode == T5_INPUT_NEUTRAL) t5_input_neutral(input, history, env->pad);  // neutral mode: no input at all
    else if (input->mode <= T5_INPUT_LIVE) t5_input_sample(input, history, env);  // locked or live: read input; above: frozen
}

// --- command matching

static Words history_words(const T5History *history, uint8_t slot) {  // the three words of one ring slot
    return (Words){history->buttons[slot], history->direction_held[slot], history->direction_new[slot]};
}

static bool directions_match(uint16_t code, Words words) {
    uint16_t wanted = code & DIRECTIONS_COMPARED;  // the directions the command asks for
    if (!wanted) return true;  // no direction asked: anything fits
    if ((wanted & T5_DIRECTION_NEW_PRESS) && !(wanted & words.direction_new)) return false;  // must be newly entered, was not
    return wanted & words.direction_held;  // one of the wanted directions is held
}

// The buttons half of a command: bits 0..11 as in the button word, then the mode bits.
enum {
    COMMAND_ANY_PRESS = 1 << 12,        // one of the presses is enough
    COMMAND_HOLD_AFTER_PRESS = 1 << 13, // presses must be held, and one must be new
    COMMAND_SUMMARY = 1 << 14,          // the buttons half is one of the summaries below
};

// Whole-word tests of the buttons half: no press, no hold, some press, some hold.
typedef struct {
    uint16_t buttons;
    bool of_held, any;
} Summary;

static const Summary summaries[] = {
    {COMMAND_SUMMARY + 0, false, false},
    {COMMAND_SUMMARY + 1, true, false},
    {COMMAND_SUMMARY + 2, false, true},
    {COMMAND_SUMMARY + 3, true, true},
};

// Shoulder buttons at `shift` of a word as buttons 5 and 6 of a set.
static T5ButtonSet shoulders_of(uint16_t word, int shift) {
    return (T5ButtonSet)(((word >> shift) & ((1 << SHOULDER_BITS) - 1)) << SHOULDER_SHIFT);
}

static bool buttons_match(T5Command command, Words words) {
    if (command.buttons == 0) return true;  // no buttons asked: anything fits
    for (size_t summary_index = 0; summary_index < sizeof summaries / sizeof *summaries; summary_index++) {  // is it a summary?
        if (command.buttons != summaries[summary_index].buttons) continue;  // not this one
        T5ButtonSet word_set = t5_buttons_pressed(words.buttons);  // summary of presses this frame,
        if (summaries[summary_index].of_held) word_set = t5_buttons_held(words.buttons);  // or of buttons held
        return (word_set != 0) == summaries[summary_index].any;  // "some" needs one or more buttons, "no" needs none
    }

    T5ButtonSet press = t5_buttons_pressed(command.buttons)  // buttons the command wants pressed this frame
                        | shoulders_of(command.code, DIRECTION_SHOULDER_NEW_SHIFT);
    T5ButtonSet hold = t5_buttons_held(command.buttons)  // buttons the command wants held
                       | shoulders_of(command.code, DIRECTION_SHOULDER_HELD_SHIFT);
    T5ButtonSet not_held = t5_buttons_not_held(command.buttons);  // buttons the command wants released
    T5ButtonSet pressed_now = t5_buttons_pressed(words.buttons)  // buttons pressed this frame, shoulders included
                            | shoulders_of(words.direction_held, DIRECTION_SHOULDER_NEW_SHIFT)
                            | shoulders_of(words.buttons, BUTTON_SHOULDER_NEW_SHIFT);
    T5ButtonSet held_now = t5_buttons_held(words.buttons)  // buttons held this frame, shoulders included
                         | shoulders_of(words.direction_held, DIRECTION_SHOULDER_HELD_SHIFT)
                         | shoulders_of(words.buttons, BUTTON_SHOULDER_HELD_SHIFT);
    if (press) {  // the command needs button presses
        if (command.buttons & COMMAND_ANY_PRESS) {  // any one of the buttons will do
            if (!(pressed_now & press)) return false;  // none of them was pressed this frame
        } else if (command.buttons & COMMAND_HOLD_AFTER_PRESS) {  // all must be down, at least one new
            hold |= press;  // the buttons must also be held
            if (!(pressed_now & press)) return false;  // and at least one pressed this frame
        } else if ((pressed_now & press) != press) {  // default: every button pressed this frame
            return false;
        }
    }
    return (held_now & hold) == hold  // all wanted holds are held
           && (t5_buttons_not_held(words.buttons) & not_held) == not_held;  // and all wanted releases are up
}

// The game compares this button word, but no sample sets it.
static constexpr uint16_t BUTTONS_UNREACHABLE = (1 << 14) | (T5_BUTTON_3 << T5_PRESSED_SHIFT);

static bool key_match(T5Command command, Words words, bool lock) {
    if (!directions_match(command.code, words)) return false;  // the stick part must fit
    if (lock || words.buttons == BUTTONS_UNREACHABLE) return command.buttons == 0;  // locked: only commands without buttons fit
    return buttons_match(command, words);  // then the button part must fit
}

// Newest entry first; extra frames between entries are free unless they hold a button press.
static bool sequence_match(const T5Input *input, const T5History *history, const T5InputSequence *sequence,
                           const T5Command *keys, bool lock) {
    int key_index = sequence->count - 1;  // match from the newest key back to the oldest
    uint8_t next = history->next;  // the slot after the next one to test
    if (keys[key_index].buttons) {  // the newest entry is the live frame
        if (!key_match(keys[key_index], words_of(input), lock)) return false;  // the live input must fit the newest key
        if (key_index == 0) return true;  // a one key sequence is done
        key_index--;  // go on to the older key
        next--;  // step past the newest history slot (the live frame)
    }
    for (int window = sequence->window; window > 0; window--) {  // look back at most `window` frames
        Words words = history_words(history, --next);  // one frame further back
        if (key_match(keys[key_index], words, lock)) {  // this frame fits the key we look for
            if (key_index == 0) return true;  // every key found
            key_index--;  // now look for the next older key
        } else if (t5_buttons_pressed(words.buttons)) {  // a button press that fits no key
            return false;  // breaks the sequence
        }
    }
    return false;  // ran out of window before the oldest key
}

typedef struct {
    int length;
    uint8_t end;  // the first slot that does not belong to the run
} Run;

// Slots from `start` backward that hold exactly `direction`, at most `limit`.
static Run run_back(const T5History *history, uint8_t start, uint16_t direction, int limit) {
    Run run = {0, start};
    while (run.length < limit  // go back frame by frame while the held direction is exactly `direction`
           && (history->direction_held[run.end] & DIRECTIONS_COMPARED) == direction) {
        run.length++;  // one more frame in the run
        run.end--;  // one slot back (a byte, wraps around the ring)
    }
    return run;
}

// (hole strict-sequences :tags (sim tk5mod) :needs tk5-input-load) sequences have no strict joiner (':'), so dashes and taps need their own matchers; with it they become sequences ({f:n:^f}20), and the oracle shows whether that is exact or a deviation to record.
// Dash: `direction` entered now; before it N for n frames, before that `direction` for m frames, n + m <= DASH_FRAMES.
static bool dash_match(const T5Input *input, const T5History *history, uint16_t direction) {
    if ((input->direction_new & DIRECTIONS_COMPARED) != direction) return false;  // the direction must be entered this frame
    Run neutral = run_back(history, (uint8_t)(history->next - 2), T5_DIRECTION_N, DASH_FRAMES.ticks);  // neutral before now
    if (neutral.length == 0) return false;  // the stick must have been released first
    Run held = run_back(history, neutral.end, direction, DASH_FRAMES.ticks + 1 - neutral.length);  // the first tap before that
    return held.length > 0 && neutral.length + held.length <= DASH_FRAMES.ticks;  // there was a first tap, all within dash time
}

// Tap: N now and before (n frames in all), `direction` for m frames before that, n + m <= TAP_FRAMES, then N again.
static bool tap_match(const T5Input *input, const T5History *history, uint16_t direction) {
    if ((input->direction_held & DIRECTIONS_COMPARED) != T5_DIRECTION_N) return false;  // the stick must be neutral now
    Run neutral = run_back(history, (uint8_t)(history->next - 2), T5_DIRECTION_N, TAP_FRAMES.ticks - 1);  // neutral before now
    int neutral_frames = 1 + neutral.length;  // plus this frame
    Run held = run_back(history, neutral.end, direction, TAP_FRAMES.ticks + 1 - neutral_frames);  // the tap before the neutral
    return held.length > 0 && neutral_frames + held.length <= TAP_FRAMES.ticks  // a tap happened, all within tap time,
           && (history->direction_held[held.end] & DIRECTIONS_COMPARED) == T5_DIRECTION_N;  // and neutral came before it
}

bool t5_command_match(const T5Input *input, const T5History *history, const T5Motbin *motbin, const T5Cancel *cancel) {
    if (cancel->option & T5_OPTION_NO_INPUT) return true;  // the cancel asks for no input
    bool lock = input->mode == T5_INPUT_LOCKED  // a locked fighter's commands fail,
                && !(cancel->extradata & EXTRA_UNLOCKS_COMMAND);  // unless the cancel unlocks them
    uint16_t kind = cancel->command.code;  // plain key, or a special kind above the end code
    if (kind < T5_CANCEL_END) return key_match(cancel->command, words_of(input), lock);  // plain stick and button command
    switch (kind) {
    case T5_CANCEL_DASH_F: return dash_match(input, history, T5_DIRECTION_F);  // forward dash: forward, neutral, forward
    case T5_CANCEL_DASH_B: return dash_match(input, history, T5_DIRECTION_B);  // back dash: back, neutral, back
    case T5_CANCEL_TAP_U: return tap_match(input, history, T5_DIRECTION_U);  // quick tap up
    case T5_CANCEL_TAP_D: return tap_match(input, history, T5_DIRECTION_D);  // quick tap down
    case T5_CANCEL_END:
    case T5_CANCEL_GROUP:
    case T5_CANCEL_GROUP_END: return false;  // the game prints "Illegal KEY condition" for the group codes
    }
    const T5InputSequence *sequence =  // codes from SEQUENCE up pick one of the moveset's input sequences
        &motbin->input_sequences[kind - T5_CANCEL_SEQUENCE];
    return sequence_match(input, history, sequence, &motbin->input_extras[sequence->first], lock);  // its keys are in the extras
}

// --- cancel scan

// Window, input, requirements of one entry. True when the scan stops on it.
static bool stops_scan(const T5Cancel *cancel, int32_t frame, T5CancelScan *scan) {
    if (frame < cancel->window_start || frame > cancel->window_end) return false;  // the move frame is outside the entry's window
    if (cancel->option & T5_OPTION_INPUT) scan->input_window = true;  // tell the caller an input window is open
    if (cancel->option & T5_OPTION_TRACK) scan->option8 = 0;  // tracked entry in its window: clear the flag
    if ((cancel->option & T5_OPTION_REVERSAL)  // reversals match on a hit taken, never here
        || !t5_command_match(scan->input, scan->history, scan->motbin, cancel)  // the input does not fit the command
        || !scan->requirements.check(scan->requirements.context, cancel))  // or the requirements fail
        return false;
    scan->requirements.apply(scan->requirements.context, cancel);  // also for entries that do not stop
    if (cancel->option & T5_OPTION_TRACK) scan->option8 = 1;  // the tracked entry matched
    return cancel->option & T5_OPTION_STOP;  // only entries marked stop end the scan
}

static const T5Cancel *list_end(const T5Cancel *cancel) {
    while (cancel->command.code != T5_CANCEL_END) cancel++;  // walk forward to the end entry
    return cancel;
}

// The game's flag for "no window open yet" has no reader and is left out.
const T5Cancel *t5_cancel_scan(const T5Cancel *cancel, int32_t frame, T5CancelScan *scan) {
    scan->input_window = false;  // no input window seen yet
    scan->requirements.reset(scan->requirements.context);  // requirements start fresh for this scan
    const T5Cancel *group_entry = 0;  // the group entry being walked, to come back to
    for (;;) {  // repeat when a locked entry is skipped
        while (cancel->command.code != T5_CANCEL_END) {  // go through the entries until the end entry
            const T5Cancel *entry = cancel;  // the entry to test
            if (entry->command.code == T5_CANCEL_GROUP) {  // a group: test its shared entries here
                group_entry = entry;  // remember where to come back to
                entry = &scan->motbin->group_cancels[entry->move];  // the group's first entry
            } else if (entry->command.code == T5_CANCEL_GROUP_END) {  // end of the group
                cancel = group_entry + 1;  // carry on after the group entry
                continue;
            }
            if (stops_scan(entry, frame, scan)) {  // window, input and requirements fit, and it stops the scan
                cancel = entry;  // this is the result
                break;
            }
            cancel = entry + 1;  // no stop: next entry
        }
        if (cancel->extradata == EXTRA_NO_MOVE) cancel = list_end(cancel);  // "no move": fall to the end entry
        if (!(cancel->option & T5_OPTION_LOCK_SKIP) || cancel->command.code == T5_CANCEL_END
            || !scan->cancel_lock) return cancel;  // done, unless a lock-skip entry is passed over while cancel lock is set
        cancel++;  // skip that entry and scan on
    }
}
