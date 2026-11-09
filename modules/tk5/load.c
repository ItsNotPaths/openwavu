#include "load.h"

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sim/requirements.h"
#include "sim/state.h"
#include "sim/transition.h"
#include "sqlite3.h"
#define OW_INPUT_IMPLEMENTATION
#include "ow_input.h"

// A column is named after its field: the member path with '_' for '.', without the unit wrappers (.ticks, .degrees, .bits).
// A column that is a declared foreign key holds a row key: the field gets the row's index in its table, or for a
// <table>_list the index of the list's first row in <table>. NULL leaves the field as it is, or writes `none`.
typedef enum : uint8_t {
    KIND_INT,      // the low `size` bytes of the integer
    KIND_FLOAT,
    KIND_COMPARE,  // a move identity (T5Move.compare_id): a number as it is; a text key gets a number above every stock
                   // one, the same in every character, since moves compare the opponent's identity
    KIND_ANIM,     // two columns, anim_owner and anim_idx, stored as the index in the fighter's anim list
    KIND_BITS,     // value << shift, ORed into a 32-bit word: a 0/1 column, or a name sheet's code in a part of the word
    KIND_BYTES,    // a word the game stores big endian, as its `size` bytes in the game's order
} Kind;

typedef struct {
    const char *column;  // an array takes column_0, column_1, ...; KIND_ANIM: none
    size_t offset, size;
    size_t count, stride;  // array elements
    Kind kind;
    int32_t bias;  // added to the value
    int32_t none;  // written for NULL when not 0
    uint8_t shift;  // KIND_BITS
} Field;

#define MEMBER(type, path) (((type *)0)->path)
#define KIND_OF(type, path) _Generic(MEMBER(type, path), float: KIND_FLOAT, default: KIND_INT)
#define AT(type, path) .offset = offsetof(type, path), .size = sizeof MEMBER(type, path), .count = 1
#define FIELD_AS(type, path, name, ...) {name, AT(type, path), .kind = KIND_OF(type, path) __VA_OPT__(, ) __VA_ARGS__}
#define FIELD(type, member, ...) FIELD_AS(type, member, #member __VA_OPT__(, ) __VA_ARGS__)
#define ARRAY_AS(type, array, path, name, ...)                                                                             \
    {name,                                                                                                                 \
     .offset = offsetof(type, array[0] path),                                                                              \
     .size = sizeof MEMBER(type, array[0] path),                                                                           \
     .count = sizeof MEMBER(type, array) / sizeof MEMBER(type, array[0]),                                                  \
     .stride = sizeof MEMBER(type, array[0]),                                                                              \
     .kind = KIND_OF(type, array[0] path) __VA_OPT__(, ) __VA_ARGS__}
#define ARRAY(type, array) ARRAY_AS(type, array, , #array)
#define COMPARE_AS(type, path, name) {name, AT(type, path), .kind = KIND_COMPARE}
#define VALUE(type, name) {name, .size = sizeof(type), .count = 1, .kind = KIND_INT}  // a table of plain integers
#define ANIM(type, member) {NULL, AT(type, member), .kind = KIND_ANIM}
#define BIT(type, member, name, bit) {name, AT(type, member), .kind = KIND_BITS, .shift = bit}
#define ALIAS_AS(type, path, name) FIELD_AS(type, path, name, .bias = T5_ALIAS_BASE)  // a move slot n: 0x8000 + n
// A requirement param or property value: plain, or a row of the table its code names, in that table's column.
#define PARAM(type, member)                                                                                                \
    FIELD(type, member), FIELD_AS(type, member, #member "_move"), ALIAS_AS(type, member, #member "_alias"),                \
        FIELD_AS(type, member, #member "_pushback"), FIELD_AS(type, member, #member "_tracking_row"),                       \
        FIELD_AS(type, member, #member "_move_pool"), COMPARE_AS(type, member, #member "_compare_id")

static const Field move_fields[] = {
    ANIM(T5Move, anim),
    BIT(T5Move, vuln, "state_class", STATE_CLASS_SHIFT),
    BIT(T5Move, vuln, "state_hurt_crouching", 0), BIT(T5Move, vuln, "state_hurt_standing", 1), BIT(T5Move, vuln, "state_hurt_lying", 2),
    BIT(T5Move, vuln, "state_guard_crouch", 3), BIT(T5Move, vuln, "state_guard_stand", 4), BIT(T5Move, vuln, "state_throw_crouching", 5),
    BIT(T5Move, vuln, "state_throw_standing", 6), BIT(T5Move, vuln, "state_throw_lying", 7), BIT(T5Move, vuln, "state_guard_locked", 8),
    BIT(T5Move, vuln, "state_downed", 9), BIT(T5Move, vuln, "state_launched", 10),
    BIT(T5Move, hit_level, "attack_kind", 8),
    BIT(T5Move, hit_level, "attack_hits_crouching", 0), BIT(T5Move, hit_level, "attack_hits_standing", 1), BIT(T5Move, hit_level, "attack_hits_lying", 2),
    BIT(T5Move, hit_level, "attack_blocked_by_crouch_guard", 3), BIT(T5Move, hit_level, "attack_blocked_by_stand_guard", 4),
    FIELD(T5Move, cancels),
    FIELD(T5Move, next_move),
    ALIAS_AS(T5Move, next_move, "next_alias"),
    FIELD(T5Move, end_yaw),
    COMPARE_AS(T5Move, compare_id, "compare_id"),
    FIELD(T5Move, push_speed),
    FIELD(T5Move, hit_conditions),
    FIELD(T5Move, window_start),
    FIELD(T5Move, window_end),
    FIELD(T5Move, hold_frame),
    FIELD(T5Move, voiceclips, .none = -1),
    FIELD(T5Move, extra_props, .none = -1),
    FIELD(T5Move, start_props, .none = -1),
    FIELD(T5Move, end_prop, .none = -1),
    BIT(T5Move, flags, "keeps_hips", 0), BIT(T5Move, flags, "turns_at_end", 1), BIT(T5Move, flags, "looks_at_opponent", 2),
    BIT(T5Move, flags, "follows_floor", 3), BIT(T5Move, flags, "no_blend_in", 4), BIT(T5Move, flags, "no_blend_out", 5),
    BIT(T5Move, flags, "hit_reaction", 6), BIT(T5Move, flags, "guard_by_input", 7), BIT(T5Move, flags, "no_leg_push", 8),
    BIT(T5Move, flags, "sets_hurt_lying", 9), BIT(T5Move, flags, "throw_resync", 10), BIT(T5Move, flags, "starts_on_partner", 11),
    BIT(T5Move, flags, "thrown_stays", 12), BIT(T5Move, flags, "keeps_root_yaw", 13), BIT(T5Move, flags, "no_ko_cut", 15),
    BIT(T5Move, flags, "holds_face_expression", 16), BIT(T5Move, flags, "no_start_shift", 17), BIT(T5Move, flags, "no_sword_trail", 18),
    BIT(T5Move, flags, "forces_sword_trail", 19), BIT(T5Move, flags, "grounded_reaction", 21), BIT(T5Move, flags, "keeps_took_damage", 23),
    BIT(T5Move, flags, "string_move", 24), BIT(T5Move, flags, "practice_dummy_recovery", 26), BIT(T5Move, flags, "reaction_continues", 28),
    BIT(T5Move, flags, "blends_in_active", 30),
    {"hit_category", AT(T5Move, hitbox), .kind = KIND_BYTES},
    FIELD(T5Move, first_active),
    FIELD(T5Move, last_active),
    FIELD(T5Move, push_shape),
    FIELD_AS(T5Move, tracking.row, "tracking_row"),
    FIELD_AS(T5Move, tracking.far_row, "tracking_far_row"),
    FIELD_AS(T5Move, tracking.far_source, "tracking_far_source"),
    FIELD_AS(T5Move, tracking.far_angle, "tracking_far_angle"),
    FIELD(T5Move, rides_partner),
    ARRAY_AS(T5Move, hit_pair, .end.kind, "hit_pair_end_kind"),
    ARRAY_AS(T5Move, hit_pair, .end.index, "hit_pair_end_index"),
    ARRAY_AS(T5Move, hit_pair, .start.kind, "hit_pair_start_kind"),
    ARRAY_AS(T5Move, hit_pair, .start.index, "hit_pair_start_index"),
    FIELD_AS(T5Move, hits.attack_bones, "hits_attack_bones"),
    FIELD_AS(T5Move, hits.slots, "hits_slots"),
    FIELD_AS(T5Move, hits.launches, "hits_launches"),
};

// The command and its timing come from `input`, the extradata from the transition columns (load_inputs).
// Not final: the stock CPU's inputs (schema move_ai), until the CPU AI is rewritten.
static const Field move_ai_fields[] = {
    BIT(T5Move, vuln, "ai_any_range", 16), BIT(T5Move, vuln, "ai_not_an_attack", 17), BIT(T5Move, vuln, "ai_attack_move", 19),
    BIT(T5Move, vuln, "ai_treat_as_unblockable", 21), BIT(T5Move, vuln, "ai_evading", 22), BIT(T5Move, vuln, "ai_never_picks", 23),
    BIT(T5Move, hit_level, "ai_low_attack", 16), BIT(T5Move, hit_level, "ai_reach_short", 18), BIT(T5Move, hit_level, "ai_reach_medium", 19),
    BIT(T5Move, hit_level, "ai_reach_long", 20), BIT(T5Move, hit_level, "ai_strike_option", 21), BIT(T5Move, hit_level, "ai_throw", 22),
    BIT(T5Move, flags, "ai_follow_up_input", 27),
};

static const Field cancel_fields[] = {
    FIELD(T5Cancel, requirements),
    FIELD(T5Cancel, move),
    ALIAS_AS(T5Cancel, move, "alias"),
    FIELD_AS(T5Cancel, move, "group_list"),  // a group entry: the group cancel list it enters
    FIELD_AS(T5Cancel, tracking_pick, "tracking_override", .bias = 1),  // tracking_pick counts from 1
};

static const Field requirement_fields[] = {FIELD(T5Requirement, id), PARAM(T5Requirement, param)};

static const Field move_pool_fields[] = {{"compare_id", .size = sizeof(uint16_t), .count = 1, .kind = KIND_COMPARE}};

static const Field pushback_fields[] = {
    FIELD(T5Pushback, frames),
    FIELD(T5Pushback, distance),
    FIELD(T5Pushback, curve_frames),
    FIELD(T5Pushback, curve),
};

static const Field pushback_curve_fields[] = {VALUE(uint16_t, "value")};
static const Field voiceclip_fields[] = {VALUE(uint16_t, "value")};

static const Field property_fields[] = {FIELD(T5Property, when), FIELD(T5Property, id), PARAM(T5Property, value)};

static const Field conditional_property_fields[] = {
    FIELD(T5ConditionalProperty, requirements),
    FIELD(T5ConditionalProperty, id),
    PARAM(T5ConditionalProperty, value),
};

static const Field hit_condition_fields[] = {
    FIELD(T5HitCondition, requirements),
    FIELD(T5HitCondition, damage),
    FIELD(T5HitCondition, reaction),
};

static const Field side_band_fields[] = {
    FIELD(T5SideBand, offset),
    FIELD(T5SideBand, width_0),
    FIELD(T5SideBand, width_1),
    FIELD(T5SideBand, width_2),
};

static const Field reaction_fields[] = {
    ARRAY_AS(T5Reaction, pushback, .index, "pushback"),
    ARRAY(T5Reaction, angle),
    ARRAY(T5Reaction, yaw),
    ARRAY(T5Reaction, move),
    ARRAY_AS(T5Reaction, move, , "alias", .bias = T5_ALIAS_BASE),
};

static const Field tracking_row_fields[] = {
    FIELD(T5FacingRow, law),
    FIELD(T5FacingRow, start),
    FIELD(T5FacingRow, target),
    FIELD(T5FacingRow, stock_mode),
    FIELD_AS(T5FacingRow, gate.until.ticks, "gate_until"),
    FIELD_AS(T5FacingRow, gate.min_distance, "gate_min_distance"),
    FIELD_AS(T5FacingRow, gate.kind, "gate_kind"),
    FIELD_AS(T5FacingRow, rate.normal.degrees, "rate_normal"),
    FIELD_AS(T5FacingRow, rate.late.degrees, "rate_late"),
    FIELD_AS(T5FacingRow, rate.air.degrees, "rate_air"),
    FIELD_AS(T5FacingRow, rate.late_from.ticks, "rate_late_from"),
    FIELD_AS(T5FacingRow, rate.frames.ticks, "rate_frames"),
    FIELD_AS(T5FacingRow, rate.halving, "rate_halving"),
    FIELD_AS(T5FacingRow, rate.frames_by_distance, "rate_frames_by_distance"),
    FIELD_AS(T5FacingRow, limit.total.degrees, "limit_total"),
    ARRAY_AS(T5FacingRow, limit.sweep, .degrees, "limit_sweep"),
    FIELD_AS(T5FacingRow, end.grace.ticks, "end_grace"),
    FIELD_AS(T5FacingRow, end.move_yaw_when, "end_move_yaw_when"),
    FIELD_AS(T5FacingRow, end.pivot_when, "end_pivot_when"),
    FIELD_AS(T5FacingRow, end.phase, "end_phase"),
};

static const Field move_tracking_fields[] = {
    FIELD(T5MoveTracking, row),
    FIELD(T5MoveTracking, far_row),
    FIELD(T5MoveTracking, far_source),
    FIELD(T5MoveTracking, far_angle),
};

static const Field body_fields[] = {
    ARRAY_AS(T5Body, hurt, .radius, "hurt_radius"),
    ARRAY_AS(T5Body, hurt, .bone, "hurt_bone"),
    ARRAY_AS(T5Body, hurt, .lift, "hurt_lift"),
    ARRAY_AS(T5Body, push, .radius, "push_radius"),
    ARRAY_AS(T5Body, push, .bone, "push_bone"),
    FIELD(T5Body, throw_range_cut),
    FIELD_AS(T5Body, head_probe.x, "head_probe_x"),
    FIELD_AS(T5Body, head_probe.z, "head_probe_z"),
    FIELD_AS(T5Body, head_probe.radius, "head_probe_radius"),
    FIELD(T5Body, head_top),
};

static const Field body_points_fields[] = {
    FIELD(T5BodyPoints, count),
    ARRAY_AS(T5BodyPoints, point, .bone, "point_bone"),
    ARRAY_AS(T5BodyPoints, point, .offset.x, "point_offset_x"),
    ARRAY_AS(T5BodyPoints, point, .offset.y, "point_offset_y"),
    ARRAY_AS(T5BodyPoints, point, .offset.z, "point_offset_z"),
    FIELD(T5BodyPoints, hitscan),
    FIELD(T5BodyPoints, projectile),
};

static const Field gaze_fields[] = {
    FIELD(T5Gaze, tilt),
    FIELD_AS(T5Gaze, head_turn.bits, "head_turn"),
};

typedef enum : uint8_t {
    ROWS_KEYED,  // by key, in sheet order (rowid): the game's rows, then a mod's
    ROWS_LISTS,  // the lists of <table>_list in sheet order, each list's rows by pos
    ROWS_SLOTS,  // slot 0..n-1
    ROWS_ONE,    // the one row of the character
} Rows;

typedef struct {
    const char *name;
    Rows rows;
    size_t size;
    size_t items, count;  // in T5Motbin
    const Field *fields;
    size_t field_count;
    const void *end;  // ROWS_LISTS: the row that ends each list (the db leaves it out); NULL: none
} Table;

static const T5Requirement REQUIREMENT_END = {.id = T5_REQUIREMENT_COUNT};
static const T5Property PROPERTY_END;
static const T5ConditionalProperty CONDITIONAL_PROPERTY_END;
static const uint16_t POOL_END;
static const uint16_t VOICECLIP_END = T5_VOICECLIP_END;

#define TABLE(name, rows, type, items, count, fields, end) \
    {name, rows, sizeof(type), offsetof(T5Motbin, items), offsetof(T5Motbin, count), fields, sizeof fields / sizeof fields[0], end}

static const Table tables[] = {  // moves first: the first thing taken from the arena is `moves`
    TABLE("move", ROWS_KEYED, T5Move, moves, move_count, move_fields, NULL),
    TABLE("cancel", ROWS_LISTS, T5Cancel, cancels, cancel_count, cancel_fields, NULL),
    TABLE("group_cancel", ROWS_LISTS, T5Cancel, group_cancels, group_cancel_count, cancel_fields, NULL),
    TABLE("requirement", ROWS_LISTS, T5Requirement, requirements, requirement_count, requirement_fields, &REQUIREMENT_END),
    TABLE("move_pool", ROWS_LISTS, uint16_t, id_pool, id_pool_count, move_pool_fields, &POOL_END),
    TABLE("pushback", ROWS_KEYED, T5Pushback, pushbacks, pushback_count, pushback_fields, NULL),
    TABLE("pushback_curve", ROWS_LISTS, uint16_t, pushback_curves, pushback_curve_count, pushback_curve_fields, NULL),
    TABLE("extra_prop", ROWS_LISTS, T5Property, properties, property_count, property_fields, &PROPERTY_END),
    TABLE("start_prop", ROWS_LISTS, T5ConditionalProperty, start_properties, start_property_count, conditional_property_fields,
          &CONDITIONAL_PROPERTY_END),
    TABLE("end_prop", ROWS_LISTS, T5ConditionalProperty, end_properties, end_property_count, conditional_property_fields,
          &CONDITIONAL_PROPERTY_END),
    TABLE("voiceclip", ROWS_LISTS, uint16_t, voiceclips, voiceclip_count, voiceclip_fields, &VOICECLIP_END),
    TABLE("hit_condition", ROWS_LISTS, T5HitCondition, hit_conditions, hit_condition_count, hit_condition_fields, NULL),
    TABLE("side_band", ROWS_SLOTS, T5SideBand, side_bands, side_band_count, side_band_fields, NULL),
    TABLE("reaction", ROWS_KEYED, T5Reaction, reactions, reaction_count, reaction_fields, NULL),
    TABLE("tracking_row", ROWS_KEYED, T5FacingRow, tracking, tracking_count, tracking_row_fields, NULL),
    TABLE("tracking_override", ROWS_KEYED, T5MoveTracking, tracking_overrides, tracking_override_count, move_tracking_fields, NULL),
    TABLE("tracking_fixed", ROWS_SLOTS, T5MoveTracking, fixed_tracking, fixed_tracking_count, move_tracking_fields, NULL),
    TABLE("body", ROWS_ONE, T5Body, body, body_count, body_fields, NULL),
    TABLE("body_points", ROWS_ONE, T5BodyPoints, body_points, body_point_count, body_points_fields, NULL),
    TABLE("gaze", ROWS_ONE, T5Gaze, gaze, gaze_count, gaze_fields, NULL),
};
#define TABLE_COUNT (sizeof tables / sizeof tables[0])

static char error[512];

// The arguments may be an earlier message in `error`.
static const char *fail(const char *format, ...) {
    char message[sizeof error];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, sizeof message, format, arguments);
    va_end(arguments);
    memcpy(error, message, sizeof error);
    return error;
}

static const char *prepare(sqlite3 *db, const char *sql, const char *character, sqlite3_stmt **statement) {
    if (sqlite3_prepare_v2(db, sql, -1, statement, NULL) != SQLITE_OK) return fail("%s: %s", sql, sqlite3_errmsg(db));
    sqlite3_bind_text(*statement, 1, character, -1, SQLITE_STATIC);
    return NULL;
}

// The first value of a one-row query.
static const char *query_int(sqlite3 *db, const char *sql, const char *character, int64_t *value) {
    sqlite3_stmt *row;
    *value = 0;
    const char *failed = prepare(db, sql, character, &row);
    if (failed) return failed;
    sqlite3_step(row);
    *value = sqlite3_column_int64(row, 0);
    sqlite3_finalize(row);
    return NULL;
}

// The select that lays a table out as the arena holds it: its fields after SELECT_FIRST columns. A list table gives its
// lists in sheet order, each list's rows by pos and then, when the table has one, an end row of NULLs.
enum { SELECT_FIRST = 3 };

static void select_fields(const Table *table, const char *format, char *sql, size_t room, size_t *used) {
    for (size_t index = 0; index < table->field_count; index++) {
        const Field *field = &table->fields[index];
        for (size_t element = 0; element < field->count && *used < room; element++) {
            char column[64];
            if (field->kind == KIND_ANIM) snprintf(column, sizeof column, "anim_owner\", \"anim_idx");
            else snprintf(column, sizeof column, field->count == 1 ? "%s" : "%s_%zu", field->column, element);
            *used += (size_t)snprintf(sql + *used, room - *used, format, column);
        }
    }
}

static void build_select(const Table *table, char *sql, size_t room) {
    size_t used = 0;
    if (table->rows != ROWS_LISTS) {
        used += (size_t)snprintf(sql, room, "SELECT 0, 0, 0");
        select_fields(table, ", \"%s\"", sql, room, &used);
        static const char *const order[] = {[ROWS_KEYED] = " ORDER BY rowid", [ROWS_SLOTS] = " ORDER BY slot", [ROWS_ONE] = ""};
        snprintf(sql + used, room - used, " FROM %s WHERE character = ?1%s", table->name, order[table->rows]);
        return;
    }
    used += (size_t)snprintf(sql, room, "SELECT l.rowid, 0, pos");
    select_fields(table, ", \"%s\"", sql, room, &used);
    used += (size_t)snprintf(sql + used, room - used, " FROM %s_list l JOIN %s ON list = l.key WHERE l.character = ?1", table->name, table->name);
    if (table->end) {
        used += (size_t)snprintf(sql + used, room - used, " UNION ALL SELECT rowid, 1, 0");
        select_fields(table, ", NULL", sql, room, &used);
        used += (size_t)snprintf(sql + used, room - used, " FROM %s_list WHERE character = ?1", table->name);
    }
    if (used < room) snprintf(sql + used, room - used, " ORDER BY 1, 2, 3");
}

static const char *count_rows(sqlite3 *db, const char *character, const Table *table, int32_t *count) {
    char select[4096], sql[sizeof select + 64];
    build_select(table, select, sizeof select);
    snprintf(sql, sizeof sql, "SELECT count(*) FROM (%s)", select);
    int64_t rows;
    const char *failed = query_int(db, sql, character, &rows);
    *count = (int32_t)rows;
    if (failed || table->rows != ROWS_SLOTS) return failed;
    snprintf(sql, sizeof sql, "SELECT coalesce(max(slot) + 1, 0) FROM %s WHERE character = ?1", table->name);
    int64_t span;
    failed = query_int(db, sql, character, &span);
    if (!failed && span != rows) return fail("%s %s: slots run to %lld over %d rows", table->name, character, (long long)span - 1, *count);
    return failed;
}

// Every table ends with one zero record: a scan that runs one entry past the list reads zeros.
static size_t table_bytes(int32_t count, size_t size) { return t5_arena_round(((size_t)count + 1) * size); }

// --- cancel inputs (docs/commands.md)

static const char *const BUTTON_NAMES[] = {"1", "2", "3", "4", NULL};
static const char *const WORD_NAMES[] = {"unlock", NULL};  // bit i: EXTRA_WORDS[i] of extradata
static const uint32_t EXTRA_WORDS[] = {1 << 18};
static const OwInputNames NAMES = {BUTTON_NAMES, WORD_NAMES};

// The codes after T5_CANCEL_END: dashes and taps, as the sequences they match.
static const char *const SPECIAL_INPUTS[] = {"{^f:n:^f}20@0..0>0", "{^b:n:^b}20@0..0>0", "{n:u:n}16@0..0>0", "{n:d:n}16@0..0>0"};

// The sequences the cancels read, numbered by cancel. NULL tables: only counted.
typedef struct {
    T5InputSequence *sequences;
    uint16_t *joints;
    T5Command *extras;
    int32_t sequence_count, extra_count;
} Sequences;

// Inside a sequence a step without buttons is "no press".
static T5Command step_command(const OwInputStep *step, bool in_sequence) {
    T5Command command = {(uint16_t)(step->directions << 1 | (step->tap ? T5_DIRECTION_NEW_PRESS : 0)), 0};
    bool no_buttons = !step->press && !step->held && !step->not_held;
    if (step->summary || (in_sequence && no_buttons)) {
        static const uint16_t summaries[] = {[OW_SUMMARY_NONE] = 0, [OW_SUMMARY_NO_PRESS] = 0, [OW_SUMMARY_NOTHING_HELD] = 1,
                                             [OW_SUMMARY_SOME_PRESS] = 2, [OW_SUMMARY_SOME_HELD] = 3};
        command.buttons = T5_COMMAND_SUMMARY + summaries[step->summary];
        return command;
    }
    static const uint16_t modes[] = {[OW_PRESS_TOGETHER] = T5_COMMAND_HOLD_AFTER_PRESS, [OW_PRESS_SAME_FRAME] = 0,
                                     [OW_PRESS_ANY] = T5_COMMAND_ANY_PRESS};
    command.buttons = (uint16_t)(step->press | step->held << 4 | step->not_held << 8 | (step->press ? modes[step->press_mode] : 0));
    return command;
}

static uint16_t special_code(OwInput input) {
    char text[256];
    input.open = input.close = input.start = input.words = 0;
    ow_input_text(&input, &NAMES, text, sizeof text);
    for (uint16_t index = 0; index < sizeof SPECIAL_INPUTS / sizeof *SPECIAL_INPUTS; index++)
        if (strcmp(text, SPECIAL_INPUTS[index]) == 0) return T5_CANCEL_DASH_F + index;
    return 0;
}

static const char *cancel_input(const char *table, const char *kind, const char *text, T5Cancel *cancel, Sequences *sequences) {
    OwInput input;
    const char *failed = ow_input_parse(text, (uint32_t)strlen(text), &NAMES, &input);
    if (failed) return fail("%s.input %s: %s", table, text, failed);
    cancel->window_start = input.open, cancel->window_end = input.close, cancel->start_frame = input.start;
    for (size_t word = 0; word < sizeof EXTRA_WORDS / sizeof *EXTRA_WORDS; word++)
        if (input.words >> word & 1) cancel->extradata |= EXTRA_WORDS[word];
    if (kind) {
        if (input.step_count) return fail("%s.input %s: a %s row takes timing only", table, text, kind);
        cancel->command.code = strcmp(kind, "end") == 0 ? T5_CANCEL_END : strcmp(kind, "group") == 0 ? T5_CANCEL_GROUP : T5_CANCEL_GROUP_END;
        return NULL;
    }
    if (input.step_count <= 1 && !input.window) {
        if (input.step_count) cancel->command = step_command(&input.steps[0], false);
        return NULL;
    }
    if ((cancel->command.code = special_code(input))) return NULL;
    if (sequences->sequence_count > UINT16_MAX - T5_CANCEL_SEQUENCE) return fail("%s: too many input sequences", table);
    cancel->command.code = (uint16_t)(T5_CANCEL_SEQUENCE + sequences->sequence_count);
    if (sequences->sequences) {
        sequences->sequences[sequences->sequence_count] = (T5InputSequence){input.window, input.step_count, (uint32_t)sequences->extra_count};
        for (int32_t step = 0; step < input.step_count; step++) {
            sequences->extras[sequences->extra_count + step] = step_command(&input.steps[step], true);
            sequences->joints[sequences->sequence_count] |= (uint16_t)(input.steps[step].strict << step);
        }
    }
    sequences->sequence_count++;
    sequences->extra_count += input.step_count;
    return NULL;
}

// The transition word from its three name columns, then the flags; columns 2.. of the input select.
static const char *const TRANSITION_COLUMNS[] = {"transition", "start_align", "motion"};
static const uint32_t EXTRA_FLAGS[] = {EXTRADATA_TURN, EXTRADATA_NO_BLEND_OUT, EXTRADATA_NO_ROOT_FIX, EXTRADATA_ROOT_HIPS};
enum { NAMES_FIRST = 2, FLAGS_FIRST = NAMES_FIRST + 3, NAME_TEXT_FIRST = FLAGS_FIRST + 4 };

static const char *cancel_extradata(const char *table, sqlite3_stmt *row, uint32_t *extradata) {
    for (int name = 0; name < 3; name++)
        if (sqlite3_column_type(row, NAMES_FIRST + name) == SQLITE_NULL)
            return fail("%s.%s: no row %s", table, TRANSITION_COLUMNS[name], (const char *)sqlite3_column_text(row, NAME_TEXT_FIRST + name));
    *extradata = t5_transition(sqlite3_column_int(row, NAMES_FIRST), sqlite3_column_int(row, NAMES_FIRST + 1), sqlite3_column_int(row, NAMES_FIRST + 2));
    for (int flag = 0; flag < 4; flag++)
        if (sqlite3_column_int(row, FLAGS_FIRST + flag)) *extradata |= EXTRA_FLAGS[flag];
    return NULL;
}

// Rows in the order load_table lays them out. No motbin: only counts the sequences.
static const char *read_inputs(sqlite3 *db, const char *character, T5Motbin *motbin, Sequences *sequences) {
    static const char *const names[] = {"cancel", "group_cancel"};
    const char *failed = NULL;
    for (int table = 0; table < 2 && !failed; table++) {
        char sql[1024];
        snprintf(sql, sizeof sql,
                 "SELECT kind, input, t.code, a.code, m.code, turn, no_blend_out, no_root_fix, root_hips, c.transition, c.start_align, "
                 "c.motion FROM %s_list l JOIN %s c ON c.list = l.key LEFT JOIN transition t ON t.name = c.transition "
                 "LEFT JOIN start_align a ON a.name = c.start_align LEFT JOIN motion m ON m.name = c.motion "
                 "WHERE l.character = ?1 ORDER BY l.rowid, pos",
                 names[table], names[table]);
        sqlite3_stmt *rows;
        if ((failed = prepare(db, sql, character, &rows))) break;
        T5Cancel *cancels = !motbin ? NULL : table ? motbin->group_cancels : motbin->cancels;
        for (int32_t row = 0; !failed && sqlite3_step(rows) == SQLITE_ROW; row++) {
            T5Cancel unused = {0}, *cancel = cancels ? &cancels[row] : &unused;
            failed = cancel_extradata(names[table], rows, &cancel->extradata);
            if (!failed)
                failed = cancel_input(names[table], (const char *)sqlite3_column_text(rows, 0), (const char *)sqlite3_column_text(rows, 1),
                                      cancel, sequences);
        }
        sqlite3_finalize(rows);
    }
    return failed;
}

static void sequence_bytes(const Sequences *counted, size_t *sequences, size_t *joints, size_t *extras) {
    *sequences = table_bytes(counted->sequence_count, sizeof(T5InputSequence));
    *joints = table_bytes(counted->sequence_count, sizeof(uint16_t));
    *extras = table_bytes(counted->extra_count, sizeof(T5Command));
}

static constexpr enum T5TransitionClass TRANSITION_CLASS_PASS = 9;  // an entry of this class does not end the cancel scan

// T5Cancel.option as the game's loader computes it (0xc8508): from the requirement ids, the command and the transition.
static uint16_t cancel_option(const T5Motbin *motbin, const T5Cancel *cancel) {
    uint16_t option = cancel->command.code || cancel->command.buttons ? T5_OPTION_INPUT : T5_OPTION_NO_INPUT;
    for (const T5Requirement *r = &motbin->requirements[cancel->requirements]; r->id != T5_REQUIREMENT_COUNT; r++) {
        if (r->id > 0x122 && r->id < 0x8000) option |= T5_OPTION_REVERSAL;
        if (r->id > 0x134 && r->id < 0x8000) option |= T5_OPTION_NO_DAMAGE;
        if (r->id == 0x8162) option |= T5_OPTION_TRACK;
        if (r->id >= 0x6a && r->id <= 0x6c) option |= T5_OPTION_INPUT;
    }
    uint16_t transition = t5_extradata_transition(cancel->extradata);
    if (t5_transition_class(transition) != TRANSITION_CLASS_PASS) option |= T5_OPTION_STOP;
    if (t5_transition_code(transition) == MOTION_SWEEP) option |= T5_OPTION_LOCK_SKIP;
    return option;
}

static void set_options(T5Motbin *motbin) {
    for (int32_t index = 0; index < motbin->cancel_count; index++) motbin->cancels[index].option = cancel_option(motbin, &motbin->cancels[index]);
    for (int32_t index = 0; index < motbin->group_cancel_count; index++)
        motbin->group_cancels[index].option = cancel_option(motbin, &motbin->group_cancels[index]);
}

static const char *load_inputs(sqlite3 *db, const char *character, T5Arena *arena, T5Motbin *motbin) {
    Sequences counted = {0};
    const char *failed = read_inputs(db, character, NULL, &counted);
    if (failed) return failed;
    size_t sequences_size, joints_size, extras_size;
    sequence_bytes(&counted, &sequences_size, &joints_size, &extras_size);
    Sequences sequences = {t5_arena_take(arena, sequences_size), t5_arena_take(arena, joints_size), t5_arena_take(arena, extras_size), 0, 0};
    if (!sequences.sequences || !sequences.joints || !sequences.extras) return fail("input sequences: arena full");
    memset(sequences.sequences, 0, sequences_size);
    memset(sequences.joints, 0, joints_size);
    memset(sequences.extras, 0, extras_size);
    failed = read_inputs(db, character, motbin, &sequences);
    motbin->input_sequences = sequences.sequences, motbin->input_sequence_count = sequences.sequence_count;
    motbin->input_joints = sequences.joints;
    motbin->input_extras = sequences.extras, motbin->input_extra_count = sequences.extra_count;
    return failed;
}

const char *t5_load_motbin_storage(sqlite3 *db, const char *character, size_t *bytes) {
    *bytes = 0;
    for (size_t index = 0; index < TABLE_COUNT; index++) {
        int32_t count;
        const char *failed = count_rows(db, character, &tables[index], &count);
        if (failed) return failed;
        *bytes += table_bytes(count, tables[index].size);
    }
    Sequences counted = {0};
    const char *failed = read_inputs(db, character, NULL, &counted);
    size_t sequences_size, joints_size, extras_size;
    sequence_bytes(&counted, &sequences_size, &joints_size, &extras_size);
    *bytes += sequences_size + joints_size + extras_size;
    return failed;
}

// Keys and the index each stands for, sorted by key (SQLite's text order is strcmp's).
typedef struct {
    struct Key {
        char *key;
        int32_t index;
    } *keys;
    int32_t count;
    bool foreign;  // the keys of a foreign key's table
} Keys;

// sql gives each key and its index, in key order; ?1 is `text`, ?2 `number`.
static const char *read_keys(sqlite3 *db, const char *sql, const char *text, int32_t number, Keys *keys) {
    sqlite3_stmt *rows;
    const char *failed = prepare(db, sql, text, &rows);
    if (failed) return failed;
    sqlite3_bind_int(rows, 2, number);
    for (int32_t room = 0; !failed && sqlite3_step(rows) == SQLITE_ROW;) {
        if (keys->count == room) {
            room = room ? 2 * room : 256;
            struct Key *grown = realloc(keys->keys, (size_t)room * sizeof *grown);
            if (!grown) {
                failed = fail("out of memory");
                break;
            }
            keys->keys = grown;
        }
        char *key = strdup((const char *)sqlite3_column_text(rows, 0));
        if (!key) failed = fail("out of memory");
        else keys->keys[keys->count++] = (struct Key){key, sqlite3_column_int(rows, 1)};
    }
    sqlite3_finalize(rows);
    return failed;
}

static void free_keys(Keys *keys) {
    for (int32_t index = 0; index < keys->count; index++) free(keys->keys[index].key);
    free(keys->keys);
}

static bool find_key(const Keys *keys, const char *key, int64_t *index) {
    int32_t low = 0, high = keys->count;
    while (low < high) {
        int32_t middle = (low + high) / 2;
        if (strcmp(keys->keys[middle].key, key) < 0) low = middle + 1;
        else high = middle;
    }
    if (low == keys->count || strcmp(keys->keys[low].key, key) != 0) return false;
    *index = keys->keys[low].index;
    return true;
}

// The table whose lists `target` (<table>_list) names, or NULL.
static const Table *list_table(const char *target) {
    for (size_t index = 0; index < TABLE_COUNT; index++) {
        size_t length = strlen(tables[index].name);
        if (tables[index].rows == ROWS_LISTS && strncmp(target, tables[index].name, length) == 0 && strcmp(target + length, "_list") == 0)
            return &tables[index];
    }
    return NULL;
}

// The keys of the table a column's foreign key names: a row's index in sheet order, for a <table>_list the index of the
// list's first row in <table> (lists take their rows and their end row), for a name sheet (name, code) the code. No keys
// when it is not a foreign key.
static const char *read_target_keys(sqlite3 *db, const char *character, const char *table, const char *column, Keys *keys) {
    sqlite3_stmt *row;
    const char *failed = prepare(db, "SELECT \"table\" FROM pragma_foreign_key_list(?1) WHERE \"from\" = ?2", table, &row);
    if (failed) return failed;
    sqlite3_bind_text(row, 2, column, -1, SQLITE_STATIC);
    char target[64] = "", sql[512];
    if (sqlite3_step(row) == SQLITE_ROW) snprintf(target, sizeof target, "%s", (const char *)sqlite3_column_text(row, 0));
    sqlite3_finalize(row);
    if (!target[0]) return NULL;
    keys->foreign = true;
    int64_t name_sheet;
    failed = query_int(db, "SELECT (SELECT group_concat(name) FROM pragma_table_info(?1)) = 'name,code'", target, &name_sheet);
    if (failed) return failed;
    const Table *lists = list_table(target);
    if (name_sheet) snprintf(sql, sizeof sql, "SELECT name, code FROM %s ORDER BY name", target);
    else if (lists)
        snprintf(sql, sizeof sql,
                 "SELECT key, sum(size) OVER (ORDER BY rowid) - size FROM (SELECT rowid, key, "
                 "(SELECT count(*) FROM %s WHERE list = l.key) + ?2 AS size FROM %s l WHERE character = ?1) ORDER BY key",
                 lists->name, target);
    else snprintf(sql, sizeof sql, "SELECT key, row_number() OVER (ORDER BY rowid) - 1 FROM %s WHERE character = ?1 ORDER BY key", target);
    return read_keys(db, sql, character, lists && lists->end, keys);
}

// The text compare ids of every character's moves, numbered after the highest stock one.
static const char *read_compare_ids(sqlite3 *db, Keys *keys) {
    enum { NO_MOVE_ID = 65535 };
    int64_t first;
    const char *failed =
        query_int(db, "SELECT coalesce(max(compare_id), 0) + 1 FROM move WHERE typeof(compare_id) = 'integer'", NULL, &first);
    if (!failed)
        failed = read_keys(db,
                           "SELECT compare_id, ?2 + row_number() OVER (ORDER BY compare_id) - 1 FROM "
                           "(SELECT DISTINCT compare_id FROM move WHERE typeof(compare_id) = 'text') ORDER BY compare_id",
                           NULL, (int32_t)first, keys);
    if (!failed && first + keys->count > NO_MOVE_ID) return fail("move: %d text compare ids do not fit above %lld", keys->count, (long long)first - 1);
    return failed;
}

enum { BANK_CHARACTER, BANK_COMMON, BANK_EMBEDDED, BANKS };

static int anim_bank(const char *owner) {
    static const char embedded[] = "/embedded";
    size_t length = strlen(owner);
    if (strcmp(owner, "common") == 0) return BANK_COMMON;
    if (length >= sizeof embedded - 1 && strcmp(owner + length - (sizeof embedded - 1), embedded) == 0) return BANK_EMBEDDED;
    return BANK_CHARACTER;
}

// The owners of the character's banks in fighter order: its own (the bank its moves name that is neither common nor
// embedded), common, embedded. Moves that name two own banks fail.
static const char *bank_owners(sqlite3 *db, const char *character, char owners[BANKS][T5_OWNER_BYTES]) {
    snprintf(owners[BANK_CHARACTER], T5_OWNER_BYTES, "%s", character);
    snprintf(owners[BANK_COMMON], T5_OWNER_BYTES, "common");
    snprintf(owners[BANK_EMBEDDED], T5_OWNER_BYTES, "%s/embedded", character);
    sqlite3_stmt *rows;
    const char *failed = prepare(db, "SELECT DISTINCT anim_owner FROM move WHERE character = ?1", character, &rows);
    bool named = false;
    while (!failed && sqlite3_step(rows) == SQLITE_ROW) {
        const char *owner = (const char *)sqlite3_column_text(rows, 0);
        if (!owner || anim_bank(owner) != BANK_CHARACTER) continue;
        if (named) failed = fail("move %s: anims of two banks, %s and %s", character, owners[BANK_CHARACTER], owner);
        snprintf(owners[BANK_CHARACTER], T5_OWNER_BYTES, "%s", owner);
        named = true;
    }
    sqlite3_finalize(rows);
    return failed;
}

// A bank's numbered ids run 0..numbered-1; its text ids (a mod's anims) follow, in key order.
static const char *bank_count(sqlite3 *db, const char *owner, int32_t *numbered, uint32_t *count) {
    sqlite3_stmt *row;
    const char *failed = prepare(db,
                                 "SELECT coalesce(max(CASE WHEN typeof(idx) = 'integer' THEN idx END) + 1, 0), "
                                 "total(typeof(idx) = 'text') FROM anim WHERE character = ?1",
                                 owner, &row);
    if (failed) return failed;
    sqlite3_step(row);
    *numbered = sqlite3_column_int(row, 0);
    *count = (uint32_t)(*numbered + sqlite3_column_int(row, 1));
    sqlite3_finalize(row);
    return NULL;
}

// The keys every table of a character may name besides its foreign keys.
typedef struct {
    Keys compare_ids;
    Keys anims[BANKS];  // text ids, T5AnimBases order
    T5AnimBases bases;
} Refs;

static const char *read_refs(sqlite3 *db, const char *character, Refs *refs) {
    char owners[BANKS][T5_OWNER_BYTES];
    const char *failed = read_compare_ids(db, &refs->compare_ids);
    if (!failed) failed = bank_owners(db, character, owners);
    for (int bank = 0; bank < BANKS && !failed; bank++) {
        int32_t numbered;
        uint32_t count;
        failed = bank_count(db, owners[bank], &numbered, &count);
        if (!failed)
            failed = read_keys(db,
                               "SELECT idx, ?2 + row_number() OVER (ORDER BY idx) - 1 FROM anim "
                               "WHERE character = ?1 AND typeof(idx) = 'text' ORDER BY idx",
                               owners[bank], numbered, &refs->anims[bank]);
    }
    return failed;
}

static void free_refs(Refs *refs) {
    free_keys(&refs->compare_ids);
    for (int bank = 0; bank < BANKS; bank++) free_keys(&refs->anims[bank]);
}

// The number a cell stands for: a key's index in `target`, a compare id, or the number itself.
static const char *cell_value(sqlite3_stmt *row, int column, const char *table, const Field *field, const Keys *target,
                              const Refs *refs, int64_t *value) {
    const char *text = (const char *)sqlite3_column_text(row, column);
    const char *key = sqlite3_column_type(row, column) == SQLITE_TEXT ? text : NULL;
    *value = sqlite3_column_int64(row, column);
    if (target && !find_key(target, text, value)) return fail("%s.%s: no row %s", table, field->column, text);
    if (!target && key && field->kind != KIND_COMPARE) return fail("%s.%s: text in a number column", table, field->column);
    if (!target && key && !find_key(&refs->compare_ids, key, value)) return fail("%s.%s: no compare_id %s", table, field->column, key);
    *value += field->bias;
    return NULL;
}

// anim_owner and anim_idx: the anim's index in the fighter's anim list.
static const char *anim_value(sqlite3_stmt *row, int column, const char *table, const Refs *refs, int64_t *value) {
    const char *owner = (const char *)sqlite3_column_text(row, column);
    int bank = anim_bank(owner ? owner : "");
    const char *key = sqlite3_column_type(row, column + 1) == SQLITE_TEXT ? (const char *)sqlite3_column_text(row, column + 1) : NULL;
    *value = sqlite3_column_int64(row, column + 1);
    if (key && !find_key(&refs->anims[bank], key, value)) return fail("%s: no anim %s in bank %s", table, key, owner);
    const uint32_t bases[BANKS] = {refs->bases.character, refs->bases.common, refs->bases.embedded};
    *value += bases[bank];
    return NULL;
}

static const char *copy_row(sqlite3_stmt *row, const Table *table, const Keys *targets, const Refs *refs, uint8_t *record) {
    int column = SELECT_FIRST;
    for (size_t index = 0; index < table->field_count; index++) {
        const Field *field = &table->fields[index];
        for (size_t element = 0; element < field->count; element++, column++) {
            uint8_t *at = record + field->offset + element * field->stride;
            bool null = field->kind != KIND_ANIM && sqlite3_column_type(row, column) == SQLITE_NULL;
            if (null && field->none == 0) continue;
            if (field->kind == KIND_FLOAT && !null) {
                float number = (float)sqlite3_column_double(row, column);
                memcpy(at, &number, sizeof number);
                continue;
            }
            int64_t value = field->none;
            const char *failed = NULL;
            if (field->kind == KIND_ANIM) failed = anim_value(row, column++, table->name, refs, &value);
            else if (!null) failed = cell_value(row, column, table->name, field, targets[index].foreign ? &targets[index] : NULL, refs, &value);
            if (failed) return failed;
            if (field->kind == KIND_BITS) {
                uint32_t word;
                memcpy(&word, at, sizeof word);
                word |= (uint32_t)value << field->shift;
                memcpy(at, &word, sizeof word);
            } else if (field->kind == KIND_BYTES) {
                for (size_t byte = 0; byte < field->size; byte++) at[byte] = (uint8_t)(value >> 8 * (field->size - 1 - byte));
            } else memcpy(at, &value, field->size);  // little endian: the low bytes
        }
    }
    return NULL;
}

static const char *load_table(sqlite3 *db, const char *character, const Table *table, const Refs *refs, T5Arena *arena, T5Motbin *motbin) {
    int32_t count;
    const char *failed = count_rows(db, character, table, &count);
    if (failed) return failed;
    uint8_t *items = t5_arena_take(arena, table_bytes(count, table->size));
    if (!items) return fail("%s: arena full", table->name);
    memset(items, 0, table_bytes(count, table->size));
    *(void **)((char *)motbin + table->items) = items;
    *(int32_t *)((char *)motbin + table->count) = count;

    Keys targets[table->field_count];
    memset(targets, 0, sizeof targets);
    for (size_t index = 0; index < table->field_count && !failed; index++) {
        const Field *field = &table->fields[index];
        char column[64];
        snprintf(column, sizeof column, field->count == 1 ? "%s" : "%s_0", field->column ? field->column : "");
        failed = read_target_keys(db, character, table->name, column, &targets[index]);
    }
    char sql[4096];
    build_select(table, sql, sizeof sql);
    sqlite3_stmt *rows = NULL;
    if (!failed) failed = prepare(db, sql, character, &rows);
    for (int32_t row = 0; !failed && row < count && sqlite3_step(rows) == SQLITE_ROW; row++) {
        uint8_t *record = items + (size_t)row * table->size;
        if (sqlite3_column_int(rows, 1)) memcpy(record, table->end, table->size);  // the end row of a list
        else failed = copy_row(rows, table, targets, refs, record);
    }
    sqlite3_finalize(rows);
    for (size_t index = 0; index < table->field_count; index++) free_keys(&targets[index]);
    return failed;
}

static const char *load_aliases(sqlite3 *db, const char *character, T5Motbin *motbin) {
    Keys moves = {0};
    sqlite3_stmt *rows = NULL;
    const char *failed = read_target_keys(db, character, "move_alias", "move", &moves);
    if (!failed) failed = prepare(db, "SELECT slot, move FROM move_alias WHERE character = ?1", character, &rows);
    static const Field alias_move = {.column = "move"};
    while (!failed && sqlite3_step(rows) == SQLITE_ROW) {
        int64_t slot = sqlite3_column_int64(rows, 0), move;
        if (slot < 0 || slot >= T5_ALIAS_COUNT) failed = fail("move_alias %s: slot %lld", character, (long long)slot);
        else if (!(failed = cell_value(rows, 1, "move_alias", &alias_move, &moves, NULL, &move))) motbin->aliases[slot] = (uint32_t)move;
    }
    sqlite3_finalize(rows);
    free_keys(&moves);
    memcpy(motbin->alias_defaults, motbin->aliases, sizeof motbin->aliases);
    return failed;
}

// The move_ai rows OR their bits into the moves they name.
static const char *load_move_ai(sqlite3 *db, const char *character, T5Motbin *motbin) {
    static const Table table = {.name = "move_ai", .fields = move_ai_fields, .field_count = sizeof move_ai_fields / sizeof *move_ai_fields};
    static const Field ai_move = {.column = "move"};
    Keys moves = {0}, targets[sizeof move_ai_fields / sizeof *move_ai_fields] = {0};
    char sql[2048];
    size_t used = (size_t)snprintf(sql, sizeof sql, "SELECT a.move, 0, 0");
    select_fields(&table, ", \"%s\"", sql, sizeof sql, &used);
    snprintf(sql + used, sizeof sql - used, " FROM move_ai a JOIN move m ON m.key = a.move WHERE m.character = ?1");
    sqlite3_stmt *rows = NULL;
    const char *failed = read_target_keys(db, character, "move_ai", "move", &moves);
    if (!failed) failed = prepare(db, sql, character, &rows);
    while (!failed && sqlite3_step(rows) == SQLITE_ROW) {
        int64_t move;
        if (!(failed = cell_value(rows, 0, "move_ai", &ai_move, &moves, NULL, &move)))
            failed = copy_row(rows, &table, targets, NULL, (uint8_t *)&motbin->moves[move]);
    }
    sqlite3_finalize(rows);
    free_keys(&moves);
    return failed;
}

// The body row goes with the body model (Mokujin keeps his own with any move set); every other table with the move set.
static const char *table_owner(const Table *table, const char *character, const char *body) {
    return table->items == offsetof(T5Motbin, body) ? body : character;
}

const char *t5_load_motbin(T5Motbin *motbin, sqlite3 *db, const char *character, const char *body, T5AnimBases anims, T5Arena *arena) {
    memset(motbin, 0, sizeof *motbin);
    Refs refs = {.bases = anims};
    const char *failed = load_aliases(db, character, motbin);
    if (!failed) failed = read_refs(db, character, &refs);
    for (size_t index = 0; index < TABLE_COUNT && !failed; index++)
        failed = load_table(db, table_owner(&tables[index], character, body), &tables[index], &refs, arena, motbin);
    if (!failed) failed = load_move_ai(db, character, motbin);
    if (!failed) failed = load_inputs(db, character, arena, motbin);
    if (!failed) set_options(motbin);
    free_refs(&refs);
    return failed;
}

// Row columns from `first` on, as floats.
static void read_floats(sqlite3_stmt *row, int first, float *out, int count) {
    for (int column = 0; column < count; column++) out[column] = (float)sqlite3_column_double(row, first + column);
}

// The bones of skeleton A or B by slot: parent, translation, and for A the bind turn.
static const char *load_bones(sqlite3 *db, const char *character, const char *sql, int32_t count, int8_t *parent,
                              float (*translation)[3], float (*euler)[3]) {
    sqlite3_stmt *rows;
    const char *failed = prepare(db, sql, character, &rows);
    while (!failed && sqlite3_step(rows) == SQLITE_ROW) {
        int64_t slot = sqlite3_column_int64(rows, 0);
        if (slot < 0 || slot >= count) {
            failed = fail("%s: slot %lld", sql, (long long)slot);
            break;
        }
        parent[slot] = (int8_t)sqlite3_column_int(rows, 1);
        read_floats(rows, 2, translation[slot], 3);
        if (euler) read_floats(rows, 5, euler[slot], 3);
    }
    sqlite3_finalize(rows);
    return failed;
}

const char *t5_load_skeleton(T5Skeleton *skeleton, sqlite3 *db, const char *character) {
    memset(skeleton, 0, sizeof *skeleton);
    sqlite3_stmt *row;
    const char *failed = prepare(db, "SELECT scale FROM skeleton WHERE character = ?1", character, &row);
    if (failed) return failed;
    if (sqlite3_step(row) == SQLITE_ROW) skeleton->scale = (float)sqlite3_column_double(row, 0);
    else failed = fail("skeleton %s: no row", character);
    sqlite3_finalize(row);
    if (!failed)
        failed = load_bones(db, character, "SELECT slot, parent, x, y, z, rx, ry, rz FROM skeleton_a WHERE character = ?1", T5_BONES_A,
                            skeleton->parent_a, skeleton->translation, skeleton->euler);
    if (!failed)
        failed = load_bones(db, character, "SELECT slot, parent, x, y, z FROM skeleton_b WHERE character = ?1", T5_BONES_B,
                            skeleton->parent_b, skeleton->translation_b, NULL);
    return failed;
}

static int parse_anim(void *anim, T5Bytes file) { return t5_anim_parse(anim, file); }

static const T5ClipKind ANIMS = {sizeof(T5Anim), parse_anim, "anims"};

static size_t clips_bytes(uint32_t count, T5ClipKind kind) { return t5_arena_round(((size_t)count + 1) * kind.size); }  // and a zero one

const char *t5_load_clips_storage(sqlite3 *db, const char *owner, T5ClipKind kind, size_t *bytes) {
    int32_t numbered;
    uint32_t count;
    const char *failed = bank_count(db, owner, &numbered, &count);
    *bytes = failed ? 0 : clips_bytes(count, kind);
    return failed;
}

const char *t5_load_clips(void **clips, uint32_t *count, T5ClipKind kind, sqlite3 *db, const char *owner, T5ReadFile read,
                          void *context, T5Arena *arena) {
    int32_t numbered;
    const char *failed = bank_count(db, owner, &numbered, count);
    if (failed) return failed;
    uint8_t *records = t5_arena_take(arena, clips_bytes(*count, kind));
    if (!records) return fail("%s %s: arena full", kind.what, owner);
    memset(records, 0, clips_bytes(*count, kind));
    *clips = records;
    sqlite3_stmt *rows;
    failed = prepare(db,
                     "SELECT position, file, min(position) OVER (PARTITION BY file) FROM ("
                     "SELECT file, CASE WHEN typeof(idx) = 'integer' THEN idx "
                     "ELSE ?2 + row_number() OVER (PARTITION BY typeof(idx) ORDER BY idx) - 1 END AS position "
                     "FROM anim WHERE character = ?1) ORDER BY position",
                     owner, &rows);
    if (!failed) sqlite3_bind_int(rows, 2, numbered);
    while (!failed && sqlite3_step(rows) == SQLITE_ROW) {
        int64_t index = sqlite3_column_int64(rows, 0), first = sqlite3_column_int64(rows, 2);
        const char *file = (const char *)sqlite3_column_text(rows, 1);
        if (index < 0) failed = fail("%s %s: idx %lld", kind.what, owner, (long long)index);
        else if (first < index) memcpy(records + index * kind.size, records + first * kind.size, kind.size);  // one record: the same keys
        else if (kind.parse(records + index * kind.size, read(context, file)) != 0)
            failed = fail("%s %s %lld: bad file %s", kind.what, owner, (long long)index, file);
    }
    sqlite3_finalize(rows);
    return failed;
}

// Arena bytes of the character's three anim banks, and how many anims they hold.
static const char *anims_storage(sqlite3 *db, const char *character, size_t *bytes, uint32_t *anim_count) {
    char owners[BANKS][T5_OWNER_BYTES];
    const char *failed = bank_owners(db, character, owners);
    *bytes = 0;
    *anim_count = 0;
    for (int bank = 0; bank < BANKS && !failed; bank++) {
        int32_t numbered;
        uint32_t count;
        failed = bank_count(db, owners[bank], &numbered, &count);
        *bytes += clips_bytes(count, ANIMS);
        *anim_count += count;
    }
    return failed;
}

const char *t5_load_anims_storage(sqlite3 *db, const char *character, size_t *bytes) {
    uint32_t anim_count;
    return anims_storage(db, character, bytes, &anim_count);
}

const char *t5_load_anim_bank_storage(sqlite3 *db, const char *owner, size_t *bytes) { return t5_load_clips_storage(db, owner, ANIMS, bytes); }

const char *t5_load_anim_bank(T5AnimBank *bank, sqlite3 *db, const char *owner, T5ReadFile read, void *context, T5Arena *arena) {
    return t5_load_clips((void **)&bank->anims, &bank->anim_count, ANIMS, db, owner, read, context, arena);
}

const char *t5_load_anims(T5FighterFiles *files, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena) {
    char owners[3][T5_OWNER_BYTES];
    const char *failed = bank_owners(db, character, owners);
    T5AnimBank *banks[3] = {&files->character, &files->common, &files->embedded};
    for (int bank = 0; bank < 3 && !failed; bank++) failed = t5_load_anim_bank(banks[bank], db, owners[bank], read, context, arena);
    return failed;
}

const char *t5_load_fighter_storage(sqlite3 *db, const char *character, size_t *bytes) {
    size_t anims, motbin;
    uint32_t anim_count;
    const char *failed = anims_storage(db, character, &anims, &anim_count);
    if (!failed) failed = t5_load_motbin_storage(db, character, &motbin);
    *bytes = failed ? 0 : anims + motbin + t5_fighter_finish_storage(anim_count);
    return failed;
}

const char *t5_load_fighter(T5FighterData *data, sqlite3 *db, const char *character, const char *body, T5ReadFile read, void *context,
                            T5Arena *arena) {
    memset(data, 0, sizeof *data);
    T5FighterFiles files = {0};
    const char *failed = t5_load_anims(&files, db, character, read, context, arena);
    if (!failed) failed = t5_load_motbin(&data->moves, db, character, body, t5_anim_bases(&files), arena);
    if (!failed) failed = t5_load_skeleton(&data->skeleton, db, body);
    if (!failed && t5_fighter_finish(data, &files, arena)) failed = fail("fighter %s: a move has no anim, or the arena is full", character);
    return failed;
}

const char *t5_own_anim_bank(sqlite3 *db, const char *character, char owner[T5_OWNER_BYTES]) {
    char owners[BANKS][T5_OWNER_BYTES];
    const char *failed = bank_owners(db, character, owners);
    memcpy(owner, owners[BANK_CHARACTER], T5_OWNER_BYTES);
    return failed;
}

static const char *stage_files(sqlite3 *db, const char *stage, T5ReadFile read, void *context, T5Bytes *collision, T5Bytes *surfaces, bool *infinite) {
    sqlite3_stmt *row;
    const char *failed = prepare(db, "SELECT collision, surfaces, radius FROM stage WHERE id = ?1", stage, &row);
    if (!failed && sqlite3_step(row) != SQLITE_ROW) failed = fail("stage %s: no row", stage);
    if (!failed) {
        *collision = read(context, (const char *)sqlite3_column_text(row, 0));
        *surfaces = read(context, (const char *)sqlite3_column_text(row, 1));
        *infinite = sqlite3_column_double(row, 2) > 0;
        if (!collision->size || !surfaces->size) failed = fail("stage %s: missing file", stage);
    }
    sqlite3_finalize(row);
    return failed;
}

static const char *load_stage(T5Stage *out, sqlite3 *db, const char *stage, T5ReadFile read, void *context, T5Arena *arena, size_t *bytes) {
    T5Bytes collision, surfaces;
    bool infinite = false;
    const char *failed = stage_files(db, stage, read, context, &collision, &surfaces, &infinite);
    if (!failed) failed = t5_stage_parse(out, collision, surfaces, arena, bytes);
    if (!failed) out->infinite = infinite;
    return failed && failed != error ? fail("stage %s: %s", stage, failed) : failed;
}

const char *t5_load_stage_storage(sqlite3 *db, const char *stage, T5ReadFile read, void *context, size_t *bytes) {
    T5Stage unused;
    return load_stage(&unused, db, stage, read, context, NULL, bytes);
}

const char *t5_load_stage(T5Stage *out, sqlite3 *db, const char *stage, T5ReadFile read, void *context, T5Arena *arena) {
    size_t bytes;
    return load_stage(out, db, stage, read, context, arena, &bytes);
}

const char *t5_load_character(sqlite3 *db, const char *character, uint8_t *chara, int16_t *model) {
    sqlite3_stmt *row;
    const char *failed = prepare(db, "SELECT game_index, model FROM character WHERE id = ?1", character, &row);
    if (failed) return failed;
    if (sqlite3_step(row) == SQLITE_ROW) {
        *chara = sqlite3_column_type(row, 0) == SQLITE_NULL ? T5_CHARA_NONE : (uint8_t)sqlite3_column_int(row, 0);
        *model = (int16_t)sqlite3_column_int(row, 1);
    } else {
        failed = fail("no character %s", character);
    }
    sqlite3_finalize(row);
    return failed;
}
