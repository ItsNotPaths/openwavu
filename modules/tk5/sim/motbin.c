#include "sim/motbin.h"

#include <stddef.h>
#include <string.h>

// A move record of the file ends before T5Move.hit_pair; the pairs come in the table HITP (two per move) and the hits in HITS
// (one per move), so a build without them reads the same files.
enum { MOVE_FILE_BYTES = offsetof(T5Move, hit_pair) };
_Static_assert(MOVE_FILE_BYTES == 77, "T5Move must match the .t5m record");
_Static_assert(sizeof(T5Cancel) == 24, "T5Cancel must match the .t5m record");
_Static_assert(sizeof(T5Reaction) == 80, "T5Reaction must match the .t5m record");
_Static_assert(sizeof(T5Body) == 196, "T5Body must match the .t5m record");
_Static_assert(sizeof(T5BodyPoints) == 40, "T5BodyPoints must match the .t5m record");
_Static_assert(sizeof(T5Gaze) == 8, "T5Gaze must match the .t5m record");
_Static_assert(sizeof(T5MoveHits) == 8, "T5MoveHits must match the .t5m record");

typedef struct {
    const char *tag;
    size_t size;
    size_t offset_items, offset_count;  // in T5Motbin
} Table;

#define TABLE(tag, type, items, count) {tag, sizeof(type), offsetof(T5Motbin, items), offsetof(T5Motbin, count)}

static const Table tables[] = {  // one row per optional table: file tag, record size, where the list and count go
    TABLE("CANC", T5Cancel, cancels, cancel_count),
    TABLE("GRPC", T5Cancel, group_cancels, group_cancel_count),
    TABLE("REQS", T5Requirement, requirements, requirement_count),
    TABLE("ISEQ", T5InputSequence, input_sequences, input_sequence_count),
    TABLE("IEXT", T5Command, input_extras, input_extra_count),
    TABLE("POOL", uint16_t, id_pool, id_pool_count),
    TABLE("PUSH", T5Pushback, pushbacks, pushback_count),
    TABLE("PCRV", uint16_t, pushback_curves, pushback_curve_count),
    TABLE("XPRP", T5Property, properties, property_count),
    TABLE("SPRP", T5ConditionalProperty, start_properties, start_property_count),
    TABLE("EPRP", T5ConditionalProperty, end_properties, end_property_count),
    TABLE("HCON", T5HitCondition, hit_conditions, hit_condition_count),
    TABLE("SBND", T5SideBand, side_bands, side_band_count),
    TABLE("RLST", T5Reaction, reactions, reaction_count),
    TABLE("TRKR", T5FacingRow, tracking, tracking_count),
    TABLE("TOVR", T5MoveTracking, tracking_overrides, tracking_override_count),
    TABLE("TFIX", T5MoveTracking, fixed_tracking, fixed_tracking_count),
    TABLE("BODY", T5Body, body, body_count),
    TABLE("ANCH", T5BodyPoints, body_points, body_point_count),
    TABLE("GAZE", T5Gaze, gaze, gaze_count),
};
#define TABLE_COUNT (sizeof tables / sizeof tables[0])

typedef struct {
    const uint8_t *cursor;
    size_t left;
} Reader;

typedef struct {
    const uint8_t *records;  // NULL = the file has no such table
    uint32_t count;
} Slice;

typedef struct {
    int32_t move_count;
    uint32_t aliases[T5_ALIAS_COUNT];
    Slice moves;
    Slice hit_pairs;  // HITP
    Slice hits;       // HITS
    Slice table[TABLE_COUNT];
} Layout;

static bool read_value(Reader *reader, void *out, size_t size) {
    if (reader->left < size) return false;
    memcpy(out, reader->cursor, size);
    reader->cursor += size;
    reader->left -= size;
    return true;
}

static bool read_slice(Reader *reader, Slice *out, uint32_t count, size_t size) {
    if (count > reader->left / size) return false;
    *out = (Slice){reader->cursor, count};
    reader->cursor += (size_t)count * size;
    reader->left -= (size_t)count * size;
    return true;
}

// Tagged tables after the moves: tag[4], u32 count, u32 record size, records. Unknown tags are skipped.
static bool read_tables(Reader *reader, Layout *layout) {
    char tag[4];
    uint32_t count, size;
    while (read_value(reader, tag, 4)) {  // read table headers until the file ends
        if (!read_value(reader, &count, 4) || !read_value(reader, &size, 4)) return false;  // header: count, then record size
        const Table *table = NULL;
        Slice *slice = NULL;
        for (size_t index = 0; index < TABLE_COUNT; index++)  // find the known table with this tag
            if (memcmp(tables[index].tag, tag, 4) == 0) table = &tables[index], slice = &layout->table[index];
        if (memcmp(tag, "HITP", 4) == 0) {  // hit pairs are kept apart from the moves
            if (size != sizeof(T5HitPair) || !read_slice(reader, &layout->hit_pairs, count, size)) return false;
            continue;
        }
        if (memcmp(tag, "HITS", 4) == 0) {  // per move hits are kept apart too
            if (size != sizeof(T5MoveHits) || !read_slice(reader, &layout->hits, count, size)) return false;
            continue;
        }
        if (!table) {  // unknown table: skip its records, so newer files still load
            Slice skipped;
            if (!read_slice(reader, &skipped, count, size ? size : 1)) return true;
            continue;
        }
        if (size != table->size || slice->records || !read_slice(reader, slice, count, size)) return false;
    }
    return true;
}

// .t5m: "T5M1", i32 move_count, u32 aliases[37], T5Move[move_count], tagged tables; little endian
static bool read_layout(T5Bytes bytes, Layout *layout) {
    memset(layout, 0, sizeof *layout);  // start with an empty layout
    Reader reader = {bytes.data, bytes.size};
    char magic[4];
    return read_value(&reader, magic, 4) && memcmp(magic, "T5M1", 4) == 0
        && read_value(&reader, &layout->move_count, 4) && layout->move_count >= 0
        && read_value(&reader, layout->aliases, sizeof layout->aliases)
        && read_slice(&reader, &layout->moves, (uint32_t)layout->move_count, MOVE_FILE_BYTES) && read_tables(&reader, layout);
}

// Every table ends with one zero record: a scan that runs one entry past the list reads zeros.
static size_t table_bytes(uint32_t count, size_t size) { return ((size_t)count + 1) * size; }

bool t5_motbin_storage(T5Bytes file, size_t *bytes) {
    Layout layout;
    if (!read_layout(file, &layout)) return false;  // fail if the file is not a valid move file
    *bytes = t5_arena_round(table_bytes(layout.moves.count, sizeof(T5Move)));
    for (size_t index = 0; index < TABLE_COUNT; index++)
        if (layout.table[index].records) *bytes += t5_arena_round(table_bytes(layout.table[index].count, tables[index].size));
    return true;
}

int32_t t5_motbin_move_count(T5Bytes bytes) {
    Layout layout;
    return read_layout(bytes, &layout) ? layout.move_count : -1;  // -1 when the file is not valid
}

static void *copy_into(T5Arena *arena, Slice from, size_t size) {
    uint8_t *destination = t5_arena_take(arena, table_bytes(from.count, size));
    if (!destination) return NULL;
    memcpy(destination, from.records, from.count * size);
    memset(destination + from.count * size, 0, size);  // zero end record, so scans past the last entry read zeros
    return destination;
}

static T5Move *copy_moves(T5Arena *arena, const Layout *layout) {
    T5Move *moves = t5_arena_take(arena, table_bytes(layout->moves.count, sizeof(T5Move)));
    if (!moves) return NULL;
    memset(moves, 0, table_bytes(layout->moves.count, sizeof(T5Move)));  // start with all zero, so missing hit data stays zero
    const T5HitPair *pairs = (const T5HitPair *)layout->hit_pairs.records;
    const T5MoveHits *hits = (const T5MoveHits *)layout->hits.records;
    for (uint32_t index = 0; index < layout->moves.count; index++) {  // loop through moves and fill each from the file
        memcpy(&moves[index], layout->moves.records + (size_t)index * MOVE_FILE_BYTES, MOVE_FILE_BYTES);
        if (pairs && layout->hit_pairs.count >= 2 * (index + 1))  // the file has the two hit pairs of this move
            memcpy(moves[index].hit_pair, pairs + 2 * index, sizeof moves[index].hit_pair);
        if (hits && layout->hits.count > index) memcpy(&moves[index].hits, hits + index, sizeof moves[index].hits);
    }
    return moves;
}

int t5_motbin_parse(T5Motbin *motbin, T5Bytes bytes, T5Arena *arena) {
    memset(motbin, 0, sizeof *motbin);  // clear the output first
    Layout layout;
    if (!read_layout(bytes, &layout)) return -1;
    motbin->move_count = layout.move_count;  // keep the move count
    memcpy(motbin->aliases, layout.aliases, sizeof motbin->aliases);
    memcpy(motbin->alias_defaults, layout.aliases, sizeof layout.aliases);
    motbin->moves = copy_moves(arena, &layout);  // copy the moves in
    if (!motbin->moves) return -1;
    for (size_t index = 0; index < TABLE_COUNT; index++) {  // loop through the optional tables
        if (!layout.table[index].records) continue;  // skip tables the file does not have
        void **items = (void **)((char *)motbin + tables[index].offset_items);
        if (!(*items = copy_into(arena, layout.table[index], tables[index].size))) return -1;
        *(int32_t *)((char *)motbin + tables[index].offset_count) = (int32_t)layout.table[index].count;
    }
    return 0;
}

const uint16_t t5_default_pushback[14] = {T5_ALIAS_LAUNCH, 440, 0, 0, 0, 0, 100, 50, 10, 0, 0, 0, 0, 0};
