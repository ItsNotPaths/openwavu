// Throws: a throw is a cancel into a move of the thrower class. The cancel's requirements check the
// position of the victim and the range; the next frame the throw connects (the victim takes the reaction move of the throw)
// or, when both fighters throw, clashes. The two fighters are a pair (T6Throw.partner) for the moves of the throw. throw.c.
#ifndef T6_THROW_H
#define T6_THROW_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/hit.h"
#include "sim/motbin.h"
#include "sim/world.h"

// The role of a fighter in a throw and the moves they have played in it, counting the move that started the role.
typedef enum : uint8_t { THROW_ROLE_NONE, THROW_ROLE_THROWER, THROW_ROLE_THROWN } T6ThrowRole;

typedef struct {
    T6ThrowRole role;
    uint16_t moves;  // throw moves in a row with this role; restarts at 1 on a new role
} T6ThrowChain;

// How the victim stands for a throw. The throw requirements name a stance and the side the thrower is on.
typedef enum : uint8_t {
    THROW_UNSEEN,          // not looked at since the cache was cleared
    THROW_NOT_THROWABLE,   // no hit landed, or the victim is in no stance a throw takes
    THROW_STANDING, THROW_CROUCHING, THROW_FACE_UP, THROW_FACE_DOWN,
    THROW_BEHIND,          // standing with their back to the thrower
    THROW_STANDING_OR_CROUCHING,  // only in requirements
    THROW_AIR, THROW_AIR_FACE_DOWN,
} T6ThrowStance;

typedef struct {
    T6ThrowStance stance;
    uint8_t side;  // enum T6HitSide of the victim
} T6ThrowPosition;

// What a fighter knows about one opponent for the throw requirements: the range to them, and the position last seen with the
// opponent's state and the own move id at that time (the cache of the game; a later look at the same state or move reuses it).
typedef struct {
    float range;
    T6ThrowPosition seen;
    uint32_t seen_state;
    uint32_t seen_move_id;
} T6ThrowTarget;

typedef struct {
    int16_t partner;                // object index of the other fighter of the throw
    T6ThrowChain chain;
    T6ThrowChain chain_before;      // the chain as the current move began
    int16_t wall_hit;               // the throw hit a wall (1), or a voice property's value
    T6ThrowTarget target[T6_FIGHTER_COUNT];  // by the opponent's slot
} T6Throw;

[[nodiscard]] static inline bool t6_in_throw(T6ThrowChain chain) { return chain.role != THROW_ROLE_NONE; }
[[nodiscard]] static inline bool t6_throwing(T6ThrowChain chain) { return chain.role == THROW_ROLE_THROWER; }
[[nodiscard]] static inline bool t6_thrown(T6ThrowChain chain) { return chain.role == THROW_ROLE_THROWN; }

// The chain after a move change into a move of `role`.
[[nodiscard]] T6ThrowChain t6_throw_chain_step(T6ThrowChain chain, T6ThrowRole role);

// The other fighter of f's throw, NULL when none.
[[nodiscard]] T6Fighter *t6_throw_partner(const T6World *w, const T6Fighter *f);
// a and b throw each other: one of them is in a throw with the other as partner.
[[nodiscard]] bool t6_throw_pair(const T6World *w, const T6Fighter *first, const T6Fighter *second);
// Makes f and the object `partner` the pair of a throw.
void t6_throw_link(const T6World *w, T6Fighter *f, int16_t partner);

// The throw requirements (ids 2..33): four ids a stance, front, back, left and right of the victim.
enum { THROW_REQ_FIRST = 2, THROW_REQ_LAST = 33 };
[[nodiscard]] T6ThrowPosition t6_throw_position_of_requirement(uint16_t requirement);
// the victim must be on the wanted side; a combined wanted stance takes standing or crouching
[[nodiscard]] bool t6_throw_position_takes(T6ThrowPosition wanted, T6ThrowPosition seen);

// The position of the opponent for a throw by f (and its classifier).
[[nodiscard]] T6ThrowPosition t6_throw_position(const T6Fighter *f, const T6Fighter *opponent);
// The target row after f looks at the opponent: a seen position stays while the opponent's state or move id is the one
// seen (the game compares the opponent's move with the id of f's own move). own_move_id, opponent_move_id:
// T6Move.compare_id of both moves.
[[nodiscard]] T6ThrowTarget t6_throw_look(T6ThrowTarget target, const T6Fighter *f, const T6Fighter *opponent, uint32_t own_move_id, uint32_t opponent_move_id);
// No position seen: the start of every cancel scan.
void t6_throw_forget(T6Fighter *f);

// The turn of the victim's facing from the thrower's position, when the throw takes the partner's facing. `partner_turned`:
// the thrower's move change turned them half a circle.
[[nodiscard]] int16_t t6_throw_victim_turn(T6ThrowPosition position, bool partner_turned);

// The frames the victim counts as thrown: to the end of the thrower's move, or to its hold frame.
[[nodiscard]] int16_t t6_thrown_frames(const T6Move *thrower, const T6Move *victim);

// The thrower stands where their throw anim starts from the victim; the victim slides there over the slide frames.
// on_partner: the thrower takes the victim's spot.
void t6_throw_snap(const T6World *w, T6Fighter *thrower, T6Fighter *victim, bool on_partner);

// The pending throws of the frame. One thrower connects: the victim takes the reaction move of the throw, then both
// change moves, the victim first; the pair is returned. Two throwers clash: each takes the clash move; none is returned.
typedef struct {
    T6Fighter *thrower, *victim;
} T6ThrowStart;
[[nodiscard]] int32_t t6_pending_throwers(const T6World *w, T6Fighter *out[], int32_t cap);
T6ThrowStart t6_throws_start(T6World *w, T6Fighter *const throwers[], int32_t count);

#endif
