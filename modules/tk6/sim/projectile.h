// Shots: the hitscan and the projectile of a character and the special points they move. The rows are named consts; the ANCH row
// of a character file picks one of each list by its place (T6BodyPoints).
#ifndef T6_PROJECTILE_H
#define T6_PROJECTILE_H

#include "sim/fighter.h"

extern const T6Hitscan T6_HITSCAN_EYE_LASER;   // Devil Jin
extern const T6Projectile T6_PROJECTILE_FIRE;  // Jinpachi

// The rows a file can pick, in the order the exporter numbers them; entry 0 is none.
extern const T6Hitscan *const T6_HITSCANS[];
extern const T6Projectile *const T6_PROJECTILES[];

// The fighter's rows; NULL when it has none.
[[nodiscard]] const T6Hitscan *t6_hitscan_of(const T6Fighter *f);
[[nodiscard]] const T6Projectile *t6_projectile_of(const T6Fighter *f);

// The start point of a shot on its bone of skeleton A.
[[nodiscard]] T6Vec4 t6_shot_start(T6BodyPoint start, const T6Fighter *f);

// Two properties: the line starts growing at its start point; it stops and flies free along its line.
[[nodiscard]] T6SpecialPoints t6_hitscan_start(const T6Fighter *f, T6Hitscan row, T6SpecialScript script);
[[nodiscard]] T6SpecialPoints t6_hitscan_stop(const T6Fighter *f, T6Hitscan row);
// The line grows by its script; stopped, its tip flies free.
[[nodiscard]] T6SpecialPoints t6_hitscan_step(const T6World *w, T6SpecialPoints special);

// The projectile on the body: its front, and the facing as a unit vector.
typedef struct { T6Vec4 front, direction; } T6ProjectileHome;
[[nodiscard]] T6ProjectileHome t6_projectile_home(T6Projectile row, const T6Fighter *f);
// A property: projectile leaves the body with its script.
[[nodiscard]] T6SpecialPoints t6_projectile_start(const T6Fighter *f, T6Projectile row, T6SpecialScript script);
// The projectile flies by its script; at the end of its life it goes back to the body.
[[nodiscard]] T6SpecialPoints t6_projectile_step(const T6World *w, const T6Fighter *f, T6Projectile row);

// Step 5 of the move change into `new_move`: a growing line flies free, a projectile move restarts the projectile from
// the body.
void t6_shots_move_change(T6Fighter *f, const T6Move *new_move);
// Step 10 of the movement step.
void t6_shots_step(const T6World *w, T6Fighter *f);

#endif
