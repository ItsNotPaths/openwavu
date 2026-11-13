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

// What a hit does to the fighter: a reaction move, or it keeps its move (TK6's bosses, FUN_001bfa50).
typedef enum : uint8_t { REACTION_KEEPING_REACTS, REACTION_KEEPING_ALWAYS, REACTION_KEEPING_WHEN_GUARDING } T6ReactionKeeping;

// The rules TK6 gives its bosses by model in code, as data of the body (Azazel, NANCY); zeros for any other fighter.
typedef struct {
    int16_t health;                      // points at the stock health setting; 0: the setting's points
    bool health_fixed;                   // the health setting does not scale it
    T6ReactionKeeping reaction_keeping;
    uint8_t guard_move_class;            // a guarded hit in this state class forces T6_ALIAS_FORCED_GUARD; 0: none
    bool unthrowable;                    // no throw or hit grab takes the fighter, no reversal answers its hits
    bool no_chip_damage;                 // its blocked hits do no chip damage
    bool no_flashback;                   // a KO in a round it fights skips the flashback
} T6BodyRules;

// A point on a bone, from the character's body_points row: the bone's world matrix applied to an offset, or, when `yawed`,
// the offset turned by the facing and put at the bone's position. Row i fills T6SpecialPoints.fixed[i]; `bone` is a bone of
// skeleton B.
#define T6_BODY_POINTS 2

typedef struct {
    uint8_t bone;
    bool yawed;
    T6Vec3 offset;
} T6BodyPoint;

typedef struct {
    uint32_t count;  // entries of point[] in use, at most T6_BODY_POINTS
    T6BodyPoint point[T6_BODY_POINTS];
} T6BodyPoints;

// How a character looks at the opponent (the GAZE row of its file). By move set, as the stock check is.
typedef struct {
    float tilt;        // radians: the gaze is tipped this much about the level axis across the line to the opponent's head
    T6Angle head_turn; // the head of the model sits turned this much about its y axis; the aim adds it (zero: none)
} T6Gaze;

#endif
