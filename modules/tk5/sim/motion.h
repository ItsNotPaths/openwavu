// Root and relative angles, the root passes and the juggle launch (code-map §7). The turns toward the opponent are in facing.h.
#ifndef T5_MOTION_H
#define T5_MOTION_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/world.h"

typedef struct T5Reaction T5Reaction;

float t5_turn_positive(float angle);  // wraps into [-pi, pi], then [0, 2pi)
void t5_relative_angles(const T5World *w, T5Fighter *f, const T5Fighter *opponent);  // angle to opponent, and which side is hit
void t5_face_angles(const T5World *w, T5Fighter *f, const T5Fighter *opponent);  // yaw from facing, turned or look, then relative
void t5_angles_pass(T5World *w);
void t5_root_matrix_pass(T5World *w);  // root matrix copy, base position as translation
void t5_root_delta_pass(T5World *w);  // base movement since last frame, per object
// Send the defender up into a juggle: the velocity away and up, the frame its reaction move starts at, the
// pushback.
void t5_juggle_launch(const T5World *w, T5Fighter *defender, const T5Reaction *reaction);

#endif
