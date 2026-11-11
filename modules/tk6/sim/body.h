// The body measures of a character: the spheres that keep fighters apart, the hurtbox sizes, the throw range cut and the head
// probe of the limb code.
// The BODY row of the character file is the stock data. The fighter holds its own copy, so a host can give
// a fighter the row of another character.
#ifndef T6_BODY_H
#define T6_BODY_H

#include <stdint.h>

#include "sim/units.h"
#include "sim/vec.h"

#define T6_HURTBOXES 14
#define T6_PUSH_POINTS 8

// Push spheres by body part, in the order of T6Body.push (bones: neck, left forearm, right forearm, hips, left shin, right shin,
// left foot, right foot). Named because the push shape of a move switches spheres off by part (body_push.c).
enum T6PushSphere {
    PUSH_CHEST, PUSH_ARM_1, PUSH_ARM_2, PUSH_HIPS, PUSH_SHIN_1, PUSH_SHIN_2, PUSH_FOOT_1, PUSH_FOOT_2,
};

// A hurtbox is a vertical cylinder centred on a bone of skeleton B, lifted by `lift`. The order of the rows is the index the hit
// record stores. Units: mm.
typedef struct {
    int16_t radius;  // radius, and half height
    uint8_t bone;
    float lift;  // added to the bone's height for the box centre
} T6HurtRow;

// A push point is a sphere on a bone; `radius` is its size at rest (the move changes it).
typedef struct {
    float radius;
    uint8_t bone;
} T6PushRow;

// The floor probe of the head (limb code): a point in head space on the x and z axes and a radius, as fractions of the
// length of the head end bone.
typedef struct {
    float x, z, radius;
} T6HeadProbe;

// Units: mm.
typedef struct {
    T6HurtRow hurt[T6_HURTBOXES];
    T6PushRow push[T6_PUSH_POINTS];
    float throw_range_cut;               // the throw range of both fighters is shorter by this much for this fighter
    T6HeadProbe head_probe;
    float head_top;                      // height of the head end point in the standing idle (not stock: the exporter measures it)
} T6Body;

// A point fixed to a bone: the bone's world matrix applied to an offset. Of a character, from the ANCH row of its file
// row i fills T6SpecialPoints.fixed[i]. `bone` is a bone of skeleton B.
#define T6_BODY_POINTS 2

typedef struct {
    uint8_t bone;
    T6Vec3 offset;
} T6BodyPoint;

// A hitscan (Devil Jin's laser): a line from `bone` (skeleton B) along its x axis, as long as its script has grown it; a hitbox
// on the line hits anything on it. Its start puts the tip at `start` (skeleton A). Its stop puts the tail on the line bone, and
// the tip flies on away from it, the tail with it, for `free_frames` at the last growth step.
typedef struct {
    T6BodyPoint start;
    int16_t free_frames;  // frames the shot flies on at its last speed once the script stops growing it
    uint8_t bone;
} T6Hitscan;

// A projectile (Jinpachi's fire): its front flies along the facing by its script for `life` frames, then goes back to `start`
// (skeleton A). The hitboxes run from the front to the two back corners, `back` behind it and `side` to each side.
typedef struct {
    T6BodyPoint start;
    float back, side;
    int16_t life;
} T6Projectile;

// The fixed bone points and the shots of a character (the ANCH row of its file). `hitscan` and `projectile`
// name a row of T6_HITSCANS and T6_PROJECTILES (projectile.h) by its place in the list; zero is none.
typedef struct {
    uint32_t count;  // entries of point[] in use, at most T6_BODY_POINTS
    T6BodyPoint point[T6_BODY_POINTS];
    uint8_t hitscan, projectile;
} T6BodyPoints;

// How a character looks at the opponent (the GAZE row of its file). By move set, as the stock check is.
typedef struct {
    float tilt;        // radians: the gaze is tipped this much about the level axis across the line to the opponent's head
    T6Angle head_turn; // the head of the model sits turned this much about its y axis; the aim adds it (zero: none)
} T6Gaze;

#endif
