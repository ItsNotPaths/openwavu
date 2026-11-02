// Loads a character from the pack database (modules/tk5/load.c) and from its sim files (.t5m, .t5b) and prints each table
// that differs. Fields the db does not carry, because the sim never reads them, are zeroed on both sides.
// Usage: load_parity db character t5m character_t5a common_t5a t5b
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "load.h"
#include "sim/skel.h"
#include "sqlite3.h"

typedef struct {
    const char *name;
    size_t size, items, count;
} Table;

#define TABLE(type, items, count) {#items, sizeof(type), offsetof(T5Motbin, items), offsetof(T5Motbin, count)}

static const Table tables[] = {  // end_properties: the .t5m files hold none
    TABLE(T5Move, moves, move_count),
    TABLE(T5Cancel, cancels, cancel_count),
    TABLE(T5Cancel, group_cancels, group_cancel_count),
    TABLE(T5Requirement, requirements, requirement_count),
    TABLE(uint16_t, id_pool, id_pool_count),
    TABLE(T5Pushback, pushbacks, pushback_count),
    TABLE(uint16_t, pushback_curves, pushback_curve_count),
    TABLE(T5Property, properties, property_count),
    TABLE(T5ConditionalProperty, start_properties, start_property_count),
    TABLE(T5HitCondition, hit_conditions, hit_condition_count),
    TABLE(T5SideBand, side_bands, side_band_count),
    TABLE(T5Reaction, reactions, reaction_count),
    TABLE(T5FacingRow, tracking, tracking_count),
    TABLE(T5MoveTracking, tracking_overrides, tracking_override_count),
    TABLE(T5MoveTracking, fixed_tracking, fixed_tracking_count),
    TABLE(T5Body, body, body_count),
    TABLE(T5BodyPoints, body_points, body_point_count),
    TABLE(T5Gaze, gaze, gaze_count),
};

static T5Bytes read_file(const char *path) {
    FILE *in = fopen(path, "rb");
    if (!in) return (T5Bytes){};
    fseek(in, 0, SEEK_END);
    size_t size = (size_t)ftell(in);
    uint8_t *data = malloc(size);
    rewind(in);
    size = fread(data, 1, size, in);
    fclose(in);
    return (T5Bytes){data, size};
}

// Anims of a .t5a bank: the u16 at byte 2, as tools/motbin2bin.py reads it.
static uint32_t bank_count(const char *path) {
    T5Bytes bank = read_file(path);
    return bank.size >= 4 ? (uint32_t)(bank.data[2] | bank.data[3] << 8) : 0;
}

static const float HEAD_TOP_TOLERANCE = 0.001f;  // mm: the importer's f32 pose against tools/body.py's f64 numpy

// head_top is measured, not stock: within the tolerance, the db's value is taken as the file's.
static void match_head_top(T5Motbin *db, const T5Motbin *file) {
    if (db->body_count != 1 || file->body_count != 1) return;
    if (fabsf(db->body->head_top - file->body->head_top) <= HEAD_TOP_TOLERANCE) db->body->head_top = file->body->head_top;
}

// Move bits nothing in the game reads: the db drops them.
enum : uint32_t {
    DEAD_STATE_BITS = 1u << 18 | 1u << 20 | 1u << 24,
    DEAD_HIT_LEVEL_BITS = 1u << 17 | 1u << 23,
    DEAD_FLAG_BITS = 1u << 20 | 1u << 22 | 1u << 25 | 1u << 29,
};

static void drop_unread(T5Motbin *motbin) {
    for (int32_t index = 0; index < motbin->move_count; index++) {
        T5Move *move = &motbin->moves[index];
        move->voiceclips = 0, move->padding = 0;
        move->vuln &= ~DEAD_STATE_BITS, move->hit_level &= ~DEAD_HIT_LEVEL_BITS, move->flags &= ~DEAD_FLAG_BITS;
        memset(move->hitbox, 0, sizeof move->hitbox);
    }
    for (int32_t index = 0; index < motbin->hit_condition_count; index++) motbin->hit_conditions[index].padding = 0;
    for (int32_t index = 0; index < motbin->pushback_count; index++) motbin->pushbacks[index].padding = 0;
    for (int32_t index = 0; index < motbin->property_count; index++) motbin->properties[index].padding = 0;
}

// A one-button press matches alike in every mode (input.c buttons_match): the db writes one.
static T5Command one_press_form(T5Command command) {
    uint16_t press = command.buttons & 15;
    if (command.buttons & T5_COMMAND_SUMMARY || !press || press & (press - 1)) return command;
    command.buttons = (command.buttons & ~T5_COMMAND_ANY_PRESS) | T5_COMMAND_HOLD_AFTER_PRESS;
    return command;
}

static bool same_command(T5Command a, T5Command b) {
    a = one_press_form(a), b = one_press_form(b);
    return a.code == b.code && a.buttons == b.buttons;
}

// The db numbers sequences by cancel where the file shares them, and drops the ones no cancel reads: a cancel that reads
// a sequence must read the same steps. Matching commands then take the file's, so the tables compare byte for byte.
static bool same_inputs(T5Cancel *db_cancels, int32_t db_count, const T5Cancel *file_cancels, int32_t file_count,
                        const T5Motbin *db, const T5Motbin *file, const char *name) {
    for (int32_t row = 0; row < db_count && row < file_count; row++) {
        T5Command *ours = &db_cancels[row].command;
        T5Command theirs = file_cancels[row].command;
        bool same = ours->code >= T5_CANCEL_SEQUENCE && theirs.code >= T5_CANCEL_SEQUENCE;
        if (same) {
            const T5InputSequence *a = &db->input_sequences[ours->code - T5_CANCEL_SEQUENCE];
            const T5InputSequence *b = &file->input_sequences[theirs.code - T5_CANCEL_SEQUENCE];
            uint16_t a_joints = db->input_joints ? db->input_joints[ours->code - T5_CANCEL_SEQUENCE] : 0;
            uint16_t b_joints = file->input_joints ? file->input_joints[theirs.code - T5_CANCEL_SEQUENCE] : 0;
            same = a->window == b->window && a->count == b->count && a_joints == b_joints;
            for (uint16_t key = 0; same && key < a->count; key++)
                same = same_command(db->input_extras[a->first + key], file->input_extras[b->first + key]);
        } else same = same_command(*ours, theirs);
        if (!same) return printf("%s: row %d reads another input\n", name, row), false;
        *ours = theirs;
    }
    return true;
}

static bool same_table(const Table *table, const T5Motbin *db, const T5Motbin *file) {
    int32_t db_count = *(const int32_t *)((const char *)db + table->count);
    int32_t file_count = *(const int32_t *)((const char *)file + table->count);
    // The db ends a table's last list with an end row where the file runs into its zero record: the sim reads the same.
    if (db_count != file_count && db_count != file_count + 1) {
        printf("%s: %d rows, the sim file %d\n", table->name, db_count, file_count);
        return false;
    }
    const uint8_t *db_items = *(uint8_t *const *)((const char *)db + table->items);
    const uint8_t *file_items = *(uint8_t *const *)((const char *)file + table->items);
    for (int32_t row = 0; row < db_count; row++)
        for (size_t at = 0; at < table->size; at++)
            if (db_items[row * table->size + at] != file_items[row * table->size + at]) {
                printf("%s: row %d differs at byte %zu\n", table->name, row, at);
                return false;
            }
    return true;
}

static bool same_skeleton(sqlite3 *db, const char *character, const char *path) {
    T5Skeleton from_db, from_file;
    memset(&from_file, 0, sizeof from_file);
    const char *failed = t5_load_skeleton(&from_db, db, character);
    if (failed) return printf("%s\n", failed), false;
    if (t5_skeleton_parse(&from_file, read_file(path)) != 0) return printf("bad skeleton file\n"), false;
    if (memcmp(&from_db, &from_file, sizeof from_db) == 0) return true;
    printf("skeleton differs\n");
    return false;
}

int main(int argc, char **argv) {
    if (argc != 7) return 2;
    sqlite3 *db;
    if (sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return 2;
    T5Bytes file = read_file(argv[3]);
    size_t db_bytes, file_bytes;
    const char *failed = t5_load_motbin_storage(db, argv[2], &db_bytes);
    if (failed || !t5_motbin_storage(file, &file_bytes)) return printf("%s\n", failed ? failed : "bad sim file"), 1;

    T5Arena db_arena = {malloc(db_bytes), db_bytes, 0}, file_arena = {malloc(file_bytes), file_bytes, 0};
    uint32_t character = bank_count(argv[4]), common = bank_count(argv[5]);
    T5Motbin from_db, from_file;
    failed = t5_load_motbin(&from_db, db, argv[2], (T5AnimBases){0, character, character + common}, &db_arena);
    if (failed) return printf("%s\n", failed), 1;
    if (t5_motbin_parse(&from_file, file, &file_arena) != 0) return printf("bad sim file\n"), 1;
    drop_unread(&from_db), drop_unread(&from_file);
    match_head_top(&from_db, &from_file);

    bool same = memcmp(from_db.aliases, from_file.aliases, sizeof from_db.aliases) == 0;
    if (!same) printf("aliases differ\n");
    same &= same_inputs(from_db.cancels, from_db.cancel_count, from_file.cancels, from_file.cancel_count, &from_db, &from_file, "cancels");
    same &= same_inputs(from_db.group_cancels, from_db.group_cancel_count, from_file.group_cancels, from_file.group_cancel_count, &from_db,
                        &from_file, "group_cancels");
    for (size_t index = 0; index < sizeof tables / sizeof tables[0]; index++) same &= same_table(&tables[index], &from_db, &from_file);
    same &= same_skeleton(db, argv[2], argv[6]);
    return same ? 0 : 1;
}
