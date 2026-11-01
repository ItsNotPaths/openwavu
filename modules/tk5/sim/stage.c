#include "sim/stage.h"

#include <math.h>

static const uint32_t LIST_BIT[7] = {0, T5_ZONE_LIST_1, T5_ZONE_LIST_2, T5_ZONE_LIST_3, T5_ZONE_LIST_4, T5_ZONE_LIST_5, T5_ZONE_LIST_6};
// The masks that ask for the highest floor, and for the lowest (the ceiling)
static constexpr uint32_t FLOOR_MASK = T5_ZONE_FLOOR | T5_ZONE_LIST_1 | T5_ZONE_LIST_2 | T5_ZONE_LIST_3 | T5_ZONE_LIST_4;
static constexpr uint32_t CEILING_MASK = T5_ZONE_LIST_5 | T5_ZONE_LIST_6;

// The first ground flag of a zone, in this order, gives its ground kind (bits 24..27 of the flags). The flags of
// the kinds leave the word. A zone with none has kind 11, or 12 without GROUND_KIND_ROOM.
enum { GROUND_KIND_NONE = 11, GROUND_KIND_NONE_LOW = 12 };
enum : uint32_t { GROUND_KIND_ROOM = 1 << 17 };
static const struct { uint32_t flags; uint32_t kind; } GROUND_KINDS[] = {
    {1 << 2, 1}, {(1 << 3) | (1 << 4), 2}, {1 << 5, 4}, {1 << 6, 5}, {1 << 7, 6}, {1 << 8, 7}, {1 << 9, 8}, {1 << 10, 9}, {1 << 11, 10},
};
static constexpr uint32_t GROUND_KIND_SOURCES = ((1 << 12) - 1) & ~(uint32_t)3;  // bits 2..11, with GROUND_KIND_ROOM

uint32_t t5_ground_kind_flags(uint32_t flags) {
    uint32_t kind = GROUND_KIND_NONE;  // start with the kind for a zone with no ground flag
    if (!(flags & GROUND_KIND_ROOM)) kind = GROUND_KIND_NONE_LOW;  // no room flag, so use the lower no-ground kind
    for (size_t index = 0; index < sizeof GROUND_KINDS / sizeof *GROUND_KINDS; index++) {  // check each ground flag group
        if (!(flags & GROUND_KINDS[index].flags)) continue;  // this ground type is not set, try the next
        kind = GROUND_KINDS[index].kind;  // first match wins
        break;
    }
    return (flags & ~(GROUND_KIND_SOURCES | GROUND_KIND_ROOM)) | (kind << T5_GROUND_KIND_SHIFT);  // clear source flags, set kind
}

static bool in_range(const T5Vec4 *position, T5Vec3 centre, float radius_squared) {
    T5Vec4 sphere = vec4_of(centre, radius_squared), offset;  // flat circle test on the ground plane, offset from the centre
    t5_vec_subtract(&offset, position, &sphere);
    return radius_squared >= fmaf(offset.x, offset.x, offset.z * offset.z);  // inside when x/z distance is within radius
}

static const T5FloorPolygon *next_polygon(const T5FloorPolygon *polygon) {  // polygons sit back to back, step past the vertices
    return (const T5FloorPolygon *)&polygon->vertices[polygon->count];
}

// The zone test: a zone of one polygon skips the polygon sphere.
static bool polygon_counts(const T5StageZone *zone, const T5Vec4 *position, const T5FloorPolygon *polygon) {
    return zone->polygon_count == 1 ||  // one-polygon zones skip the circle test
           in_range(position, polygon->centre, polygon->radius2);
}

// loop over the zone polygons, keeping only those near the point
#define EACH_POLYGON(zone, position, polygon)                                                           \
    const T5FloorPolygon *polygon = (zone)->polygons;                                                   \
    for (int32_t index_ = 0; index_ < (zone)->polygon_count; index_++, polygon = next_polygon(polygon)) \
        if (polygon_counts(zone, position, polygon))  // only polygons near the point

// The zones with flag 1, last first (the stage load pushes each on the list head).
float t5_stage_floor(const T5World *w, T5Vec3 point) {
    float depth = w->stage_depth, height = -depth;  // start at the very bottom of the stage
    if (t5_floor_disabled(w)) return 0.0f;  // floor is switched off, so the ground is flat at zero
    T5Vec4 position = vec4_of(point, 0.0f);
    for (int32_t zone_index = w->stage->zone_count - 1; zone_index >= 0; zone_index--) {  // zones from last to first
        const T5StageZone *zone = &w->stage->zones[zone_index];
        if (!(zone->flags & T5_ZONE_FLOOR) ||  // skip non-floor zones and zones far from the point
            !in_range(&position, zone->centre, zone->radius2)) continue;
        EACH_POLYGON(zone, &position, polygon) height = t5_floor_polygon(height, &position, polygon);
    }
    return height == -depth ? 0.0f : height;  // no floor found under the point, use zero
}

// The highest (FLOOR_MASK) or the lowest floor under the point among the zones with a flag of mask, with the
// flags of that zone. The floor height is mask T5_ZONE_FLOOR.
T5StageHeight t5_stage_height(const T5World *w, T5Vec3 point, uint32_t mask) {
    float depth = w->stage_depth;
    if (t5_floor_disabled(w)) {
        uint32_t kind = 0;  // floor is off: only an object floor can set the ground kind
        if (w->stage_state.object_floor)  // a stage object is acting as the floor
            kind = (uint32_t)T5_GROUND_KIND_OBJECT_FLOOR << T5_GROUND_KIND_SHIFT;
        if (mask & FLOOR_MASK) return (T5StageHeight){0.0f, kind};  // floor query: flat zero
        if (mask & CEILING_MASK)  // ceiling query: use the stored disabled ceiling
            return (T5StageHeight){w->stage_state.disabled_ceiling, kind};
    }
    float high = -depth, low = depth;  // track the highest and lowest surface found
    uint32_t high_flags = 0, low_flags = 0;
    T5Vec4 position = vec4_of(point, 0.0f);
    for (int32_t zone_index = 0; zone_index < w->stage->zone_count; zone_index++) {  // walk all zones
        const T5StageZone *zone = &w->stage->zones[zone_index];
        if (!(mask & zone->flags) ||  // skip zones not in the mask or far away
            !in_range(&position, zone->centre, zone->radius2)) continue;
        EACH_POLYGON(zone, &position, polygon) {
            T5FloorHeight under = t5_floor_polygon_y(&position, polygon);  // height of this polygon under the point
            if (!under.inside) continue;  // point is not over this polygon
            float y = under.y;
            if (high < y) high = y, high_flags = zone->flags;  // new highest surface, keep its zone flags
            if (y < low) low = y, low_flags = zone->flags;  // new lowest surface, keep its zone flags
        }
    }
    if (mask & FLOOR_MASK) return (T5StageHeight){high, high_flags};  // floor queries want the highest, ceilings the lowest
    return (T5StageHeight){low, low_flags};
}

// The highest floor of the zones of list `type`. Type 1 is a stage object's floor when it has one.
float t5_stage_special(const T5World *w, T5Vec3 point, int32_t type) {
    float height = -w->stage_depth;
    if (type == 1 && w->stage_state.object_floor) return w->stage_state.object_floor_y;  // a stage object floor overrides list 1
    if (t5_floor_disabled(w)) return 0.0f;  // floor is switched off, so the ground is flat at zero
    if (type < 1 || type > 6) return height;  // unknown list: report the bottom of the stage
    T5Vec4 position = vec4_of(point, 0.0f);
    for (int32_t zone_index = 0; zone_index < w->stage->zone_count; zone_index++) {  // walk all zones
        const T5StageZone *zone = &w->stage->zones[zone_index];
        if (!(zone->flags & LIST_BIT[type]) || !in_range(&position, zone->centre, zone->radius2)) continue;
        EACH_POLYGON(zone, &position, polygon) height = t5_floor_polygon(height, &position, polygon);
    }
    return height;
}

// the floor polygon with the lowest height
static float polygon_lowest(float height, const T5Vec4 *position, const T5FloorPolygon *polygon) {
    T5FloorHeight under = t5_floor_polygon_y(position, polygon);
    if (under.inside && under.y < height) height = under.y;  // lower than the best so far, keep it
    return height;
}

// The lowest floor of the zones of list `type`.
float t5_stage_lowest(const T5World *w, T5Vec3 point, int32_t type) {
    float height = w->stage_depth;
    if (t5_floor_disabled(w)) return w->stage_state.disabled_ceiling;  // floor is off, so use the stored ceiling
    if (type < 1 || type > 6) return height;  // unknown list: report the bottom of the stage
    T5Vec4 position = vec4_of(point, 0.0f);
    for (int32_t zone_index = 0; zone_index < w->stage->zone_count; zone_index++) {  // walk all zones
        const T5StageZone *zone = &w->stage->zones[zone_index];
        if (!(zone->flags & LIST_BIT[type]) || !in_range(&position, zone->centre, zone->radius2)) continue;
        EACH_POLYGON(zone, &position, polygon) height = polygon_lowest(height, &position, polygon);
    }
    return height;
}

enum { OBJECT_WALL_A = 3, OBJECT_FLOOR_CELL = 6, OBJECT_WALL_B = 9 };  // T5StageObject.type

// Does the cell (centre cell_x, cell_z) touch the circle?
static bool cell_touches(float cell_x, float cell_z, T5Vec3 circle, float radius, float cell) {
    float half = cell * 0.5f;
    float gap_x = fabsf(circle.x - cell_x);
    float gap_z = fabsf(circle.z - cell_z);
    float reach = half + radius;
    if (half >= gap_x) return reach >= gap_z;  // circle centre is level with the cell on x, so only z reach matters
    if (half >= gap_z) return reach >= gap_x;  // circle centre is level with the cell on z, so only x reach matters
    float corner = radius + sqrtf(half * half + half * half);  // circle is diagonal to the cell, test against the corner distance
    return corner * corner >= fmaf(gap_x, gap_x, gap_z * gap_z);
}

// Cell index of a distance from the grid origin: clamped to the grid.
static int32_t cell_of(float distance, float cell, int32_t count) {
    if (distance < 0.0f || distance != distance) return 0;  // before the grid or not a number: first cell
    if (distance >= cell * (float)count) return count - 1;  // past the grid: last cell
    return (int32_t)(distance / cell);
}

// with a sphere query: the objects of the cells that touch the circle, z rows then x, each cell in list
// order. Duplicates drop out and the list stops at 255, floor cells (type 6) take room too. Only the wall kinds are
// returned (the wall pass keeps types 3 and 9). The object matrices are the identity.
// (hole wall-grid-drop :tags (tk5mod port) :sev polish) rewrite: the grid only saves time; test every wall object in object order (floor off still means no walls). Changes the push order at corners, a fraction of an inch; gate with the oracle and the scenarios.
T5StageWalls t5_stage_walls(const T5World *w, T5Vec3 centre, float radius) {
    const T5Stage *s = w->stage;
    T5StageWalls found = {};
    if (t5_floor_disabled(w)) return found;  // floor off also switches the walls off: empty list
    int32_t count_x = s->grid_nx, count_z = s->grid_nz;
    float cell = s->grid_cell;
    float half = cell * 0.5f;
    float origin_x = -(half * (float)count_x);  // the grid is centred on the stage middle
    float origin_z = -(half * (float)count_z);
    float low_x = centre.x - radius;  // box around the circle
    float high_x = radius + centre.x;
    float low_z = centre.z - radius;
    float high_z = radius + centre.z;
    int32_t first_column = cell_of(low_x - origin_x, cell, count_x);  // range of grid cells the box covers
    int32_t first_row = cell_of(low_z - origin_z, cell, count_z);
    int32_t last_column = cell_of(high_x - origin_x, cell, count_x);
    int32_t last_row = cell_of(high_z - origin_z, cell, count_z);
    float first_x = fmaf(cell, (float)first_column, half + origin_x);  // centre of the first cell to test
    float row_z = fmaf(cell, (float)first_row, half + origin_z);
    uint16_t seen[T5_STAGE_RESULTS];  // objects already counted, so none repeats
    int32_t seen_count = 0;
    for (int32_t row = first_row; row <= last_row; row++, row_z += cell) {  // walk the cell rows
        float cell_x = first_x;
        for (int32_t column = first_column; column <= last_column; column++, cell_x += cell) {  // walk the cells in this row
            if (!cell_touches(cell_x, row_z, centre, radius, cell)) continue;  // skip cells the circle does not touch
            int32_t cell_index = (row >= count_z ? count_z - 1 : row) * count_x +  // cell number, rows then columns,
                                 (column >= count_x ? count_x - 1 : column);       // clamped inside the grid
            for (uint32_t entry = s->cell_start[cell_index];  // go through the objects listed in this cell
                 entry < s->cell_start[cell_index + 1]; entry++) {
                uint16_t object = s->cell_objects[entry];
                int32_t type = s->objects[object].type;
                if (type != OBJECT_WALL_A && type != OBJECT_FLOOR_CELL &&  // only wall and floor cell objects count
                    type != OBJECT_WALL_B) continue;
                bool known = false;  // has this object been seen already?
                for (int32_t seen_index = 0; seen_index < seen_count; seen_index++) known |= seen[seen_index] == object;
                if (known || seen_count >= T5_STAGE_RESULTS) continue;  // skip duplicates, or stop adding when the list is full
                seen[seen_count++] = object;  // remember this object
                if (type != OBJECT_FLOOR_CELL)  // floor cells take room but only walls are returned
                    found.object[found.count++] = object;
            }
        }
    }
    return found;
}
