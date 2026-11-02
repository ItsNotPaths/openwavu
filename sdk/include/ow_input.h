// openwavu command syntax (docs/commands.md): a cancel's input and timing as text, the same for every game.
// One C file defines OW_INPUT_IMPLEMENTATION before including it.
#ifndef OW_INPUT_H
#define OW_INPUT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>  // no openwavu.h: the TK5 loader also builds natively

enum { OW_INPUT_STEPS = 16 };

// Directions relative to the facing side, as bits of OwInputStep.directions.
enum {
    OW_DIR_DB = 1 << 0, OW_DIR_D = 1 << 1, OW_DIR_DF = 1 << 2, OW_DIR_B = 1 << 3, OW_DIR_N = 1 << 4,
    OW_DIR_F = 1 << 5, OW_DIR_UB = 1 << 6, OW_DIR_U = 1 << 7, OW_DIR_UF = 1 << 8,
    OW_DIR_ALL = (1 << 9) - 1,
};

typedef enum : uint8_t {
    OW_PRESS_TOGETHER,  // 1+2: all held, one pressed this frame; a one-button press is always this
    OW_PRESS_SAME_FRAME,  // {1+2}1
    OW_PRESS_ANY,       // 1/2
} OwPressMode;

typedef enum : uint8_t { OW_SUMMARY_NONE, OW_SUMMARY_SOME_PRESS, OW_SUMMARY_NO_PRESS, OW_SUMMARY_SOME_HELD, OW_SUMMARY_NOTHING_HELD } OwSummary;

typedef struct {
    uint16_t directions;  // any of these held; 0: any
    bool tap;             // ^: pushed this frame
    bool strict;          // joined to the step before by ':'
    uint8_t press, held, not_held;  // button sets: bit i is the game's button i
    OwPressMode press_mode;
    OwSummary summary;
} OwInputStep;

typedef struct {
    OwInputStep steps[OW_INPUT_STEPS];
    uint8_t step_count;   // 0: no input
    uint16_t window;      // {…}N; one step with window 0 is tested on this frame only
    uint16_t open, close; // @open..close, frames of the current move
    uint16_t start;       // >start, frame of the next move
} OwInput;

// buttons: the game's button names by bit, NULL-terminated; no name may be a direction.
// Returns NULL, or what is wrong with the text.
const char *ow_input_parse(const char *text, uint32_t length, const char *const *buttons, OwInput *out);

// The exact text of an input; returns its length, or 0 when it does not fit.
uint32_t ow_input_text(const OwInput *input, const char *const *buttons, char *out, uint32_t room);

// The plain notation players use (f,f+1+2), for reading only.
// (hole input-notation :tags (sdk editor) :sev polish) no plain notation printer for move lists, the pause menu and the editor.
uint32_t ow_input_notation(const OwInput *input, const char *const *buttons, char *out, uint32_t room);

#ifdef OW_INPUT_IMPLEMENTATION

enum { OW_INPUT_TEXT = 1024 };

static const char *const ow_direction_names[] = {"db", "d", "df", "b", "n", "f", "ub", "u", "uf", NULL};  // by OW_DIR_* bit

static const struct { char name[3]; uint16_t bits; } ow_direction_groups[] = {
    {"*b", OW_DIR_DB | OW_DIR_B | OW_DIR_UB}, {"*f", OW_DIR_DF | OW_DIR_F | OW_DIR_UF},
    {"*d", OW_DIR_DB | OW_DIR_D | OW_DIR_DF}, {"*u", OW_DIR_UB | OW_DIR_U | OW_DIR_UF}, {"*", OW_DIR_ALL},
};

static const char *const ow_summary_names[] = {"", "*", "!*", "*~", "!*~"};

typedef struct {
    const char *at, *end;
    const char *const *buttons;
} OwReader;

static uint32_t ow_length(const char *text) {
    uint32_t length = 0;
    while (text[length]) length++;
    return length;
}

static bool ow_starts(const OwReader *r, const char *name) {
    uint32_t length = ow_length(name);
    if ((uint32_t)(r->end - r->at) < length) return false;
    for (uint32_t i = 0; i < length; i++)
        if (r->at[i] != name[i]) return false;
    return true;
}

static char ow_peek(const OwReader *r, uint32_t ahead) { return r->end - r->at > ahead ? r->at[ahead] : 0; }

static bool ow_take(OwReader *r, char c) {
    if (ow_peek(r, 0) != c) return false;
    r->at++;
    return true;
}

// The longest of the names at the reader; -1 when none.
static int32_t ow_name_at(const OwReader *r, const char *const *names) {
    int32_t found = -1;
    uint32_t found_length = 0;
    for (int32_t i = 0; names[i]; i++) {
        uint32_t length = ow_length(names[i]);
        if (length > found_length && ow_starts(r, names[i])) found = i, found_length = length;
    }
    return found;
}

static bool ow_take_name(OwReader *r, const char *const *names, int32_t *found) {
    *found = ow_name_at(r, names);
    if (*found < 0) return false;
    r->at += ow_length(names[*found]);
    return true;
}

static bool ow_take_button(OwReader *r, int32_t *button) { return ow_take_name(r, r->buttons, button); }

static bool ow_is_direction_letter(char c) { return c == 'b' || c == 'd' || c == 'f' || c == 'u'; }

// A step starts with directions, or only buttons: `*` and `!*` are buttons unless a direction letter follows.
static bool ow_directions_ahead(const OwReader *r) {
    OwReader ahead = *r;
    if (ow_peek(&ahead, 0) == '^') return true;
    ow_take(&ahead, '!');
    if (ow_peek(&ahead, 0) == '*') return ow_is_direction_letter(ow_peek(&ahead, 1));
    return ow_name_at(&ahead, ow_direction_names) >= 0;
}

static const char *ow_read_number(OwReader *r, uint16_t *out) {
    uint32_t value = 0, digits = 0;
    for (char c; (c = ow_peek(r, 0)) >= '0' && c <= '9'; r->at++, digits++) {
        value = value * 10 + (uint32_t)(c - '0');
        if (value > UINT16_MAX) return "a number is above 65535";
    }
    if (!digits) return "a number is missing";
    *out = (uint16_t)value;
    return NULL;
}

static const char *ow_read_directions(OwReader *r, OwInputStep *step) {
    step->tap = ow_take(r, '^');
    bool negated = ow_take(r, '!');
    uint16_t bits = 0;
    do {
        if (ow_take(r, '*')) {
            int32_t g = 4;  // `*`: all
            for (int32_t i = 0; i < 4; i++)
                if (ow_peek(r, 0) == ow_direction_groups[i].name[1]) g = i;
            if (g < 4) r->at++;
            bits |= ow_direction_groups[g].bits;
            continue;
        }
        int32_t d;
        if (!ow_take_name(r, ow_direction_names, &d)) return "a direction is missing";
        bits |= (uint16_t)(1 << d);
    } while (ow_take(r, '/'));
    step->directions = negated ? OW_DIR_ALL & ~bits : bits;
    return NULL;
}

// `{1+2}1` with no digit after it: the same-frame press, not a sequence.
static bool ow_same_frame_ahead(const OwReader *r) {
    OwReader ahead = *r;
    int32_t button;
    if (!ow_take(&ahead, '{')) return false;
    do
        if (!ow_take_button(&ahead, &button)) return false;
    while (ow_take(&ahead, '+'));
    if (!ow_take(&ahead, '}') || !ow_take(&ahead, '1')) return false;
    char next = ow_peek(&ahead, 0);
    return next < '0' || next > '9';
}

static const char *ow_set_press(OwInputStep *step, uint8_t buttons, OwPressMode mode) {
    if (step->press && (mode != OW_PRESS_TOGETHER || step->press_mode != OW_PRESS_TOGETHER)) return "a step has one press group";
    step->press |= buttons;
    step->press_mode = mode;
    return NULL;
}

static const char *ow_read_button_part(OwReader *r, OwInputStep *step) {
    int32_t button;
    if (ow_peek(r, 0) == '*' || (ow_peek(r, 0) == '!' && ow_peek(r, 1) == '*')) {
        if (step->summary) return "a step has one of * !* *~ !*~";
        bool negated = ow_take(r, '!');
        r->at++;
        bool held = ow_take(r, '~');
        step->summary = negated ? (held ? OW_SUMMARY_NOTHING_HELD : OW_SUMMARY_NO_PRESS) : (held ? OW_SUMMARY_SOME_HELD : OW_SUMMARY_SOME_PRESS);
        return NULL;
    }
    if (ow_take(r, '!')) {
        if (!ow_take_button(r, &button)) return "a button is missing after !";
        step->not_held |= (uint8_t)(1 << button);
        return NULL;
    }
    if (ow_take(r, '{')) {
        uint8_t buttons = 0;
        do {
            if (!ow_take_button(r, &button)) return "a button is missing in {…}1";
            buttons |= (uint8_t)(1 << button);
        } while (ow_take(r, '+'));
        if (!ow_take(r, '}') || !ow_take(r, '1')) return "{…}1 is not closed";
        return ow_set_press(step, buttons, OW_PRESS_SAME_FRAME);
    }
    if (!ow_take_button(r, &button)) return "a direction or button is unknown";
    uint8_t buttons = (uint8_t)(1 << button);
    if (ow_take(r, '~')) {
        step->held |= buttons;
        return NULL;
    }
    if (ow_peek(r, 0) != '/') return ow_set_press(step, buttons, OW_PRESS_TOGETHER);
    while (ow_take(r, '/')) {
        if (!ow_take_button(r, &button)) return "a button is missing after /";
        buttons |= (uint8_t)(1 << button);
    }
    return ow_set_press(step, buttons, OW_PRESS_ANY);
}

static const char *ow_read_step(OwReader *r, OwInputStep *step) {
    *step = (OwInputStep){0};
    const char *failed = NULL;
    if (ow_directions_ahead(r)) {
        failed = ow_read_directions(r, step);
        if (failed || !ow_take(r, '+')) return failed;
    }
    do failed = ow_read_button_part(r, step);
    while (!failed && ow_take(r, '+'));
    return failed;
}

const char *ow_input_parse(const char *text, uint32_t length, const char *const *buttons, OwInput *out) {
    char compact[OW_INPUT_TEXT];  // spaces mean nothing
    uint32_t count = 0;
    for (uint32_t i = 0; i < length; i++) {
        if (text[i] == ' ' || text[i] == '\t') continue;
        if (count == OW_INPUT_TEXT) return "the text is too long";
        compact[count++] = text[i];
    }
    OwReader r = {compact, compact + count, buttons};
    *out = (OwInput){0};
    const char *failed = NULL;
    if (ow_peek(&r, 0) == '{' && !ow_same_frame_ahead(&r)) {
        r.at++;
        do {
            if (out->step_count == OW_INPUT_STEPS) return "a sequence has more than 16 steps";
            OwInputStep *step = &out->steps[out->step_count];
            bool strict = out->step_count && r.at[-1] == ':';
            if ((failed = ow_read_step(&r, step))) return failed;
            step->strict = strict;
            out->step_count++;
        } while (ow_take(&r, ',') || ow_take(&r, ':'));
        if (!ow_take(&r, '}')) return "a sequence is not closed";
        if ((failed = ow_read_number(&r, &out->window))) return failed;
    } else if (ow_peek(&r, 0) != '@') {
        if ((failed = ow_read_step(&r, &out->steps[0]))) return failed;
        out->step_count = 1;
    }
    if (!ow_take(&r, '@')) return "@ is missing";
    if ((failed = ow_read_number(&r, &out->open))) return failed;
    if (!ow_take(&r, '.') || !ow_take(&r, '.')) return ".. is missing";
    if ((failed = ow_read_number(&r, &out->close))) return failed;
    if (!ow_take(&r, '>')) return "> is missing";
    if ((failed = ow_read_number(&r, &out->start))) return failed;
    if (r.at != r.end) return "text follows the start frame";
    return NULL;
}

typedef struct {
    char *out;
    uint32_t room, length;
} OwWriter;

static void ow_put(OwWriter *w, const char *text) {
    for (; *text; text++, w->length++)
        if (w->length < w->room) w->out[w->length] = *text;
}

static void ow_put_number(OwWriter *w, uint32_t value) {
    char digits[6], *at = digits + sizeof digits - 1;
    *at = 0;
    do *--at = (char)('0' + value % 10);
    while (value /= 10);
    ow_put(w, at);
}

static void ow_put_names(OwWriter *w, uint16_t bits) {
    bool first = true;
    for (int32_t i = 0; ow_direction_names[i]; i++) {
        if (!(bits & (1 << i))) continue;
        if (!first) ow_put(w, "/");
        ow_put(w, ow_direction_names[i]);
        first = false;
    }
}

// The shortest of: a plain list, a group, a group and the rest, all but a group.
static void ow_put_directions(OwWriter *w, uint16_t bits, bool tap) {
    char best[64], candidate[64];
    OwWriter shortest = {best, sizeof best, 0};
    ow_put_names(&shortest, bits);
    for (int32_t g = 0; g < 5; g++) {
        uint16_t group = ow_direction_groups[g].bits, rest = bits & ~group;
        OwWriter option = {candidate, sizeof candidate, 0};
        if (bits == group && (group != OW_DIR_ALL || tap)) ow_put(&option, ow_direction_groups[g].name);
        else if (group != OW_DIR_ALL && (bits & group) == group) {
            ow_put(&option, ow_direction_groups[g].name);
            ow_put(&option, "/");
            ow_put_names(&option, rest);
        } else if (group != OW_DIR_ALL && bits == (OW_DIR_ALL & ~group)) {
            ow_put(&option, "!");
            ow_put(&option, ow_direction_groups[g].name);
        } else continue;
        if (option.length < shortest.length) {
            for (uint32_t i = 0; i < option.length; i++) best[i] = candidate[i];
            shortest.length = option.length;
        }
    }
    best[shortest.length] = 0;
    if (tap) ow_put(w, "^");
    ow_put(w, best);
}

static void ow_put_step(OwWriter *w, const OwInputStep *step, const char *const *names) {
    bool first = true;
    if (step->directions) {
        ow_put_directions(w, step->directions, step->tap);
        first = false;
    }
    if (step->press) {
        ow_put(w, first ? "" : "+");
        bool one = !(step->press & (step->press - 1));
        bool inner = true;
        const char *between = step->press_mode == OW_PRESS_ANY && !one ? "/" : "+";
        if (step->press_mode == OW_PRESS_SAME_FRAME) ow_put(w, "{");
        for (int32_t i = 0; names[i]; i++) {
            if (!(step->press & (1 << i))) continue;
            if (!inner) ow_put(w, between);
            ow_put(w, names[i]);
            inner = false;
        }
        if (step->press_mode == OW_PRESS_SAME_FRAME) ow_put(w, "}1");
        first = false;
    }
    for (int32_t i = 0; names[i]; i++) {
        if (!(step->held & (1 << i))) continue;
        ow_put(w, first ? "" : "+");
        ow_put(w, names[i]);
        ow_put(w, "~");
        first = false;
    }
    for (int32_t i = 0; names[i]; i++) {
        if (!(step->not_held & (1 << i))) continue;
        ow_put(w, first ? "!" : "+!");
        ow_put(w, names[i]);
        first = false;
    }
    if (step->summary) {
        ow_put(w, first ? "" : "+");
        ow_put(w, ow_summary_names[step->summary]);
    }
}

uint32_t ow_input_text(const OwInput *input, const char *const *buttons, char *out, uint32_t room) {
    OwWriter w = {out, room, 0};
    bool sequence = input->step_count > 1 || input->window;
    if (sequence) ow_put(&w, "{");
    for (int32_t i = 0; i < input->step_count; i++) {
        if (i) ow_put(&w, input->steps[i].strict ? ":" : ",");
        ow_put_step(&w, &input->steps[i], buttons);
    }
    if (sequence) {
        ow_put(&w, "}");
        ow_put_number(&w, input->window);
    }
    ow_put(&w, "@");
    ow_put_number(&w, input->open);
    ow_put(&w, "..");
    ow_put_number(&w, input->close);
    ow_put(&w, ">");
    ow_put_number(&w, input->start);
    return w.length < room ? (out[w.length] = 0, w.length) : 0;
}

uint32_t ow_input_notation(const OwInput *input, const char *const *buttons, char *out, uint32_t room) {
    (void)input, (void)buttons, (void)out, (void)room;
    return 0;
}

#endif
#endif
