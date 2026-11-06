// The battle frame (normal fight branch). Each pass is a hook whose default is the
// port; a pack's sim replaces entries of t5_hooks at init and can call t5_default_hooks.
#ifndef T5_FRAME_H
#define T5_FRAME_H

#include "sim/world.h"

typedef void (*T5Pass)(T5World *w);
typedef void (*T5RoundInit)(T5World *w, T5RoundSetup setup);

typedef struct {
    T5Pass frame;          // runs the passes below in this order
    T5Pass round;          // round flow (the phase table, round.c)
    T5Pass side_latch;
    T5Pass side;           // for both fighters
    T5Pass hitbox_starts;  // starts each fighter's hitboxes for the current move
    T5Pass apply_moves;
    T5Pass clear_push;  // clears each fighter's push flags
    T5Pass props_logic;
    T5Pass distance;  // sets the gap between the two fighters
    T5Pass movement;  // moves the fighters; they stand still while frozen
    T5Pass save_root;  // remembers each fighter's root from last frame
    T5Pass motion;
    T5Pass angles;  // works out each fighter's angles to the opponent
    T5Pass root_matrix;
    T5Pass arena;  // centres the arena between the fighters; when far apart, pulls them back inside its edge
    T5Pass props_effects;
    T5Pass root_delta;
    T5Pass hurtboxes;  // sets each fighter's hurt areas for the current move
    T5Pass push_radii;  // sets each fighter's body radius for pushing
    T5Pass push_solve;  // pushes overlapping fighters apart
    T5Pass hit_clear;  // clears last frame's hit records
    T5Pass hit_detect;  // attacks that reach the other fighter land a hit
    T5Pass attack_direction;
    T5Pass reversals;
    T5Pass clear_results;  // clears last frame's results (ko, guard, counter hit)
    T5Pass damage;  // applies this frame's hits as damage
    T5Pass input;  // reads the pads only in phases that take input
    T5Pass decide;
    // after the passes: round rules (the entries above keep their positions)
    T5RoundInit round_init;  // round init, called as a phase begins (t5_round_begin)
    T5Pass reset_models;   // of both fighters, then the model, blend and push start of a round init
    T5Pass voice_clips;    // runs after decide: the voice clip cues
} T5Hooks;

extern const T5Hooks t5_default_hooks;
extern T5Hooks t5_hooks;  // starts as the defaults; set only at init

void t5_battle_frame(T5World *w);

#endif
