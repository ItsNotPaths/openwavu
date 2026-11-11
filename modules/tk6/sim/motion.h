// Root and relative angles, the root passes and the juggle launch. The turns toward the opponent are in facing.h.
#ifndef T6_MOTION_H
#define T6_MOTION_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/world.h"

typedef struct T6Reaction T6Reaction;

float t6_turn_positive(float angle);  // wraps into [-pi, pi], then [0, 2pi)
void t6_relative_angles(const T6World *w, T6Fighter *f, const T6Fighter *opponent);  // angle to opponent, and which side is hit
void t6_face_angles(const T6World *w, T6Fighter *f, const T6Fighter *opponent);  // yaw from facing, turned or look, then relative
void t6_angles_pass(T6World *w);
void t6_root_matrix_pass(T6World *w);  // root matrix copy, base position as translation
void t6_root_delta_pass(T6World *w);  // base movement since last frame, per object
// Send the defender up into a juggle: the velocity away and up, the frame its reaction move starts at, the
// pushback.
void t6_juggle_launch(const T6World *w, T6Fighter *defender, const T6Reaction *reaction);

#endif
