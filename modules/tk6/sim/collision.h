// Collision: the joint spheres of a fighter against the stage walls (wall.c), the floor polygon
// (floor.c) and the push that keeps the fighters apart (body_push.c).
#ifndef T6_COLLISION_H
#define T6_COLLISION_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/vec.h"
#include "sim/world.h"

// --- walls (wall.c)

typedef struct {
    T6Mat4 corners;
    T6Vec4 normal;
    int32_t surface;  // index into T6Stage.surfaces
} T6WallQuad;

// The point of the plane (plane_normal through on_plane) that is nearest to `point`, w = 1.
T6Vec4 t6_plane_project(T6Vec4 plane_normal, T6Vec4 on_plane, T6Vec4 point);

// Where the line from `before` to `now` crosses the plane (plane_normal through on_plane). The normal is
// normalized again, and the caller goes on with that unit vector.
typedef struct { T6Vec4 point, normal; } T6PlaneHit;
T6PlaneHit t6_plane_intersect(T6Vec4 plane_normal, T6Vec4 on_plane, T6Vec4 now, T6Vec4 before);

// Is `point` inside the quad seen along `normal`: at least WALL_MIN_HEIGHT tall, and point.x between its sides.
bool t6_wall_span(const T6Mat4 *quad, T6Vec4 normal, T6Vec4 point, float stage_depth);

// A sphere of the fighter (see WALL_SPHERES in wall.c; the neck has the wider radius) moving to `point` against a quad.
bool t6_wall_test(const T6Fighter *f, const T6WallQuad *quad, T6Vec4 point, int32_t sphere, float stage_depth);
// The same, and when the sphere crosses the quad: the point it is pushed to, and the contact recorded in the fighter.
typedef struct { bool hit; T6Vec4 position; } T6WallHit;
T6WallHit t6_wall_push(T6Fighter *f, const T6WallQuad *quad, T6Vec4 point, int32_t sphere, float stage_depth);

void t6_wall_clear(T6Fighter *f);  // reset f's wall contacts, wall bits and new stage hits
// Solves the six joint spheres of f against the walls of w->stage; writes f->wall_push and previous_sphere.
void t6_wall_solve(T6World *w, T6Fighter *f);
// Adds the wall push to the position of each fighter; a linked pair (a throw, or a flag) takes the longer of its two.
void t6_wall_apply(T6World *w);

// --- floor (floor.c)

typedef struct {
    T6Vec3 normal;  // as stored, not unit: the plane is solved for y with it
    int32_t surface;  // index into T6Stage.surfaces
    int32_t count;
    const T6Vec4 *vertices;
} T6FloorPolygon;

// If `position` is inside the polygon in the ground plane, the height of its plane there.
typedef struct { bool inside; float y; } T6FloorHeight;
T6FloorHeight t6_floor_polygon_y(const T6Vec4 *point, const T6FloorPolygon *poly);  // the area test and the plane height
// raise height to the floor under point, if point is inside
float t6_floor_polygon(float height, const T6Vec4 *point, const T6FloorPolygon *poly);

// --- body push (body_push.c)

void t6_push_init(T6Fighter *f);  // push spheres to the base position, no throw softening
void t6_previous_root(T6Fighter *f);  // save the base position as the previous root
void t6_push_radii(const T6World *w, T6Fighter *f);  // radii of the push spheres, from the move and state
void t6_previous_root_pass(T6World *w);  // previous root of each fighter and extra
void t6_radii_pass(T6World *w);  // push and hurtbox radii of every object (only fighters get them)

// The push of one pair of fighters in the ground plane. `settled`: the bodies overlap and do not cross, so both
// fighters take `counter` as their softening counter (frames left in which a throw softens the push).
typedef struct { float x, z; } T6Push;
typedef struct { T6Push first, second; bool settled; int16_t counter; } T6PairPush;
T6PairPush t6_push_pair(const T6World *w, const T6Fighter *first, const T6Fighter *second);

// The pairs of fighters in index order, the pushes of a fighter summed and applied once.
void t6_push_pass(T6World *w);
void t6_clear_push_pass(T6World *w);  // clear push flags; fighters in a throw and their partners are not pushed

#endif
