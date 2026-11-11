// The battle frame (normal fight branch). Each pass is a hook whose default is the
// port; a pack's sim replaces entries of t6_hooks at init and can call t6_default_hooks.
#ifndef T6_FRAME_H
#define T6_FRAME_H

#include "sim/world.h"

typedef void (*T6Pass)(T6World *w);
typedef void (*T6RoundInit)(T6World *w, T6RoundSetup setup);

typedef struct {
    T6Pass frame;          // runs the passes below in this order
    T6Pass round;          // round flow (the phase table, round.c)
    T6Pass side_latch;
    T6Pass side;           // for both fighters
    T6Pass hitbox_starts;  // starts each fighter's hitboxes for the current move
    T6Pass apply_moves;
    T6Pass clear_push;  // clears each fighter's push flags
    T6Pass props_logic;
    T6Pass distance;  // sets the gap between the two fighters
    T6Pass movement;  // moves the fighters; they stand still while frozen
    T6Pass save_root;  // remembers each fighter's root from last frame
    T6Pass motion;
    T6Pass angles;  // works out each fighter's angles to the opponent
    T6Pass root_matrix;
    T6Pass arena;  // centres the arena between the fighters; when far apart, pulls them back inside its edge
    T6Pass props_effects;
    T6Pass root_delta;
    T6Pass hurtboxes;  // sets each fighter's hurt areas for the current move
    T6Pass push_radii;  // sets each fighter's body radius for pushing
    T6Pass push_solve;  // pushes overlapping fighters apart
    T6Pass hit_clear;  // clears last frame's hit records
    T6Pass hit_detect;  // attacks that reach the other fighter land a hit
    T6Pass attack_direction;
    T6Pass reversals;
    T6Pass clear_results;  // clears last frame's results (ko, guard, counter hit)
    T6Pass damage;  // applies this frame's hits as damage
    T6Pass input;  // reads the pads only in phases that take input
    T6Pass decide;
    // after the passes: round rules (the entries above keep their positions)
    T6RoundInit round_init;  // round init, called as a phase begins (t6_round_begin)
    T6Pass reset_models;   // of both fighters, then the model, blend and push start of a round init
    T6Pass voice_clips;    // runs after decide: the voice clip cues
} T6Hooks;

extern const T6Hooks t6_default_hooks;
extern T6Hooks t6_hooks;  // starts as the defaults; set only at init

void t6_battle_frame(T6World *w);

#endif
