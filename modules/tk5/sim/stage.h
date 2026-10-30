// Stage collision from plain arrays (the host reads the stage files; docs/stages.md). Floor zones (UNDN, section 17):
// Walls (MHO, section 15): the broadphase.
#ifndef T5_STAGE_H
#define T5_STAGE_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/collision.h"
#include "sim/world.h"

#define T5_STAGE_RESULTS 255  // the game's result list holds 255 objects

// Runtime zone flags. Bit 0 marks the zones of the floor under the fighters; floor list types 1..6 each have a
// flag. Bits 24..27 hold the ground kind (t5_ground_kind_flags).
enum : uint32_t {
    T5_ZONE_FLOOR = 1 << 0,
    T5_ZONE_LIST_5 = 1 << 1,
    T5_ZONE_LIST_1 = 1 << 12,
    T5_ZONE_LIST_2 = 1 << 13,
    T5_ZONE_LIST_6 = 1 << 14,
    T5_ZONE_LIST_3 = 1 << 15,
    T5_ZONE_LIST_4 = 1 << 16,
};
enum { T5_GROUND_KIND_SHIFT = 24, T5_GROUND_KIND_OBJECT_FLOOR = 9 };
enum : uint32_t { T5_GROUND_KIND_MASK = 15u << T5_GROUND_KIND_SHIFT };  // kind 9: the special floor of the limbs

typedef struct {
    T5Vec3 centre;  // zone sphere (x, z): points outside it skip the zone
    float radius2;
    uint32_t flags;                  // runtime flags: t5_ground_kind_flags of the stored ones
    int32_t polygon_count;
    const T5FloorPolygon *polygons;  // packed one after the other (each has its own vertex count)
} T5StageZone;

typedef struct {
    int32_t type;      // 3 and 9 hold quads (wall), 5 the grid, 6 a floor cell
    T5WallObject wall; // types 3 and 9: id = the stage object id (the link), effect = it has a link
} T5StageObject;

// Start points (sections 14 and 13, docs/stages.md 5.6): a point is the position and the rotation of a record.
typedef struct { float position[4], rotation[4]; } T5StartPoint;

typedef struct {
    int32_t id;                    // TKPD entry id, or the pair index of a POS section
    int32_t count;                 // records
    int32_t per_record;            // points per record (1, or 2 for a double record)
    const T5StartPoint *points;    // count * per_record; null if the group has none
} T5StartGroup;

typedef struct {
    bool pos_format;               // "POS " section (four pairs) or "TKPD" (entries by id)
    const T5StartGroup *groups;
    int32_t group_count;
} T5StartSlot;

// A start record the next round never takes: the nearest start pick takes `instead`. Zero: none.
typedef struct { int32_t record, instead; } T5StartSkip;

// The stage the sim reads through w->stage. Every world has one (host_stage_flat builds a flat one).
struct T5Stage {
    const T5StageZone *zones;        // file order
    int32_t zone_count;
    int32_t grid_nx, grid_nz;
    float grid_cell;
    const T5StageObject *objects;    // by MHO object index
    int32_t object_count;
    const uint32_t *cell_start;      // grid_nx * grid_nz + 1 offsets into cell_objects, cell = z * nx + x
    const uint16_t *cell_objects;    // object indexes in the order of the game's cell lists
    T5StartSlot start[2];            // section 14 (object slot 0) and section 13 (slot 1)
    T5StartSkip start_skip;          // by stage id, not in the file (host_stock_start_skip)
};

uint32_t t5_ground_kind_flags(uint32_t flags);  // the ground kind into bits 24..27

// The floor queries on w->stage. They read w's stage_depth, floor_disabled and stage_state.
float t5_stage_floor(const T5World *w, T5Vec3 point);
typedef struct { float y; uint32_t kind; } T5StageHeight;  // kind: the flags of the zone found, 0 when none
T5StageHeight t5_stage_height(const T5World *w, T5Vec3 point, uint32_t mask);  // the floor height uses mask T5_ZONE_FLOOR
float t5_stage_special(const T5World *w, T5Vec3 point, int32_t type);  // highest floor in the list; type 1: object floor if set
float t5_stage_lowest(const T5World *w, T5Vec3 point, int32_t type);  // lowest in the list; floor off: disabled ceiling

// The wall objects near a sphere, as indexes into w->stage->objects in the game's order.
typedef struct { int32_t count; uint16_t object[T5_STAGE_RESULTS]; } T5StageWalls;
T5StageWalls t5_stage_walls(const T5World *w, T5Vec3 centre, float radius);  // sphere query

// The start points (stage_start.c).
int32_t t5_stage_start_count(const T5Stage *s, int32_t table);
const float *t5_stage_start_position(const T5Stage *s, int32_t table, int32_t index);  // null when there is no such record
const float *t5_stage_start_rotation(const T5Stage *s, int32_t table, int32_t index);  // null when there is no such record

#endif
