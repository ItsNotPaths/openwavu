// Input concept: the standard input of a fighter, its input words, the history ring, command matching
// and the input side of the cancel scan. docs/input.md; offsets are the game's fighter (p+) and history block (H+).
#ifndef T5_INPUT_H
#define T5_INPUT_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/motbin.h"

// --- input words of a fighter

// Direction words (direction_held, direction_new): one numpad bit (1 << key), plus shoulder bits. In direction_new no
// change is NO_CHANGE.
// The command code uses the same bits, and NEW_PRESS means the direction must be newly entered.
enum {
    T5_DIRECTION_NO_CHANGE = 1 << 0, T5_DIRECTION_DB = 1 << 1, T5_DIRECTION_D = 1 << 2, T5_DIRECTION_DF = 1 << 3,
    T5_DIRECTION_B = 1 << 4, T5_DIRECTION_N = 1 << 5, T5_DIRECTION_F = 1 << 6,
    T5_DIRECTION_UB = 1 << 7, T5_DIRECTION_U = 1 << 8, T5_DIRECTION_UF = 1 << 9,
    T5_DIRECTION_NEW_PRESS = 1 << 10,
};

// A set of game buttons: bit i is button i + 1, so buttons 1 and 2 are 3 and all four are 15.
// The four face buttons are one 4-bit mask: button 1 is left punch (LP), 2 right punch (RP), 3 left kick (LK),
// 4 right kick (RK). Pressing several together sets several bits at once, so LP+RP is 3. Which pad button gives
// which game button is the client's map.
typedef uint8_t T5ButtonSet;

enum {
    T5_BUTTONS_NONE = 0,
    T5_BUTTON_1 = 1 << 0, T5_BUTTON_2 = 1 << 1, T5_BUTTON_3 = 1 << 2, T5_BUTTON_4 = 1 << 3,
    T5_BUTTONS_ALL = (1 << 4) - 1,
    T5_BUTTON_L1 = 1 << 4, T5_BUTTON_R1 = 1 << 5,  // extra buttons: the CPU and scripts can press them, the stock pad menu cannot
};

// The button word is three sets of four bits: pressed this frame, held, not held.
enum { T5_PRESSED_SHIFT = 0, T5_HELD_SHIFT = 4, T5_NOT_HELD_SHIFT = 8 };  // held or not held; pressed ones are also held

[[nodiscard]] static inline T5ButtonSet t5_buttons_pressed(uint16_t word) { return (word >> T5_PRESSED_SHIFT) & T5_BUTTONS_ALL; }
[[nodiscard]] static inline T5ButtonSet t5_buttons_held(uint16_t word) { return (word >> T5_HELD_SHIFT) & T5_BUTTONS_ALL; }
[[nodiscard]] static inline T5ButtonSet t5_buttons_not_held(uint16_t word) {  // the buttons not held
    return (word >> T5_NOT_HELD_SHIFT) & T5_BUTTONS_ALL;
}

// The standard input of one fighter for one frame. The client (harness/pad.h) maps and cleans the pad: opposite
// directions cannot happen, and which physical button presses which game buttons is its map. Presses are derived
// in the sim from the held set and the last frame.
typedef struct {
    int8_t vertical;    // -1 down, 0, +1 up
    int8_t horizontal;  // -1 screen left, 0, +1 screen right. The sim turns it into forward and back from the side
    T5ButtonSet held;   // buttons 1..4 and the extra L1, R1
} T5StdInput;

typedef enum : uint32_t {  // What the fighter does with input this frame.
    T5_INPUT_NEUTRAL = 0,  // neutral words, history cleared
    T5_INPUT_LOCKED = 1,   // sampled, then forced neutral; commands need extra permission
    T5_INPUT_LIVE = 2,
                           // above LIVE: frozen, the words of the last frame stay
} T5InputMode;

typedef enum : uint8_t {  // Who drives the fighter.
    T5_CONTROL_PAD = 0,
    T5_CONTROL_CPU = 1,
    T5_CONTROL_SCRIPT = 2,
    T5_CONTROL_NONE_3 = 3,  // 3 and 4 give no input
    T5_CONTROL_NONE_4 = 4,
    T5_CONTROL_5 = 5,       // round reset sets no throw link for it; no writer known
} T5Control;

typedef enum : uint8_t { T5_SIDE_LEFT = 0, T5_SIDE_RIGHT = 1 } T5Side;  // screen side of a fighter

typedef struct {
    T5InputMode mode;
    T5StdInput previous_input;  // the game keeps the held pad word of the last frame
    uint16_t buttons;         // button word: pressed, held, not held sets of this frame
    uint16_t direction_held;  // the direction the fighter holds now, relative to the opponent
    uint16_t direction_new;   // the direction they just entered; NO_CHANGE if the stick did not move
    T5Control control;
    T5Side camera_side;    // host input, filled with the pad: right of the opponent on screen
    T5Side side;           // camera_side as of the last side update
    T5Side side_copy;      // written with side, no reader
    T5Side side_latched;      // side at frame start: directions and the side requirements use it
    T5ButtonSet latch_asked;  // punches (buttons 1, 2, both) a throw-break requirement asked about in this move (reqs 106..108)
    T5ButtonSet first_punch;  // the first punch press; follows every frame until a requirement asks
} T5Input;

// Queries of other modules.
[[nodiscard]] static inline bool t5_input_pad_driven(const T5Input *input) { return input->control == T5_CONTROL_PAD; }
[[nodiscard]] static inline bool t5_input_cpu_driven(const T5Input *input) { return input->control == T5_CONTROL_CPU; }
[[nodiscard]] static inline bool t5_input_control_is(const T5Input *input, uint16_t control) { return input->control == control; }
[[nodiscard]] static inline bool t5_input_mode_is(const T5Input *input, uint32_t mode) { return input->mode == mode; }
[[nodiscard]] static inline bool t5_input_on_right(const T5Input *input) {  // fighter is on the right of the screen
    return input->side_latched != T5_SIDE_LEFT;
}
[[nodiscard]] static inline bool t5_input_holds(const T5Input *input, uint16_t directions) {  // any of these directions is held
    return (input->direction_held & directions) != 0;
}
[[nodiscard]] static inline bool t5_input_pressed_any(const T5Input *input) { return t5_buttons_pressed(input->buttons) != 0; }

void t5_input_set_mode(T5Input *input, T5InputMode mode);  // neutral also forgets the last input
void t5_input_round_start(T5Input *input);               // start: side 0, no latch request
void t5_input_round_end(T5Input *input, T5Side start_side); // end: first punch cleared; side until the host's next frame
bool t5_input_ask_first_punch(T5Input *input, T5ButtonSet punches);  // reqs 106..108: was it `punches`? Also asks the latch to hold

// --- history

enum { T5_HISTORY_FRAMES = 256, T5_CHANGE_LOG_SIZE = 25 };
static_assert(T5_HISTORY_FRAMES == UINT8_MAX + 1, "the ring index is a byte");

// Input history of one side: a ring of the last 256 frames of words. Command matching looks back through it, so
typedef struct {  // a dash or a motion can be read from frames before the live one.
    int32_t log_held_only;                          // nonzero: the log keeps only held buttons and direction
    uint8_t next;                                   // ring write index (s32 0..255 in the game)
    uint8_t log_next;                               // (s32 0..24)
    uint16_t log_last_buttons;
    uint16_t log_last_direction_held;
    uint16_t log_last_direction_new;
    uint16_t buttons[T5_HISTORY_FRAMES];
    uint16_t direction_held[T5_HISTORY_FRAMES];
    uint16_t direction_new[T5_HISTORY_FRAMES];
    uint16_t log_buttons[T5_CHANGE_LOG_SIZE];       // change log, no reader
    uint16_t log_direction_held[T5_CHANGE_LOG_SIZE];
    uint16_t log_direction_new[T5_CHANGE_LOG_SIZE];
} T5History;

// --- frame

// Input from a non-pad source: the CPU AI or a script. The CPU AI always plays as if on the left
// side: horizontal +1 is forward.
typedef struct {
    T5StdInput (*read)(void *context);
    void *context;
} T5InputHook;

// What a frame of input reads outside the fighter.
typedef struct {
    T5StdInput pad;       // the pad of this fighter's side
    bool unpause;         // first frame after a pause
    bool ko;              // health is 0
    T5InputHook cpu;      // control CPU; null read gives no input
    T5InputHook script;   // control script
} T5InputEnv;

// `history` is null for objects without history (extras).
void t5_side_update(T5Input *input);                                 // side from the host's camera_side
void t5_side_latch(T5Input *first, T5Input *second);  // both fighters fix their side for the frame
void t5_history_clear(T5History *history);  // forget all past input
void t5_input_neutral(T5Input *input, T5History *history, T5StdInput pad);  // no buttons, stick centered, no history
void t5_input_sample(T5Input *input, T5History *history, const T5InputEnv *env);  // read the source, make the words, push history
void t5_input_frame(T5Input *input, T5History *history, const T5InputEnv *env);   // one frame of input by input mode

// --- commands and the cancel scan

// Command test of a cancel: does what the fighter pressed now (and in the last frames) fit the cancel's command?
// `motbin` is the moveset in use, for input sequences.
bool t5_command_match(const T5Input *input, const T5History *history, const T5Motbin *motbin, const T5Cancel *cancel);

// Requirement layer as seen by the scan (stubs until requirements are ported).
typedef struct {
    void (*reset)(void *context);
    bool (*check)(void *context, const T5Cancel *cancel);
    void (*apply)(void *context, const T5Cancel *cancel); // instant properties
    void *context;
} T5RequirementHooks;

typedef struct {
    const T5Input *input;
    const T5History *history;
    const T5Motbin *motbin;   // group cancels, input sequences
    uint16_t cancel_lock;     // nonzero: entries marked LOCK_SKIP are passed over
    uint16_t option8;         // in/out
    bool input_window;        // out: a T5_OPTION_INPUT entry was in its window
    T5RequirementHooks requirements;
} T5CancelScan;

// Walks the cancel list in order and returns the first entry whose window, command and requirements all fit and
// which stops the scan, or the list's end entry.
const T5Cancel *t5_cancel_scan(const T5Cancel *cancel, int32_t frame, T5CancelScan *scan);

#endif
