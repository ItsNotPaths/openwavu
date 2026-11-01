#include "load.h"

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sqlite3.h"

// A column is named after its field: the member path with '_' for '.', without the unit wrappers (.ticks, .degrees, .bits).
// NULL leaves the field as it is.
typedef enum : uint8_t {
    KIND_INT,    // the low `size` bytes of the integer
    KIND_FLOAT,
    KIND_LIST,   // a list id of table `list`, stored as the index of the list's first row; -1 stays -1
    KIND_ANIM,   // two columns, anim_owner and anim_idx, stored as the index in the fighter's anim list
} Kind;

typedef struct {
    const char *column;  // an array takes column_0, column_1, ...; KIND_ANIM: none
    size_t offset, size;
    size_t count, stride;  // array elements
    Kind kind;
    const char *list;
} Field;

#define MEMBER(type, path) (((type *)0)->path)
#define KIND_OF(type, path) _Generic(MEMBER(type, path), float: KIND_FLOAT, default: KIND_INT)
#define FIELD_AS(type, path, name) {name, offsetof(type, path), sizeof MEMBER(type, path), 1, 0, KIND_OF(type, path), NULL}
#define FIELD(type, member) FIELD_AS(type, member, #member)
#define LIST_AS(type, path, name, table) {name, offsetof(type, path), sizeof MEMBER(type, path), 1, 0, KIND_LIST, table}
#define LIST(type, member, table) LIST_AS(type, member, #member, table)
#define ARRAY_AS(type, array, path, name)                                                                                   \
    {name, offsetof(type, array[0] path), sizeof MEMBER(type, array[0] path),                                               \
     sizeof MEMBER(type, array) / sizeof MEMBER(type, array[0]), sizeof MEMBER(type, array[0]), KIND_OF(type, array[0] path), NULL}
#define ARRAY(type, array) ARRAY_AS(type, array, , #array)
#define VALUE(type, name) {name, 0, sizeof(type), 1, 0, KIND_INT, NULL}  // a table of plain integers
#define ANIM(type, member) {NULL, offsetof(type, member), sizeof MEMBER(type, member), 1, 0, KIND_ANIM, NULL}

static const Field move_fields[] = {
    ANIM(T5Move, anim),
    FIELD(T5Move, vuln),
    FIELD(T5Move, hit_level),
    LIST(T5Move, cancels, "cancel"),
    FIELD(T5Move, next_move),
    FIELD(T5Move, end_yaw),
    FIELD(T5Move, compare_id),
    FIELD(T5Move, push_speed),
    LIST(T5Move, hit_conditions, "hit_condition"),
    FIELD(T5Move, window_start),
    FIELD(T5Move, window_end),
    FIELD(T5Move, hold_frame),
    LIST(T5Move, extra_props, "extra_prop"),
    LIST(T5Move, start_props, "start_prop"),
    LIST(T5Move, end_prop, "end_prop"),
    FIELD(T5Move, flags),
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

static const Field cancel_fields[] = {
    FIELD_AS(T5Cancel, command.code, "command_code"),
    FIELD_AS(T5Cancel, command.buttons, "command_buttons"),
    LIST(T5Cancel, requirements, "requirement"),
    FIELD(T5Cancel, move),
    LIST_AS(T5Cancel, move, "group_list", "group_cancel"),  // a group entry: the group cancel list it enters
    FIELD(T5Cancel, tracking_pick),
    FIELD(T5Cancel, extradata),
    FIELD(T5Cancel, window_start),
    FIELD(T5Cancel, window_end),
    FIELD(T5Cancel, start_frame),
    FIELD(T5Cancel, option),
};

static const Field requirement_fields[] = {
    FIELD(T5Requirement, id),
    FIELD(T5Requirement, param),
};

static const Field input_sequence_fields[] = {
    FIELD(T5InputSequence, window),
    FIELD(T5InputSequence, count),
    LIST(T5InputSequence, first, "input_extra"),
};

static const Field command_fields[] = {
    FIELD(T5Command, code),
    FIELD(T5Command, buttons),
};

static const Field move_pool_fields[] = {VALUE(uint16_t, "move")};

static const Field pushback_fields[] = {
    FIELD(T5Pushback, frames),
    FIELD(T5Pushback, distance),
    FIELD(T5Pushback, curve_frames),
    LIST(T5Pushback, curve, "pushback_curve"),
};

static const Field pushback_curve_fields[] = {VALUE(uint16_t, "value")};

static const Field property_fields[] = {
    FIELD(T5Property, when),
    FIELD(T5Property, id),
    FIELD(T5Property, value),
};

static const Field conditional_property_fields[] = {
    LIST(T5ConditionalProperty, requirements, "requirement"),
    FIELD(T5ConditionalProperty, id),
    FIELD(T5ConditionalProperty, value),
};

static const Field hit_condition_fields[] = {
    LIST(T5HitCondition, requirements, "requirement"),
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
    ROWS_LISTS,    // (list, pos) rows, laid out in list id order
    ROWS_INDEXED,  // idx 0..count-1
    ROWS_ONE,      // the one row of the character
} Rows;

static const char *const ORDER_BY[] = {[ROWS_LISTS] = " ORDER BY list, pos", [ROWS_INDEXED] = " ORDER BY idx", [ROWS_ONE] = ""};

typedef struct {
    const char *name;
    Rows rows;
    size_t size;
    size_t items, count;  // in T5Motbin
    const Field *fields;
    size_t field_count;
} Table;

#define TABLE(name, rows, type, items, count, fields) \
    {name, rows, sizeof(type), offsetof(T5Motbin, items), offsetof(T5Motbin, count), fields, sizeof fields / sizeof fields[0]}

static const Table tables[] = {  // moves first: the first thing taken from the arena is `moves`
    TABLE("move", ROWS_INDEXED, T5Move, moves, move_count, move_fields),
    TABLE("cancel", ROWS_LISTS, T5Cancel, cancels, cancel_count, cancel_fields),
    TABLE("group_cancel", ROWS_LISTS, T5Cancel, group_cancels, group_cancel_count, cancel_fields),
    TABLE("requirement", ROWS_LISTS, T5Requirement, requirements, requirement_count, requirement_fields),
    TABLE("input_sequence", ROWS_INDEXED, T5InputSequence, input_sequences, input_sequence_count, input_sequence_fields),
    TABLE("input_extra", ROWS_LISTS, T5Command, input_extras, input_extra_count, command_fields),
    TABLE("move_pool", ROWS_LISTS, uint16_t, id_pool, id_pool_count, move_pool_fields),
    TABLE("pushback", ROWS_INDEXED, T5Pushback, pushbacks, pushback_count, pushback_fields),
    TABLE("pushback_curve", ROWS_LISTS, uint16_t, pushback_curves, pushback_curve_count, pushback_curve_fields),
    TABLE("extra_prop", ROWS_LISTS, T5Property, properties, property_count, property_fields),
    TABLE("start_prop", ROWS_LISTS, T5ConditionalProperty, start_properties, start_property_count, conditional_property_fields),
    TABLE("end_prop", ROWS_LISTS, T5ConditionalProperty, end_properties, end_property_count, conditional_property_fields),
    TABLE("hit_condition", ROWS_LISTS, T5HitCondition, hit_conditions, hit_condition_count, hit_condition_fields),
    TABLE("side_band", ROWS_INDEXED, T5SideBand, side_bands, side_band_count, side_band_fields),
    TABLE("reaction", ROWS_INDEXED, T5Reaction, reactions, reaction_count, reaction_fields),
    TABLE("tracking_row", ROWS_INDEXED, T5FacingRow, tracking, tracking_count, tracking_row_fields),
    TABLE("tracking_override", ROWS_INDEXED, T5MoveTracking, tracking_overrides, tracking_override_count, move_tracking_fields),
    TABLE("tracking_fixed", ROWS_INDEXED, T5MoveTracking, fixed_tracking, fixed_tracking_count, move_tracking_fields),
    TABLE("body", ROWS_ONE, T5Body, body, body_count, body_fields),
    TABLE("body_points", ROWS_ONE, T5BodyPoints, body_points, body_point_count, body_points_fields),
    TABLE("gaze", ROWS_ONE, T5Gaze, gaze, gaze_count, gaze_fields),
};
#define TABLE_COUNT (sizeof tables / sizeof tables[0])

static char error[512];

static const char *fail(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(error, sizeof error, format, arguments);
    va_end(arguments);
    return error;
}

static const char *prepare(sqlite3 *db, const char *sql, const char *character, sqlite3_stmt **statement) {
    if (sqlite3_prepare_v2(db, sql, -1, statement, NULL) != SQLITE_OK) return fail("%s: %s", sql, sqlite3_errmsg(db));
    sqlite3_bind_text(*statement, 1, character, -1, SQLITE_STATIC);
    return NULL;
}

// Rows of the table for the character. Indexed rows must be 0..count-1.
static const char *count_rows(sqlite3 *db, const char *character, const Table *table, int32_t *count) {
    char sql[256];
    bool indexed = table->rows == ROWS_INDEXED;
    snprintf(sql, sizeof sql, "SELECT count(*), %s FROM %s WHERE character = ?1", indexed ? "coalesce(max(idx) + 1, 0)" : "0",
             table->name);
    sqlite3_stmt *statement;
    const char *failed = prepare(db, sql, character, &statement);
    if (failed) return failed;
    sqlite3_step(statement);
    *count = sqlite3_column_int(statement, 0);
    int32_t span = sqlite3_column_int(statement, 1);
    sqlite3_finalize(statement);
    if (indexed && span != *count) return fail("%s %s: idx runs to %d over %d rows", table->name, character, span - 1, *count);
    return NULL;
}

// Every table ends with one zero record: a scan that runs one entry past the list reads zeros.
static size_t table_bytes(int32_t count, size_t size) { return t5_arena_round(((size_t)count + 1) * size); }

const char *t5_load_motbin_storage(sqlite3 *db, const char *character, size_t *bytes) {
    *bytes = 0;
    for (size_t index = 0; index < TABLE_COUNT; index++) {
        int32_t count;
        const char *failed = count_rows(db, character, &tables[index], &count);
        if (failed) return failed;
        *bytes += table_bytes(count, tables[index].size);
    }
    return NULL;
}

// The first row of each list of a table, in id order: the order the lists are laid out in.
typedef struct {
    int64_t id;
    int32_t first;
} ListStart;

typedef struct {
    ListStart *starts;
    int32_t count;
} Lists;

static const char *read_lists(sqlite3 *db, const char *character, const char *table, Lists *lists) {
    char sql[256];
    snprintf(sql, sizeof sql, "SELECT list, count(*) FROM %s WHERE character = ?1 GROUP BY list ORDER BY list", table);
    sqlite3_stmt *statement;
    const char *failed = prepare(db, sql, character, &statement);
    if (failed) return failed;
    int32_t room = 0, first = 0;
    while (sqlite3_step(statement) == SQLITE_ROW) {
        if (lists->count == room) {
            room = room ? 2 * room : 256;
            ListStart *grown = realloc(lists->starts, (size_t)room * sizeof *grown);
            if (!grown) return sqlite3_finalize(statement), fail("out of memory");
            lists->starts = grown;
        }
        lists->starts[lists->count++] = (ListStart){sqlite3_column_int64(statement, 0), first};
        first += sqlite3_column_int(statement, 1);
    }
    sqlite3_finalize(statement);
    return NULL;
}

static bool list_first(const Lists *lists, int64_t id, int64_t *first) {
    int32_t low = 0, high = lists->count;
    while (low < high) {
        int32_t middle = (low + high) / 2;
        if (lists->starts[middle].id < id) low = middle + 1;
        else high = middle;
    }
    if (low == lists->count || lists->starts[low].id != id) return false;
    *first = lists->starts[low].first;
    return true;
}

static uint32_t anim_base(const char *owner, T5AnimBases anims) {
    static const char embedded[] = "/embedded";
    size_t length = strlen(owner);
    if (strcmp(owner, "common") == 0) return anims.common;
    if (length >= sizeof embedded - 1 && strcmp(owner + length - (sizeof embedded - 1), embedded) == 0) return anims.embedded;
    return anims.character;
}

static void build_select(const Table *table, char *sql, size_t room) {
    size_t used = (size_t)snprintf(sql, room, "SELECT ");
    const char *separator = "";
    for (size_t index = 0; index < table->field_count; index++) {
        const Field *field = &table->fields[index];
        for (size_t element = 0; element < field->count; element++, separator = ", ") {
            if (field->kind == KIND_ANIM) used += (size_t)snprintf(sql + used, room - used, "%s\"anim_owner\", \"anim_idx\"", separator);
            else if (field->count == 1) used += (size_t)snprintf(sql + used, room - used, "%s\"%s\"", separator, field->column);
            else used += (size_t)snprintf(sql + used, room - used, "%s\"%s_%zu\"", separator, field->column, element);
            if (used >= room) return;  // too long: the prepare fails on the cut SQL
        }
    }
    snprintf(sql + used, room - used, " FROM %s WHERE character = ?1%s", table->name, ORDER_BY[table->rows]);
}

static const char *copy_row(sqlite3_stmt *row, const Table *table, const Lists *lists, T5AnimBases anims, uint8_t *record) {
    int column = 0;
    for (size_t index = 0; index < table->field_count; index++) {
        const Field *field = &table->fields[index];
        for (size_t element = 0; element < field->count; element++, column++) {
            uint8_t *at = record + field->offset + element * field->stride;
            if (field->kind == KIND_ANIM) {
                const char *owner = (const char *)sqlite3_column_text(row, column);
                uint32_t value = anim_base(owner ? owner : "", anims) + (uint32_t)sqlite3_column_int64(row, ++column);
                memcpy(at, &value, field->size);
                continue;
            }
            if (sqlite3_column_type(row, column) == SQLITE_NULL) continue;
            if (field->kind == KIND_FLOAT) {
                float value = (float)sqlite3_column_double(row, column);
                memcpy(at, &value, sizeof value);
                continue;
            }
            int64_t value = sqlite3_column_int64(row, column);
            if (field->kind == KIND_LIST && value != -1 && !list_first(&lists[index], value, &value))
                return fail("%s.%s: no %s list %lld", table->name, field->column, field->list, (long long)value);
            memcpy(at, &value, field->size);  // little endian: the low bytes
        }
    }
    return NULL;
}

static const char *load_table(sqlite3 *db, const char *character, const Table *table, T5AnimBases anims, T5Arena *arena,
                              T5Motbin *motbin) {
    int32_t count;
    const char *failed = count_rows(db, character, table, &count);
    if (failed) return failed;
    uint8_t *items = t5_arena_take(arena, table_bytes(count, table->size));
    if (!items) return fail("%s: arena full", table->name);
    memset(items, 0, table_bytes(count, table->size));
    *(void **)((char *)motbin + table->items) = items;
    *(int32_t *)((char *)motbin + table->count) = count;

    Lists lists[table->field_count];
    memset(lists, 0, sizeof lists);
    for (size_t index = 0; index < table->field_count && !failed; index++)
        if (table->fields[index].kind == KIND_LIST) failed = read_lists(db, character, table->fields[index].list, &lists[index]);
    char sql[4096];
    build_select(table, sql, sizeof sql);
    sqlite3_stmt *rows = NULL;
    if (!failed) failed = prepare(db, sql, character, &rows);
    for (int32_t row = 0; !failed && row < count && sqlite3_step(rows) == SQLITE_ROW; row++)
        failed = copy_row(rows, table, lists, anims, items + (size_t)row * table->size);
    sqlite3_finalize(rows);
    for (size_t index = 0; index < table->field_count; index++) free(lists[index].starts);
    return failed;
}

static const char *load_aliases(sqlite3 *db, const char *character, T5Motbin *motbin) {
    sqlite3_stmt *rows;
    const char *failed = prepare(db, "SELECT idx, move FROM move_alias WHERE character = ?1", character, &rows);
    if (failed) return failed;
    while (!failed && sqlite3_step(rows) == SQLITE_ROW) {
        int64_t index = sqlite3_column_int64(rows, 0);
        if (index < 0 || index >= T5_ALIAS_COUNT) failed = fail("move_alias %s: idx %lld", character, (long long)index);
        else motbin->aliases[index] = (uint32_t)sqlite3_column_int64(rows, 1);
    }
    sqlite3_finalize(rows);
    memcpy(motbin->alias_defaults, motbin->aliases, sizeof motbin->aliases);
    return failed;
}

const char *t5_load_motbin(T5Motbin *motbin, sqlite3 *db, const char *character, T5AnimBases anims, T5Arena *arena) {
    memset(motbin, 0, sizeof *motbin);
    const char *failed = load_aliases(db, character, motbin);
    for (size_t index = 0; index < TABLE_COUNT && !failed; index++) failed = load_table(db, character, &tables[index], anims, arena, motbin);
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

enum { OWNER_BYTES = 128, HAND_OWNER_BYTES = OWNER_BYTES + sizeof "/hand_gestures" };

// The owners of the character's banks in fighter order: its own (the bank its moves name that is neither common nor
// embedded), common, embedded.
static const char *bank_owners(sqlite3 *db, const char *character, char owners[3][OWNER_BYTES]) {
    T5AnimBases ranks = {0, 1, 2};
    snprintf(owners[0], OWNER_BYTES, "%s", character);
    snprintf(owners[1], OWNER_BYTES, "common");
    snprintf(owners[2], OWNER_BYTES, "%s/embedded", character);
    sqlite3_stmt *rows;
    const char *failed = prepare(db, "SELECT DISTINCT anim_owner FROM move WHERE character = ?1", character, &rows);
    while (!failed && sqlite3_step(rows) == SQLITE_ROW) {
        const char *owner = (const char *)sqlite3_column_text(rows, 0);
        if (owner && anim_base(owner, ranks) == ranks.character) snprintf(owners[0], OWNER_BYTES, "%s", owner);
    }
    sqlite3_finalize(rows);
    return failed;
}

static const char *bank_count(sqlite3 *db, const char *owner, uint32_t *count) {
    sqlite3_stmt *row;
    const char *failed = prepare(db, "SELECT coalesce(max(idx) + 1, 0) FROM anim WHERE character = ?1", owner, &row);
    if (failed) return failed;
    sqlite3_step(row);
    *count = (uint32_t)sqlite3_column_int(row, 0);
    sqlite3_finalize(row);
    return NULL;
}

// A bank's clips: one record of `size` bytes per id, read from its file by `parse`. Ids without a row stay zero; rows
// that name one file share one record.
typedef struct {
    size_t size;
    int (*parse)(void *clip, T5Bytes file);
    const char *what;
} ClipKind;

static int parse_anim(void *anim, T5Bytes file) { return t5_anim_parse(anim, file); }
static int parse_hand_clip(void *clip, T5Bytes file) { return t5_hand_clip_parse(clip, file); }

static const ClipKind ANIMS = {sizeof(T5Anim), parse_anim, "anims"};
static const ClipKind HAND_CLIPS = {sizeof(T5HandClip), parse_hand_clip, "hand clips"};

static size_t clips_bytes(uint32_t count, ClipKind kind) { return t5_arena_round(((size_t)count + 1) * kind.size); }  // and a zero one

static const char *clips_storage(sqlite3 *db, const char *owner, ClipKind kind, size_t *bytes) {
    uint32_t count;
    const char *failed = bank_count(db, owner, &count);
    *bytes = failed ? 0 : clips_bytes(count, kind);
    return failed;
}

static const char *load_clips(void **clips, uint32_t *count, ClipKind kind, sqlite3 *db, const char *owner, T5ReadFile read,
                              void *context, T5Arena *arena) {
    const char *failed = bank_count(db, owner, count);
    if (failed) return failed;
    uint8_t *records = t5_arena_take(arena, clips_bytes(*count, kind));
    if (!records) return fail("%s %s: arena full", kind.what, owner);
    memset(records, 0, clips_bytes(*count, kind));
    *clips = records;
    sqlite3_stmt *rows;
    failed = prepare(db, "SELECT idx, file, (SELECT min(idx) FROM anim b WHERE b.character = a.character AND b.file = a.file) "
                         "FROM anim a WHERE character = ?1 ORDER BY idx", owner, &rows);
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

const char *t5_load_anims_storage(sqlite3 *db, const char *character, size_t *bytes) {
    char owners[3][OWNER_BYTES];
    const char *failed = bank_owners(db, character, owners);
    *bytes = 0;
    for (int bank = 0; bank < 3 && !failed; bank++) {
        size_t bank_bytes;
        failed = clips_storage(db, owners[bank], ANIMS, &bank_bytes);
        *bytes += bank_bytes;
    }
    return failed;
}

const char *t5_load_anim_bank_storage(sqlite3 *db, const char *owner, size_t *bytes) { return clips_storage(db, owner, ANIMS, bytes); }

const char *t5_load_anim_bank(T5AnimBank *bank, sqlite3 *db, const char *owner, T5ReadFile read, void *context, T5Arena *arena) {
    return load_clips((void **)&bank->anims, &bank->anim_count, ANIMS, db, owner, read, context, arena);
}

const char *t5_load_anims(T5FighterFiles *files, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena) {
    char owners[3][OWNER_BYTES];
    const char *failed = bank_owners(db, character, owners);
    T5AnimBank *banks[3] = {&files->character, &files->common, &files->embedded};
    for (int bank = 0; bank < 3 && !failed; bank++) failed = t5_load_anim_bank(banks[bank], db, owners[bank], read, context, arena);
    return failed;
}

// The pose bank is the character's, the gestures belong to the owner of its own anim bank.
static const char *hand_owners(sqlite3 *db, const char *character, char owners[2][HAND_OWNER_BYTES]) {
    char banks[3][OWNER_BYTES];
    const char *failed = bank_owners(db, character, banks);
    snprintf(owners[0], HAND_OWNER_BYTES, "%s/hand_poses", character);
    snprintf(owners[1], HAND_OWNER_BYTES, "%s/hand_gestures", banks[0]);
    return failed;
}

const char *t5_load_hands_storage(sqlite3 *db, const char *character, size_t *bytes) {
    char owners[2][HAND_OWNER_BYTES];
    const char *failed = hand_owners(db, character, owners);
    *bytes = 0;
    for (int bank = 0; bank < 2 && !failed; bank++) {
        size_t bank_bytes;
        failed = clips_storage(db, owners[bank], HAND_CLIPS, &bank_bytes);
        *bytes += bank_bytes;
    }
    return failed;
}

const char *t5_load_hands(T5HandBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context, T5Arena *arena) {
    char owners[2][HAND_OWNER_BYTES];
    const char *failed = hand_owners(db, character, owners);
    T5HandBank *bank[2] = {&banks->poses, &banks->gestures};
    for (int k = 0; k < 2 && !failed; k++)
        failed = load_clips((void **)&bank[k]->clips, &bank[k]->clip_count, HAND_CLIPS, db, owners[k], read, context, arena);
    if (!failed && (!banks->poses.clip_count || !banks->gestures.clip_count)) failed = fail("hands %s: no clips", character);
    return failed;
}

static const char *stage_files(sqlite3 *db, const char *stage, T5ReadFile read, void *context, T5Bytes *collision, T5Bytes *surfaces) {
    sqlite3_stmt *row;
    const char *failed = prepare(db, "SELECT collision, surfaces FROM stage WHERE id = ?1", stage, &row);
    if (!failed && sqlite3_step(row) != SQLITE_ROW) failed = fail("stage %s: no row", stage);
    if (!failed) {
        *collision = read(context, (const char *)sqlite3_column_text(row, 0));
        *surfaces = read(context, (const char *)sqlite3_column_text(row, 1));
        if (!collision->size || !surfaces->size) failed = fail("stage %s: missing file", stage);
    }
    sqlite3_finalize(row);
    return failed;
}

static const char *load_stage(T5Stage *out, sqlite3 *db, const char *stage, T5ReadFile read, void *context, T5Arena *arena, size_t *bytes) {
    T5Bytes collision, surfaces;
    const char *failed = stage_files(db, stage, read, context, &collision, &surfaces);
    if (!failed) failed = t5_stage_parse(out, collision, surfaces, arena, bytes);
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
