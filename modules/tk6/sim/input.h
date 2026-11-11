// Input concept: the standard input of a fighter, its input words, the history ring, command matching
// and the input side of the cancel scan.
#ifndef T6_INPUT_H
#define T6_INPUT_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/motbin.h"

// --- input words of a fighter

// Direction words (direction_held, direction_new): one numpad bit (1 << key), plus shoulder bits. In direction_new no
// change is NO_CHANGE.
// The command code uses the same bits, and NEW_PRESS means the direction must be newly entered.
enum {
    T6_DIRECTION_NO_CHANGE = 1 << 0, T6_DIRECTION_DB = 1 << 1, T6_DIRECTION_D = 1 << 2, T6_DIRECTION_DF = 1 << 3,
    T6_DIRECTION_B = 1 << 4, T6_DIRECTION_N = 1 << 5, T6_DIRECTION_F = 1 << 6,
    T6_DIRECTION_UB = 1 << 7, T6_DIRECTION_U = 1 << 8, T6_DIRECTION_UF = 1 << 9,
    T6_DIRECTION_NEW_PRESS = 1 << 10,
};

// A set of game buttons: bit i is button i + 1, so buttons 1 and 2 are 3 and all four are 15.
// The four face buttons are one 4-bit mask: button 1 is left punch (LP), 2 right punch (RP), 3 left kick (LK),
// 4 right kick (RK). Pressing several together sets several bits at once, so LP+RP is 3. Which pad button gives
// which game button is the client's map.
typedef uint8_t T6ButtonSet;

enum {
    T6_BUTTONS_NONE = 0,
    T6_BUTTON_1 = 1 << 0, T6_BUTTON_2 = 1 << 1, T6_BUTTON_3 = 1 << 2, T6_BUTTON_4 = 1 << 3,
    T6_BUTTONS_ALL = (1 << 4) - 1,
    T6_BUTTON_L1 = 1 << 4, T6_BUTTON_R1 = 1 << 5,  // extra buttons: the CPU and scripts can press them, the stock pad menu cannot
};

// L1 and R1 (buttons 5, 6 of a set) in a direction word, also in a command code: pressed (new) and held, two bits each.
enum { T6_SHOULDER_SHIFT = 4, T6_DIRECTION_SHOULDER_NEW_SHIFT = 11, T6_DIRECTION_SHOULDER_HELD_SHIFT = 13 };

// The button word is three sets of four bits: pressed this frame, held, not held.
enum { T6_PRESSED_SHIFT = 0, T6_HELD_SHIFT = 4, T6_NOT_HELD_SHIFT = 8 };  // held or not held; pressed ones are also held

[[nodiscard]] static inline T6ButtonSet t6_buttons_pressed(uint16_t word) { return (word >> T6_PRESSED_SHIFT) & T6_BUTTONS_ALL; }
[[nodiscard]] static inline T6ButtonSet t6_buttons_held(uint16_t word) { return (word >> T6_HELD_SHIFT) & T6_BUTTONS_ALL; }
[[nodiscard]] static inline T6ButtonSet t6_buttons_not_held(uint16_t word) {  // the buttons not held
    return (word >> T6_NOT_HELD_SHIFT) & T6_BUTTONS_ALL;
}

// The standard input of one fighter for one frame. The client maps and cleans the pad: opposite
// directions cannot happen, and which physical button presses which game buttons is its map. Presses are derived
// in the sim from the held set and the last frame.
typedef struct {
    int8_t vertical;    // -1 down, 0, +1 up
    int8_t horizontal;  // -1 screen left, 0, +1 screen right. The sim turns it into forward and back from the side
    T6ButtonSet held;   // buttons 1..4 and the extra L1, R1
} T6StdInput;

typedef enum : uint32_t {  // What the fighter does with input this frame.
    T6_INPUT_NEUTRAL = 0,  // neutral words, history cleared
    T6_INPUT_LOCKED = 1,   // sampled, then forced neutral; commands need extra permission
    T6_INPUT_LIVE = 2,
                           // above LIVE: frozen, the words of the last frame stay
} T6InputMode;

typedef enum : uint8_t {  // Who drives the fighter.
    T6_CONTROL_PAD = 0,
    T6_CONTROL_CPU = 1,
    T6_CONTROL_SCRIPT = 2,
    T6_CONTROL_NONE_3 = 3,  // 3 and 4 give no input
    T6_CONTROL_NONE_4 = 4,
    T6_CONTROL_5 = 5,       // round reset sets no throw link for it; no writer known
} T6Control;

typedef enum : uint8_t { T6_SIDE_LEFT = 0, T6_SIDE_RIGHT = 1 } T6Side;  // screen side of a fighter

typedef struct {
    T6InputMode mode;
    T6StdInput previous_input;  // the game keeps the held pad word of the last frame
    uint16_t buttons;         // button word: pressed, held, not held sets of this frame
    uint16_t direction_held;  // the direction the fighter holds now, relative to the opponent
    uint16_t direction_new;   // the direction they just entered; NO_CHANGE if the stick did not move
    T6Control control;
    T6Side camera_side;    // host input, filled with the pad: right of the opponent on screen
    T6Side side;           // camera_side as of the last side update
    T6Side side_copy;      // written with side, no reader
    T6Side side_latched;      // side at frame start: directions and the side requirements use it
    T6ButtonSet latch_asked;  // punches (buttons 1, 2, both) a throw-break requirement asked about in this move (reqs 106..108)
    T6ButtonSet first_punch;  // the first punch press; follows every frame until a requirement asks
} T6Input;

// Queries of other modules.
[[nodiscard]] static inline bool t6_input_pad_driven(const T6Input *input) { return input->control == T6_CONTROL_PAD; }
[[nodiscard]] static inline bool t6_input_cpu_driven(const T6Input *input) { return input->control == T6_CONTROL_CPU; }
[[nodiscard]] static inline bool t6_input_control_is(const T6Input *input, uint16_t control) { return input->control == control; }
[[nodiscard]] static inline bool t6_input_mode_is(const T6Input *input, uint32_t mode) { return input->mode == mode; }
[[nodiscard]] static inline bool t6_input_on_right(const T6Input *input) {  // fighter is on the right of the screen
    return input->side_latched != T6_SIDE_LEFT;
}
[[nodiscard]] static inline bool t6_input_holds(const T6Input *input, uint16_t directions) {  // any of these directions is held
    return (input->direction_held & directions) != 0;
}
[[nodiscard]] static inline bool t6_input_pressed_any(const T6Input *input) { return t6_buttons_pressed(input->buttons) != 0; }

void t6_input_set_mode(T6Input *input, T6InputMode mode);  // neutral also forgets the last input
void t6_input_round_start(T6Input *input);               // start: side 0, no latch request
void t6_input_round_end(T6Input *input, T6Side start_side); // end: first punch cleared; side until the host's next frame
bool t6_input_ask_first_punch(T6Input *input, T6ButtonSet punches);  // reqs 106..108: was it `punches`? Also asks the latch to hold

// --- history

enum { T6_HISTORY_FRAMES = 256, T6_CHANGE_LOG_SIZE = 25 };
static_assert(T6_HISTORY_FRAMES == UINT8_MAX + 1, "the ring index is a byte");

// Input history of one side: a ring of the last 256 frames of words. Command matching looks back through it, so
typedef struct {  // a dash or a motion can be read from frames before the live one.
    int32_t log_held_only;                          // nonzero: the log keeps only held buttons and direction
    uint8_t next;                                   // ring write index (s32 0..255 in the game)
    uint8_t log_next;                               // (s32 0..24)
    uint16_t log_last_buttons;
    uint16_t log_last_direction_held;
    uint16_t log_last_direction_new;
    uint16_t buttons[T6_HISTORY_FRAMES];
    uint16_t direction_held[T6_HISTORY_FRAMES];
    uint16_t direction_new[T6_HISTORY_FRAMES];
    uint16_t log_buttons[T6_CHANGE_LOG_SIZE];       // change log, no reader
    uint16_t log_direction_held[T6_CHANGE_LOG_SIZE];
    uint16_t log_direction_new[T6_CHANGE_LOG_SIZE];
} T6History;

// --- frame

// Input from a non-pad source: the CPU AI or a script. The CPU AI always plays as if on the left
// side: horizontal +1 is forward.
typedef struct {
    T6StdInput (*read)(void *context);
    void *context;
} T6InputHook;

// What a frame of input reads outside the fighter.
typedef struct {
    T6StdInput pad;       // the pad of this fighter's side
    bool unpause;         // first frame after a pause
    bool ko;              // health is 0
    T6InputHook cpu;      // control CPU; null read gives no input
    T6InputHook script;   // control script
} T6InputEnv;

// `history` is null for objects without history (extras).
void t6_side_update(T6Input *input);                                 // side from the host's camera_side
void t6_side_latch(T6Input *first, T6Input *second);  // both fighters fix their side for the frame
void t6_history_clear(T6History *history);  // forget all past input
void t6_input_neutral(T6Input *input, T6History *history, T6StdInput pad);  // no buttons, stick centered, no history
void t6_input_sample(T6Input *input, T6History *history, const T6InputEnv *env);  // read the source, make the words, push history
void t6_input_frame(T6Input *input, T6History *history, const T6InputEnv *env);   // one frame of input by input mode

// --- commands and the cancel scan

// Command test of a cancel: does what the fighter pressed now (and in the last frames) fit the cancel's command?
// `motbin` is the moveset in use, for input sequences.
bool t6_command_match(const T6Input *input, const T6History *history, const T6Motbin *motbin, const T6Cancel *cancel);

// Requirement layer as seen by the scan (stubs until requirements are ported).
typedef struct {
    void (*reset)(void *context);
    bool (*check)(void *context, const T6Cancel *cancel);
    void (*apply)(void *context, const T6Cancel *cancel); // instant properties
    void *context;
} T6RequirementHooks;

typedef struct {
    const T6Input *input;
    const T6History *history;
    const T6Motbin *motbin;   // group cancels, input sequences
    uint16_t cancel_lock;     // nonzero: entries marked LOCK_SKIP are passed over
    uint16_t option8;         // in/out
    bool input_window;        // out: a T6_OPTION_INPUT entry was in its window
    T6RequirementHooks requirements;
} T6CancelScan;

// Walks the cancel list in order and returns the first entry whose window, command and requirements all fit and
// which stops the scan, or the list's end entry.
const T6Cancel *t6_cancel_scan(const T6Cancel *cancel, int32_t frame, T6CancelScan *scan);

#endif
