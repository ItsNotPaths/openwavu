#include "sim/world.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/pose.h"
#include "sim/vec.h"

int32_t t5_extra_count(const T5World *w) { return w->extra_count; }

T5Fighter *t5_extra_entry(const T5World *w, int32_t extra) { return &w->extras[extra]; }

uint32_t t5_fighter_order(const T5World *w) { return w->frame & 1; }

T5TurnOrder t5_turn_order(const T5World *w) {
    if (t5_fighter_order(w) != 0) return (T5TurnOrder){w->fighters[0], w->fighters[1]};  // odd frames: P1 goes first
    return (T5TurnOrder){w->fighters[1], w->fighters[0]};  // even frames: P2 goes first
}

void t5_each_extra(T5World *w, void (*visit)(T5World *w, T5Fighter *f)) {
    for (int32_t extra = 0; extra < t5_extra_count(w); extra++) visit(w, t5_extra_entry(w, extra));  // call visit for each extra
}

void t5_each_object(T5World *w, void (*visit)(T5World *w, T5Fighter *f)) {
    for (int side = 0; side < 2; side++) visit(w, w->fighters[side]);  // visit both fighters
    t5_each_extra(w, visit);  // then the extras
}

T5Fighter *t5_object(const T5World *w, int32_t index) {
    if (index < 0) return NULL;  // -1 is none
    if (index < 2) return w->fighters[index];  // 0 and 1 are the fighters
    return &w->extras[index - 2];  // the rest are extras, offset by 2
}

int32_t t5_object_index(const T5World *w, const T5Fighter *f) {
    for (int index = 0; index < 2; index++)  // look for f among the two fighters
        if (w->fighters[index] == f) return index;
    if (w->extras && f >= w->extras && (uint32_t)(f - w->extras) < w->extra_count)  // or in the extras table
        return 2 + (int32_t)(f - w->extras);
    return -1;  // not an object
}

int32_t t5_floor_disabled(const T5World *w) { return w->floor_disabled; }

static float base_distance(const T5Fighter *first, const T5Fighter *second) {  // flat distance between two base positions
    return t5_length_xz(first->base_position.x - second->base_position.x, first->base_position.z - second->base_position.z);
}

// The tail of the decide passes. The body of a fighter can shorten the throw range of both.
static void set_fighter_distances(T5World *w, float distance) {
    T5Fighter *first = w->fighters[0], *second = w->fighters[1];
    float cut = first->body.throw_range_cut + second->body.throw_range_cut;  // total throw range cut from both bodies
    float range = distance - cut;  // throw range is the distance less the cut
    if (range < 0.0f) range = 0.0f;  // never negative
    first->distance = second->distance = distance;  // both fighters store the distance
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {  // give each opponent slot the throw range
        first->throw.target[side].range = range;
        second->throw.target[side].range = range;
    }
}

void t5_distance_pass(T5World *w) {
    w->distance = base_distance(w->fighters[0], w->fighters[1]);  // measure the distance, keep it on the world
    set_fighter_distances(w, w->distance);  // pass it to both fighters
}

static const float ARENA_LATCH = 5487.78418f, ARENA_RADIUS = 3712.0f;  // latch: pull-in distance; radius: the arena circle

static float centre_distance(const T5World *w, const T5Fighter *f) {  // xz distance from the arena centre to f
    return t5_length_xz(f->base_position.x - w->arena_centre[0], f->base_position.z - w->arena_centre[2]);
}

// Moves f to the edge of the arena circle, on the line from the centre through f.
static void pull_in(T5World *w, T5Fighter *f) {
    const float *centre = w->arena_centre;
    float angle = t5_wrap_pi(-t5_atan2(f->base_position.z - centre[2], f->base_position.x - centre[0]));  // angle from centre
    T5Mat4 turn;
    t5_mat_identity(&turn);  // start with no turn
    t5_mat_rotate_y(&turn, t5_rad_to_angle_round(angle));  // turn by the angle about y
    memcpy(turn.m[3], centre, 3 * sizeof(float));  // the turn's origin is the centre
    T5Vec4 edge = {{ARENA_RADIUS, 0.0f, 0.0f, 1.0f}}, out;  // a point on the edge circle, out along x
    t5_vec_times_mat(&out, &edge, &turn);  // turn the edge point to its place on the circle
    float offset_x = out.x - f->base_position.x;  // step from f to the edge point
    float offset_z = out.z - f->base_position.z;
    f->base_position.x = f->base_position.x + offset_x;
    f->base_position.z = f->base_position.z + offset_z;
    f->position.x = f->position.x + offset_x;  // the drawn position moves too
    f->position.z = f->position.z + offset_z;
    t5_root_from_base(f);  // copy the new base into the root matrix
}

static void measure_object(const T5World *w, T5Fighter *object) {
    object->distance = base_distance(w->fighters[0], object);  // distance from the first fighter to this object
    object->throw.target[0].range = object->distance;  // first fighter's throw range to it is that distance
    object->distance2 = base_distance(w->fighters[1], object);  // distance from the second fighter to this object
    object->throw.target[1].range = w->stage_depth;  // stage depth marks it out of range
}

// G_dist is the distance before the clamp, and stays so.
void t5_arena_pass(T5World *w) {
    T5Fighter *first = w->fighters[0], *second = w->fighters[1];
    float distance = w->distance = base_distance(first, second);  // measure the distance and keep it on the world
    if (t5_phase_row(w).arena) {  // only in phases where the arena holds fighters together
        if (distance > ARENA_LATCH) {  // far apart: pull fighters outside the circle onto its edge
            if (centre_distance(w, first) > ARENA_RADIUS) pull_in(w, first);  // pull first onto the edge if outside the circle
            if (centre_distance(w, second) > ARENA_RADIUS) pull_in(w, second);
        } else {  // close: centre the arena between the fighters
            float *centre = w->arena_centre;
            centre[0] = (first->base_position.x + second->base_position.x) * 0.5f;  // centre is the midpoint of the two fighters
            centre[1] = 0.0f;
            centre[2] = (first->base_position.z + second->base_position.z) * 0.5f;
            centre[3] = 1.0f;
        }
    }
    set_fighter_distances(w, distance);  // pass the distance to both fighters
    for (int32_t index = 0; index < t5_extra_count(w); index++) measure_object(w, t5_extra_entry(w, index));  // measure extras
}

typedef struct { T5World *w; const T5Fighter *f; } SourceCall;  // world and fighter for one input call

static T5StdInput cpu_source(void *context) {
    const SourceCall *call = context;
    return call->w->input_sources.cpu(call->w->input_sources.context, call->f);  // ask the CPU source for this fighter's input
}

static T5StdInput script_source(void *context) {
    const SourceCall *call = context;
    return call->w->input_sources.script(call->w->input_sources.context, call->f);  // ask the script for this fighter's input
}

// The game reads the pad, pause, health and opponent itself; the port gathers them in the env.
static T5InputEnv input_env(T5World *w, T5Fighter *f, SourceCall *call) {
    *call = (SourceCall){w, f};  // record the world and fighter for the callbacks
    return (T5InputEnv){
        .pad = w->fighters[f->slot & 1]->standard_input,  // the pad of the fighter at this slot
        .unpause = w->unpause,
        .ko = f->health == 0,  // knocked out when health is zero
        .cpu = {w->input_sources.cpu ? cpu_source : NULL, call},  // CPU source only if the world has one
        .script = {w->input_sources.script ? script_source : NULL, call},
    };
}

static void input_of(T5World *w, T5Fighter *f) {
    SourceCall call;
    T5InputEnv env = input_env(w, f, &call);
    t5_input_frame(&f->input, f->kind == 0 ? &f->history : NULL, &env);  // run one input frame; only fighters keep history
}

const T5Fighter *t5_human_player(const T5World *w) {
    if (t5_input_pad_driven(&w->fighters[0]->input)) return w->fighters[0];  // P1 if P1 is on a pad
    return w->fighters[1];  // else P2
}

void t5_input_sample_of(T5World *w, T5Fighter *f) {
    SourceCall call;
    T5InputEnv env = input_env(w, f, &call);
    t5_input_sample(&f->input, f->kind == 0 ? &f->history : NULL, &env);  // sample one input; only fighters keep history
}

void t5_input_pass(T5World *w) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) input_of(w, w->fighters[side]);  // read input for both fighters
}
