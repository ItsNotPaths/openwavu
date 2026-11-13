// Loads characters from a db through the TK6 sim's loader (modules/tk6/load.c) and prints what the sim could not trust:
// an index out of its table, an id it does not know, a list that runs past its table without the sim's end marker, a
// value the loader cut (the db's TK6 values must reach the sim whole).
// Usage: tk6_motbin_check db character... Exit 1 when anything is printed.
#include <stdio.h>
#include <stdlib.h>

#include "load.h"
#include "sim/properties.h"
#include "sim/requirements.h"
#include "sqlite3.h"

enum { PROPERTY_LAST = T6_PROPERTY_BASE + 371 };  // PROP_PUSH_POINTS_BEHIND

static int problems;

#define PROBLEM(...) (problems++, printf("%s: ", character), printf(__VA_ARGS__), printf("\n"))

static bool move_valid(const T6Motbin *m, uint32_t id) {
    return id < (uint32_t)m->move_count || (id >= T6_ALIAS_BASE && id < T6_ALIAS_BASE + T6_ALIAS_COUNT);
}

static bool requirement_known(uint16_t id) {
    return id < T6_REQUIREMENT_COUNT || id == T6_REQ_END || (id > T6_PROPERTY_BASE && id <= PROPERTY_LAST);
}

// The list from `first` reaches an end row inside the table.
static bool requirements_end(const T6Motbin *m, uint32_t first) {
    for (uint32_t index = first; index < (uint32_t)m->requirement_count; index++)
        if (m->requirements[index].id == T6_REQ_END) return true;
    return false;
}

static void check_cancels(const char *character, const T6Motbin *m, const T6Cancel *cancels, int32_t count, bool group) {
    for (int32_t index = 0; index < count; index++) {
        const T6Cancel *cancel = &cancels[index];
        uint16_t code = cancel->command.code;
        if (cancel->requirements >= (uint32_t)m->requirement_count || !requirements_end(m, cancel->requirements))
            PROBLEM("%scancel %d: requirement list %u", group ? "group " : "", index, cancel->requirements);
        if (code >= T6_CANCEL_SEQUENCE && code - T6_CANCEL_SEQUENCE >= m->input_sequence_count)
            PROBLEM("cancel %d: input sequence %d", index, code - T6_CANCEL_SEQUENCE);
        if (code == T6_CANCEL_GROUP) {
            bool ends = false;
            for (int32_t entry = cancel->move; entry < m->group_cancel_count && !ends; entry++)
                ends = m->group_cancels[entry].command.code == T6_CANCEL_GROUP_END;
            if (!ends) PROBLEM("cancel %d: group list %d has no end", index, cancel->move);
        } else if (code != T6_CANCEL_GROUP_END && !move_valid(m, cancel->move)) {
            PROBLEM("%scancel %d: move %#x", group ? "group " : "", index, cancel->move);
        }
        if (cancel->tracking_pick > m->tracking_override_count) PROBLEM("cancel %d: tracking pick %d", index, cancel->tracking_pick);
    }
}

static void check_moves(const char *character, const T6Motbin *m) {
    for (int32_t index = 0; index < m->move_count; index++) {
        const T6Move *move = &m->moves[index];
        bool ends = false;
        for (uint32_t entry = move->cancels; entry < (uint32_t)m->cancel_count && !ends; entry++)
            ends = m->cancels[entry].command.code == T6_CANCEL_END;
        if (!ends) PROBLEM("move %d: cancel list %u has no end", index, move->cancels);
        if (move->hit_conditions >= (uint32_t)m->hit_condition_count) PROBLEM("move %d: hit conditions %u", index, move->hit_conditions);
        if (!move_valid(m, move->next_move)) PROBLEM("move %d: next move %#x", index, move->next_move);
        if (move->voiceclips >= m->voiceclip_count) PROBLEM("move %d: voice clips %d", index, move->voiceclips);
        if (move->start_props >= m->start_property_count) PROBLEM("move %d: start properties %d", index, move->start_props);
        if (move->end_prop >= m->end_property_count) PROBLEM("move %d: end properties %d", index, move->end_prop);
        if (move->extra_props >= m->property_count) PROBLEM("move %d: properties %d", index, move->extra_props);
        if (move->extra_props >= 0) {
            ends = false;
            for (int32_t entry = move->extra_props; entry < m->property_count && !ends; entry++) ends = m->properties[entry].when == 0;
            if (!ends) PROBLEM("move %d: property list has no end", index);
        }
        if (move->tracking.row >= m->tracking_count || move->tracking.far_row >= m->tracking_count)
            PROBLEM("move %d: tracking row %d", index, move->tracking.row);
    }
}

static void check_ids(const char *character, const T6Motbin *m) {
    for (int32_t index = 0; index < m->requirement_count; index++)
        if (!requirement_known(m->requirements[index].id)) PROBLEM("requirement %d: id %d", index, m->requirements[index].id);
    for (int32_t index = 0; index < m->property_count; index++) {
        const T6Property *property = &m->properties[index];
        if (property->when && (property->id <= T6_PROPERTY_BASE || property->id > PROPERTY_LAST))
            PROBLEM("property %d: id %#x", index, property->id);
    }
    const T6ConditionalProperty *lists[] = {m->start_properties, m->end_properties};
    const int32_t counts[] = {m->start_property_count, m->end_property_count};
    for (int list = 0; list < 2; list++)
        for (int32_t index = 0; index < counts[list]; index++) {
            const T6ConditionalProperty *property = &lists[list][index];
            if (property->id == 0) continue;  // the end row
            if (property->id <= T6_PROPERTY_BASE || property->id > PROPERTY_LAST) PROBLEM("conditional property %d: id %#x", index, property->id);
            if (!requirements_end(m, property->requirements)) PROBLEM("conditional property %d: requirement list", index);
        }
}

static void check_reactions(const char *character, const T6Motbin *m) {
    for (int32_t index = 0; index < m->hit_condition_count; index++) {
        const T6HitCondition *condition = &m->hit_conditions[index];
        if (!requirements_end(m, condition->requirements)) PROBLEM("hit condition %d: requirement list", index);
        if (condition->reaction >= (uint32_t)m->reaction_count) PROBLEM("hit condition %d: reaction %u", index, condition->reaction);
    }
    for (int32_t index = 0; index < m->reaction_count; index++) {
        const T6Reaction *reaction = &m->reactions[index];
        for (int slot = 0; slot < 7; slot++)
            if (reaction->pushback[slot].index >= m->pushback_count) PROBLEM("reaction %d: pushback %d", index, reaction->pushback[slot].index);
        for (int slot = 0; slot < 14; slot++)
            if (!move_valid(m, reaction->move[slot])) PROBLEM("reaction %d: move %#x", index, reaction->move[slot]);
    }
    for (int32_t index = 0; index < m->pushback_count; index++)
        if (m->pushbacks[index].curve > (uint32_t)m->pushback_curve_count) PROBLEM("pushback %d: curve %u", index, m->pushbacks[index].curve);
    for (int slot = 0; slot < T6_ALIAS_COUNT; slot++)
        if (m->aliases[slot] >= (uint32_t)m->move_count) PROBLEM("alias %d: move %u", slot, m->aliases[slot]);
}

// The plain values of `sql` (one column, rows in load order; NULL: a reference, skipped) equal the loaded ones.
static void check_values(sqlite3 *db, const char *character, const char *what, const char *sql, const uint64_t *loaded, int32_t count) {
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, sql, -1, &rows, NULL) != SQLITE_OK) {
        PROBLEM("%s: %s", what, sqlite3_errmsg(db));
        return;
    }
    sqlite3_bind_text(rows, 1, character, -1, SQLITE_STATIC);
    int32_t index = 0;
    for (; sqlite3_step(rows) == SQLITE_ROW; index++) {
        if (index >= count) break;
        if (sqlite3_column_type(rows, 0) == SQLITE_INTEGER && (uint64_t)sqlite3_column_int64(rows, 0) != loaded[index])
            PROBLEM("%s %d: the db holds %lld, the sim %llu", what, index, sqlite3_column_int64(rows, 0), (unsigned long long)loaded[index]);
    }
    if (index != count) PROBLEM("%s: %d rows, %d loaded", what, index, count);
    sqlite3_finalize(rows);
}

#define LIST_ROWS(table, column) "SELECT " column " FROM " table "_list l JOIN " table " ON list = l.key WHERE l.character = ?1 ORDER BY l.rowid, pos"

// Values wider than TK5's in TK6 data: voice clips, compare ids, requirement params and property values, window ends.
static void check_widths(sqlite3 *db, const char *character, const T6Motbin *m) {
    int32_t room = m->move_count + m->voiceclip_count + m->id_pool_count + m->requirement_count + m->property_count +
                   m->start_property_count + m->end_property_count;
    uint64_t *loaded = malloc((size_t)room * sizeof *loaded);
    int32_t count = 0;
    for (int32_t index = 0; index < m->move_count; index++) loaded[count++] = m->moves[index].compare_id;
    check_values(db, character, "move compare_id", "SELECT compare_id FROM move WHERE character = ?1 ORDER BY rowid", loaded, count);
    count = 0;
    for (int32_t index = 0; index < m->move_count; index++) loaded[count++] = (uint64_t)m->moves[index].window_end;
    check_values(db, character, "move window_end", "SELECT window_end FROM move WHERE character = ?1 ORDER BY rowid", loaded, count);
    count = 0;
    for (int32_t index = 0; index < m->voiceclip_count; index++)
        if (m->voiceclips[index] != T6_VOICECLIP_END) loaded[count++] = m->voiceclips[index];
    check_values(db, character, "voiceclip", LIST_ROWS("voiceclip", "value"), loaded, count);
    count = 0;
    for (int32_t index = 0; index < m->id_pool_count; index++)
        if (m->id_pool[index] != 0) loaded[count++] = m->id_pool[index];
    check_values(db, character, "move_pool", LIST_ROWS("move_pool", "compare_id"), loaded, count);
    count = 0;
    for (int32_t index = 0; index < m->requirement_count; index++)
        if (m->requirements[index].id != T6_REQ_END) loaded[count++] = m->requirements[index].param;
    check_values(db, character, "requirement param", LIST_ROWS("requirement", "coalesce(param, param_compare_id)"), loaded, count);
    count = 0;
    for (int32_t index = 0; index < m->property_count; index++)
        if (m->properties[index].when != 0) loaded[count++] = m->properties[index].value;
    check_values(db, character, "extra_prop value", LIST_ROWS("extra_prop", "coalesce(value, value_compare_id)"), loaded, count);
    const char *const names[] = {"start_prop value", "end_prop value"};
    const char *const sql[] = {LIST_ROWS("start_prop", "coalesce(value, value_compare_id)"), LIST_ROWS("end_prop", "coalesce(value, value_compare_id)")};
    const T6ConditionalProperty *lists[] = {m->start_properties, m->end_properties};
    const int32_t counts[] = {m->start_property_count, m->end_property_count};
    for (int list = 0; list < 2; list++) {
        count = 0;
        for (int32_t index = 0; index < counts[list]; index++)
            if (lists[list][index].id != 0) loaded[count++] = lists[list][index].value;
        check_values(db, character, names[list], sql[list], loaded, count);
    }
    free(loaded);
}

int main(int argc, char **argv) {
    sqlite3 *db;
    if (argc < 3 || sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return 2;
    for (int argument = 2; argument < argc; argument++) {
        const char *character = argv[argument];
        size_t bytes;
        const char *failed = t6_load_motbin_storage(db, character, character, &bytes);
        T6Arena arena = {malloc(bytes), bytes, 0};
        T6Motbin m;
        if (!failed) failed = t6_load_motbin(&m, db, character, character, (T6AnimBases){}, &arena);
        if (failed) {
            PROBLEM("load: %s", failed);
        } else {
            check_moves(character, &m);
            check_cancels(character, &m, m.cancels, m.cancel_count, false);
            check_cancels(character, &m, m.group_cancels, m.group_cancel_count, true);
            check_ids(character, &m);
            check_reactions(character, &m);
            check_widths(db, character, &m);
        }
        free(arena.base);
    }
    return problems ? 1 : 0;
}
