// Stage collision: floor polygons, wall quads, the surfaces they are made of, and the start points. Flat lists in
// file order; every query tests all of them. load.c reads them from a stage's collision glb and .surfaces file.
#ifndef T6_STAGE_H
#define T6_STAGE_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/collision.h"
#include "sim/memory.h"
#include "sim/world.h"

// The layers of a floor surface: the floor under the fighters, and lists 1..6 that the special queries name (bit n).
enum : uint32_t { T6_LAYER_FLOOR = 1 << 0 };
enum { T6_LAYER_LISTS = 6 };

enum { T6_MATERIAL_OBJECT_FLOOR = 9 };  // the special floor of the limbs

typedef struct {
    uint32_t layers;      // T6_LAYER_FLOOR and lists 1..6; walls have none
    int32_t material;     // ground kind
    int32_t hit_event;    // a wall contact counts as a stage hit of this id; 0: none
    int32_t break_power;  // downward hits it takes before it breaks; 0: never breaks
} T6Surface;

typedef struct { T6Vec3 position; float turn; } T6StartPoint;  // turn: radians about y
typedef struct { int32_t count; const T6StartPoint *points; } T6StartList;
enum { T6_START_SIDE_1, T6_START_SIDE_2, T6_START_ENTRANCE, T6_START_LISTS };  // side 1 and 2 share record indexes

// The stage the sim reads through w->stage. Every world has one (host_stage_flat builds a flat one).
struct T6Stage {
    const T6Surface *surfaces;
    int32_t surface_count;
    const T6FloorPolygon *floors;
    int32_t floor_count;
    const T6WallQuad *walls;
    int32_t wall_count;
    T6StartList start[T6_START_LISTS];
    bool infinite;  // no walls and a flat floor at 0 (the game's stage mode 2); the fighters walk on forever
    float arena_radius, arena_pull_in;  // fighters further apart than the pull-in distance are pulled onto the ring; mm
};

// The floor queries on w->stage. They read w's stage_depth, floor_disabled and stage_state.
float t6_stage_floor(const T6World *w, T6Vec3 point);
typedef struct { float y; int32_t material; } T6StageHeight;  // material 0 when no floor is found
T6StageHeight t6_stage_height(const T6World *w, T6Vec3 point);  // highest floor-layer polygon, -depth when none
float t6_stage_special(const T6World *w, T6Vec3 point, int32_t list);  // highest floor in the list; list 1: object floor if set
float t6_stage_lowest(const T6World *w, T6Vec3 point, int32_t list);  // lowest in the list; floor off: disabled ceiling

// The stage of a collision glb and its .surfaces JSON (stage_file.c), copied into `arena`. A null arena only sets
// `bytes`, the arena bytes it takes. NULL on success, else what is wrong.
const char *t6_stage_parse(T6Stage *stage, T6Bytes collision, T6Bytes surfaces, T6Arena *arena, size_t *bytes);

#endif
