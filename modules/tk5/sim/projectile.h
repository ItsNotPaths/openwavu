// Shots: the hitscan and the projectile of a character and the special points they move. The rows are named consts; the ANCH row
// of a character file picks one of each list by its place (T5BodyPoints).
#ifndef T5_PROJECTILE_H
#define T5_PROJECTILE_H

#include "sim/fighter.h"

extern const T5Hitscan T5_HITSCAN_EYE_LASER;   // Devil Jin
extern const T5Projectile T5_PROJECTILE_FIRE;  // Jinpachi

// The rows a file can pick, in the order the exporter numbers them (tools/hitpoints.py); entry 0 is none.
extern const T5Hitscan *const T5_HITSCANS[];
extern const T5Projectile *const T5_PROJECTILES[];

// The fighter's rows; NULL when it has none.
[[nodiscard]] const T5Hitscan *t5_hitscan_of(const T5Fighter *f);
[[nodiscard]] const T5Projectile *t5_projectile_of(const T5Fighter *f);

// The start point of a shot on its bone of skeleton A.
[[nodiscard]] T5Vec4 t5_shot_start(T5BodyPoint start, const T5Fighter *f);

// Two properties: the line starts growing at its start point; it stops and flies free along its line.
[[nodiscard]] T5SpecialPoints t5_hitscan_start(const T5Fighter *f, T5Hitscan row, T5SpecialScript script);
[[nodiscard]] T5SpecialPoints t5_hitscan_stop(const T5Fighter *f, T5Hitscan row);
// The line grows by its script; stopped, its tip flies free.
[[nodiscard]] T5SpecialPoints t5_hitscan_step(const T5World *w, T5SpecialPoints special);

// The projectile on the body: its front, and the facing as a unit vector.
typedef struct { T5Vec4 front, direction; } T5ProjectileHome;
[[nodiscard]] T5ProjectileHome t5_projectile_home(T5Projectile row, const T5Fighter *f);
// A property: projectile leaves the body with its script.
[[nodiscard]] T5SpecialPoints t5_projectile_start(const T5Fighter *f, T5Projectile row, T5SpecialScript script);
// The projectile flies by its script; at the end of its life it goes back to the body.
[[nodiscard]] T5SpecialPoints t5_projectile_step(const T5World *w, const T5Fighter *f, T5Projectile row);

// Step 5 of the move change into `new_move`: a growing line flies free, a projectile move restarts the projectile from
// the body.
void t5_shots_move_change(T5Fighter *f, const T5Move *new_move);
// Step 10 of the movement step.
void t5_shots_step(const T5World *w, T5Fighter *f);

#endif
