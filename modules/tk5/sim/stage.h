// Stage collision: floor polygons, wall quads, the surfaces they are made of, and the start points. Flat lists in
// file order; every query tests all of them. load.c reads them from a stage's collision glb and .surfaces file.
// (hole slope-stage :tags (tk5mod content) :sev polish) every stock floor is flat (steps of up to 100 mm), so the slope
// code (floor planes, limb probes, hip drop twists) never runs in play; add a stage whose floor rises and falls at random.
// (hole infinite-stage :tags (port tk5mod) :sev gap) the infinite stages (no walls) wrap around in the game, by some circular logic not found yet
// (fighters and stage moved back by a period, or positions taken modulo); not ported, so a fighter can walk off the collision floor.
#ifndef T5_STAGE_H
#define T5_STAGE_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/collision.h"
#include "sim/memory.h"
#include "sim/world.h"

// The layers of a floor surface: the floor under the fighters, and lists 1..6 that the special queries name (bit n).
enum : uint32_t { T5_LAYER_FLOOR = 1 << 0 };
enum { T5_LAYER_LISTS = 6 };

enum { T5_MATERIAL_OBJECT_FLOOR = 9 };  // the special floor of the limbs

typedef struct {
    uint32_t layers;      // T5_LAYER_FLOOR and lists 1..6; walls have none
    int32_t material;     // ground kind
    int32_t hit_event;    // a wall contact counts as a stage hit of this id; 0: none
    int32_t break_power;  // downward hits it takes before it breaks; 0: never breaks
} T5Surface;

typedef struct { T5Vec3 position; float turn; } T5StartPoint;  // turn: radians about y
typedef struct { int32_t count; const T5StartPoint *points; } T5StartList;
enum { T5_START_SIDE_1, T5_START_SIDE_2, T5_START_ENTRANCE, T5_START_LISTS };  // side 1 and 2 share record indexes

// The stage the sim reads through w->stage. Every world has one (host_stage_flat builds a flat one).
struct T5Stage {
    const T5Surface *surfaces;
    int32_t surface_count;
    const T5FloorPolygon *floors;
    int32_t floor_count;
    const T5WallQuad *walls;
    int32_t wall_count;
    T5StartList start[T5_START_LISTS];
};

// The floor queries on w->stage. They read w's stage_depth, floor_disabled and stage_state.
float t5_stage_floor(const T5World *w, T5Vec3 point);
typedef struct { float y; int32_t material; } T5StageHeight;  // material 0 when no floor is found
T5StageHeight t5_stage_height(const T5World *w, T5Vec3 point);  // highest floor-layer polygon, -depth when none
float t5_stage_special(const T5World *w, T5Vec3 point, int32_t list);  // highest floor in the list; list 1: object floor if set
float t5_stage_lowest(const T5World *w, T5Vec3 point, int32_t list);  // lowest in the list; floor off: disabled ceiling

// The stage of a collision glb and its .surfaces JSON (stage_file.c), copied into `arena`. A null arena only sets
// `bytes`, the arena bytes it takes. NULL on success, else what is wrong.
const char *t5_stage_parse(T5Stage *stage, T5Bytes collision, T5Bytes surfaces, T5Arena *arena, size_t *bytes);

#endif
