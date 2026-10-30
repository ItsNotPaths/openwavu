// Collision (code-map section 8): the joint spheres of a fighter against the stage walls (wall.c), the floor polygon
// (floor.c) and the push that keeps the fighters apart (body_push.c).
#ifndef T5_COLLISION_H
#define T5_COLLISION_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/vec.h"
#include "sim/world.h"

// --- walls (wall.c)

typedef struct { T5Mat4 corners; T5Vec4 normal; } T5WallQuad;

// A wall object (quads of type 3 or 9). `effect`: its stage object record has an effect slot, so a
// contact counts as a stage object hit (the effect itself is not simulated).
typedef struct {
    const T5WallQuad *quads;
    int32_t quad_count;
    bool effect;
    uint32_t id;
} T5WallObject;

// The point of the plane (plane_normal through on_plane) that is nearest to `point`, w = 1.
T5Vec4 t5_plane_project(T5Vec4 plane_normal, T5Vec4 on_plane, T5Vec4 point);

// Where the line from `before` to `now` crosses the plane (plane_normal through on_plane). The normal is
// normalized again, and the caller goes on with that unit vector.
typedef struct { T5Vec4 point, normal; } T5PlaneHit;
T5PlaneHit t5_plane_intersect(T5Vec4 plane_normal, T5Vec4 on_plane, T5Vec4 now, T5Vec4 before);

// Is `point` inside the quad seen along `normal`: at least WALL_MIN_HEIGHT tall, and point.x between its sides.
bool t5_wall_span(const T5Mat4 *quad, T5Vec4 normal, T5Vec4 point, float stage_depth);

// A sphere of the fighter (see WALL_SPHERES in wall.c; the neck has the wider radius) moving to `point` against a quad.
bool t5_wall_test(const T5Fighter *f, const T5WallQuad *quad, T5Vec4 point, int32_t sphere, float stage_depth);
// The same, and when the sphere crosses the quad: the point it is pushed to, and the contact recorded in the fighter.
typedef struct { bool hit; T5Vec4 position; } T5WallHit;
T5WallHit t5_wall_push(T5Fighter *f, const T5WallQuad *quad, T5Vec4 point, int32_t sphere, float stage_depth);

void t5_wall_clear(T5Fighter *f);  // reset f's wall contacts, wall bits and new stage hits
// Solves the six joint spheres of f against the walls of w->stage; writes f->wall_push and previous_sphere.
void t5_wall_solve(T5World *w, T5Fighter *f);
// Adds the wall push to the position of each fighter; a linked pair (a throw, or a flag) takes the longer of its two.
void t5_wall_apply(T5World *w);

// --- floor (floor.c)

typedef struct {
    T5Vec3 centre;
    float radius2;
    T5Vec3 normal;
    int32_t count;
    T5Vec4 vertices[];
} T5FloorPolygon;

// If `position` is inside the polygon in the ground plane, the height of its plane there.
typedef struct { bool inside; float y; } T5FloorHeight;
T5FloorHeight t5_floor_polygon_y(const T5Vec4 *point, const T5FloorPolygon *poly);  // the area test and the plane height
// raise height to the floor under point, if point is inside
float t5_floor_polygon(float height, const T5Vec4 *point, const T5FloorPolygon *poly);

// --- body push (body_push.c)

void t5_push_init(T5Fighter *f);  // push spheres to the base position, no throw softening
void t5_previous_root(T5Fighter *f);  // save the base position as the previous root
void t5_push_radii(const T5World *w, T5Fighter *f);  // radii of the push spheres, from the move and state
void t5_previous_root_pass(T5World *w);  // previous root of each fighter and extra
void t5_push_radii_pass(T5World *w);  // push radii of every object (only fighters get them)

// The push of one pair of fighters in the ground plane. `settled`: the bodies overlap and do not cross, so both
// fighters take `counter` as their softening counter (frames left in which a throw softens the push).
typedef struct { float x, z; } T5Push;
typedef struct { T5Push first, second; bool settled; int16_t counter; } T5PairPush;
T5PairPush t5_push_pair(const T5World *w, const T5Fighter *first, const T5Fighter *second);

// The pairs of fighters in index order, the pushes of a fighter summed and applied once.
void t5_push_pass(T5World *w);
void t5_clear_push_pass(T5World *w);  // clear push flags; fighters in a throw and their partners are not pushed

#endif
