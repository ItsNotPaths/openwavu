// Hit shapes: hitbox points, hurtbox centres and radii, push points; hit detection.
#ifndef T6_HIT_H
#define T6_HIT_H

#include <stdint.h>

#include "sim/body.h"
#include "sim/motbin.h"
#include "sim/limb.h"
#include "sim/world.h"

typedef struct { T6Vec3 start, end; } T6HitSegment;  // A = start, B = end: one hitbox is a line (a limb path), not a volume
typedef struct { float x, y, z, radius_squared, radius; } T6Hurtbox;  // vertical cylinder: radius r, half height r

enum T6SpecialSlot {  // slots of T6SpecialPoints.point, rebuilt every frame from the bones; moves use them as hitbox ends
    SPECIAL_CHEST_AHEAD, SPECIAL_CHEST_BEHIND, SPECIAL_HEAD_AHEAD, SPECIAL_L_FOOT_LOW, SPECIAL_L_FOOT_HIGH, SPECIAL_R_FOOT_HIGH,
    T6_SPECIAL_SLOTS,
};

// A script of the special points: constant frames, then curve frames (the shape of a pushback).
typedef struct {
    T6Ref curve;            // cursor in the pushback curves (a pointer in the game)
    int16_t frames, curve_frames, distance;
} T6SpecialScript;

// A hitscan of the fighter (T6Hitscan).
typedef struct {
    T6SpecialScript script;  // the growth a frame
    int16_t speed;           // the last positive growth step: the speed of the free flight
    float length;
    int16_t free_frames;     // left of the free flight; none: the tip sits on the line
    T6Vec4 tip, tail;        // beam from tail to tip; the tail is set when the line stops, so the tip flies on away from it
} T6HitscanState;

// A projectile of the fighter (T6Projectile).
typedef struct {
    T6SpecialScript script;  // the travel a frame
    int16_t frames_left;     // of the flight
    uint16_t aura;           // effect kind: 2, or 7 after a hit
    T6Vec4 front, direction; // the point that flies, and its flight direction (a unit vector)
    T6Vec4 back_left, back_right;  // the back corners of its hit area, a wedge behind `front`
} T6ProjectileState;

// The special points and the shots that move them; the hitbox point kinds HIT_POINT_SPECIAL, _FIXED, _HITSCAN and
// _PROJECTILE read them.
typedef struct T6SpecialPoints {
    T6Vec4 point[T6_SPECIAL_SLOTS];
    T6Vec4 fixed[T6_BODY_POINTS];  // the fixed bone points of the character (T6BodyPoints)
    T6HitscanState hitscan;
    T6ProjectileState projectile;
} T6SpecialPoints;

// T6Move.hit_level: the low three bits are the heights the attack hits (the hurt bits of the defender's state, STATE_HURT_BITS),
// the rest picks a kind of attack. The kinds that the hit gate and the limb aim tell apart:
enum : uint16_t {
    HIT_LEVEL_LOW_A = 271,       // low attacks: they miss a fighter who is jumping (CLASS_JUMP_A..), see t6_hit_register
    HIT_LEVEL_LOW_B = 1055,
    HIT_LEVEL_LOW_C = 2311,
    HIT_LEVEL_AIR_ONLY = 2823,   // hits a fighter only while they are airborne
    HIT_LEVEL_HIGH_A = 2054,     // hand and foot hitboxes of these three aim at the opponent's height (limb.c)
    HIT_LEVEL_HIGH_B = 1298,
    HIT_LEVEL_NO_HEIGHT = 2560,
    HIT_LEVEL_MID_A = 535,       // the mid attacks of the requirements
    HIT_LEVEL_MID_B = 799,
    HIT_LEVEL_MID_C = 1799,
};

enum { T6_HIT_SEGMENTS = 4 };  // hitbox segments the detection reads

// The hit shapes of a fighter.
typedef struct T6Hit {
    T6HitSegment segment[4];               // the points fill 2, detection reads up to 4
    T6Hurtbox hurtbox[T6_HURTBOXES];       // where the body can be hit: one cylinder per body part
    T6Vec4 push_point[T6_PUSH_POINTS];     // body points that shove fighters apart; x, y, z here; r belongs to the push code
    T6Vec3 attack_direction;               // B - A of hitbox slot 0
    T6Vec3 incoming_direction;             // attack direction copied to the defender
} T6Hit;

// T6HitRecord.flags: a bitmask, each bit is one fact about the hit and several can be set together. LIVE is set by hit detection
// when a hit lands, the rest by the damage pass. A live hit is exactly one of no reaction, guarded or clean (the base outcome);
// the other bits add to it. For example a counter hit on a juggled fighter is LIVE | CLEAN | COUNTER | OFF_GROUND.
enum : uint32_t {
    T6_HIT_LIVE = 1u << 31,         // this record holds a real hit
    T6_HIT_GUARDED = 1u << 30,      // the defender blocked it
    T6_HIT_CHIP = 1u << 29,         // guarded, and the guard lets a little damage through
    T6_HIT_CLEAN = 1u << 28,        // the hit connected, not blocked
    T6_HIT_COUNTER = 1u << 27,      // clean hit that caught the defender in their own attack
    T6_HIT_OFF_GROUND = 1u << 25,   // the defender was airborne: a juggle hit
    T6_HIT_NO_REACTION = 1u << 24,  // a harmless move touched the fighter
    T6_HIT_NO_SPARK = 1u << 23,     // the attacker's move shows no hit spark
};
// The result bits of a record, the clear of the hit register: bit 23 and up. Bit 26 has no writer.
enum : uint32_t { T6_HIT_FLAGS = ~(T6_HIT_NO_SPARK - 1) };

enum { T6_HIT_RECORDS = 2 };  // hits a fighter can take in one frame (two attackers at once)
enum { T6_HIT_TARGETS = 3 };  // fighters one move can hit

// T6Fighter.hit_side: the side of the fighter a hit comes from (motion.c, from reference_side_angle).
enum T6HitSide : int16_t { HIT_FRONT, HIT_LEFT, HIT_BACK, HIT_RIGHT, T6_HIT_SIDES };

// A hit taken this frame.
typedef struct {
    int16_t attacker;          // object index
    T6Vec3 point;              // where the hit landed (the hitbox end)
    T6Vec3 direction;          // the way the hitbox was travelling
    int16_t hurtbox;           // which body part was hit
    uint16_t base_damage;      // the move's damage
    int16_t final_damage;      // after the damage pass (guard, counter and the like)
    uint32_t flags;            // bit 31: record in use
} T6HitRecord;

// Effect hitboxes, per side. A move whose first hitbox point is HIT_POINT_EFFECT uses them.
typedef struct T6EffectHitboxes {  // hitboxes that come from an effect, not from the fighter's own limbs
    T6HitSegment segment[2];
    int32_t count;
} T6EffectHitboxes;

// Hitbox points of the move's two slots (T6Move.hit_pair), in skeleton B in world space. Objects (kind != 0) are not ported: the
// hook is the early return. `move` is the fighter's current move.
// A bone point also takes the limb offset of its bone (the aimed hand and foot hitboxes, limb.c).
void t6_limb_offset(const T6LimbState *limbs, T6HitPoint point, T6Vec4 *position);
T6Vec4 *t6_limb_offset_at(T6LimbState *table, int32_t slot, int32_t limb, int32_t skeleton);
void t6_hitbox_starts(T6Fighter *f, const T6Move *move);
void t6_hit_points(T6Fighter *f, const T6Move *move);
void t6_hurtbox_radii(T6Fighter *f);
void t6_attack_direction(T6Hit *hit);
void t6_incoming_direction(T6Hit *defender, const T6Hit *attacker);

void t6_hit_victims_clear(T6Fighter *f);  // forget who this move already hit, so the next move can hit them again
void t6_hit_records_clear(const T6World *w, T6Fighter *f);  // start of frame: no hits taken or landed, records emptied
const T6HitSegment *t6_effect_hitboxes(const T6EffectHitboxes *table, int32_t side, int32_t *count);
bool t6_hit_geometry(const T6World *w, const T6Fighter *attacker, const T6Fighter *defender,
                     T6HitRecord *out);  // hitbox touches hurtbox? fill record
void t6_hit_register(T6World *w, T6Fighter *attacker, T6Fighter *defender);  // gate, geometry, record

void t6_hit_records_pass(T6World *w);  // clear the records of every fighter
void t6_clear_results_pass(T6World *w);  // clear last frame's ko, guard, clean and counter results
void t6_attack_direction_pass(T6World *w);  // work out where each fighter's attack points
void t6_hitbox_starts_pass(T6World *w);  // save hitbox starts before the fighters move
void t6_hurtboxes_pass(T6World *w);      // hit points of the fighters and the extras
void t6_hit_detection_pass(T6World *w);    // both fighters against each other and every object

#endif
