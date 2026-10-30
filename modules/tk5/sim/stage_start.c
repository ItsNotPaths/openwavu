// The start points of a stage: count, position and rotation, read from section 14
// (object slot 0) and 13 (slot 1). A "TKPD" section is read by entry id, a "POS " section by pair.
#include <stddef.h>

#include "sim/stage.h"

enum { TABLES = 7, POS_COUNT_TABLES = 6, SECOND_POINT_TABLE = 1, NO_POINT_TABLE_TKPD = 5 };

static const struct { uint8_t slot, tkpd_id, count_pair, point_pair; } TABLE[TABLES] = {
    {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 1, 1, 1}, {0, 2, 2, 2}, {1, 3, 3, 3}, {1, 3, 2, 2}, {0, 12, 0, 2},
};

static const T5StartGroup *group_of(const T5Stage *s, int32_t table, bool counting) {
    const T5StartSlot *slot = &s->start[TABLE[table].slot];
    if (slot->pos_format) {  // POS section: pick the group by pair index
        int32_t pair = counting ? TABLE[table].count_pair : TABLE[table].point_pair;
        return pair < slot->group_count ? &slot->groups[pair] : NULL;  // past the last pair: null
    }
    for (int32_t index = 0; index < slot->group_count; index++)  // TKPD section: find the group with the table's entry id
        if (slot->groups[index].id == TABLE[table].tkpd_id) return &slot->groups[index];
    return NULL;
}

int32_t t5_stage_start_count(const T5Stage *s, int32_t table) {
    if ((uint32_t)table >= TABLES || (table >= POS_COUNT_TABLES && s->start[TABLE[table].slot].pos_format)) return 0;
    const T5StartGroup *group = group_of(s, table, true);
    return group ? group->count : 0;
}

// Table 5 has no points in a TKPD section. An index past the records gives null (the game reads on past the entry at count).
static const T5StartPoint *point_of(const T5Stage *s, int32_t table, int32_t index) {
    if ((uint32_t)table >= TABLES || (!s->start[TABLE[table].slot].pos_format && table == NO_POINT_TABLE_TKPD)) return NULL;
    const T5StartGroup *group = group_of(s, table, false);
    if (!group || !group->points || (uint32_t)index >= (uint32_t)group->count) return NULL;  // no group or index past end: null
    return &group->points[index * group->per_record + (table == SECOND_POINT_TABLE ? 1 : 0)];  // table 1: second point
}

const float *t5_stage_start_position(const T5Stage *s, int32_t table, int32_t index) {
    const T5StartPoint *point = point_of(s, table, index);
    return point ? point->position : NULL;
}

const float *t5_stage_start_rotation(const T5Stage *s, int32_t table, int32_t index) {
    const T5StartPoint *point = point_of(s, table, index);
    return point ? point->rotation : NULL;
}
