// Character move data, loaded from the .t5m files that tools/motbin2bin.py writes.
#ifndef T5_MOTBIN_H
#define T5_MOTBIN_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/body.h"
#include "sim/memory.h"
#include "sim/tracking.h"

#define T5_ALIAS_COUNT 37

// A record of the move data in slot `set` of the world: a move, a pushback or a pushback curve entry.
typedef struct {
    int16_t index;  // -1 = none
    uint8_t set;
    uint8_t pad;
} T5Ref;

// T5Ref.set of a pushback_curve that reads t5_default_pushback + 6 instead of move data.
#define T5_SET_DEFAULT_PUSHBACK 2

// Reaction list of a hit condition (the .t5m RLST table; the fields that
// are read here). The file holds set 0: t5_reaction_list gives the pushbacks the slot they are asked for.
typedef struct T5Reaction {
    T5Ref pushback[7];  // by T5ReactionSlot
    uint16_t angle[6];  // by T5ReactionSlot (the counter angle has no reader)
    uint16_t yaw[6];    // by T5ReactionSlot
    uint16_t move[14];  // reaction move slots
} T5Reaction;

// The pushback, angle and yaw slots of a reaction list.
enum T5ReactionSlot : uint8_t {
    REACTION_FRONT, REACTION_BACK, REACTION_LEFT, REACTION_RIGHT, REACTION_COUNTER, REACTION_HIT_DOWN, REACTION_GUARD,
};

// T5Move.flags (live bit order, docs/data.md) that the movement code reads.
enum : uint32_t {
    T5_MOVE_GUARD_BY_INPUT = 1 << 7,  // the guard stance follows the held direction
    T5_MOVE_NO_LEG_PUSH = 1 << 8,     // the push spheres of the legs are off
    T5_MOVE_STATE_4 = 1 << 9,         // a hit-down class that ends in this move gets STATE_HURT_4; its first frame is a first
                                      // frame for the requirements, two moves with it in a row count as one hit streak
    T5_MOVE_NO_KO = 1 << 15,          // a KO does not cut this move when it is the pending one
};

// T5Move.flags that the move change reads.
enum : uint32_t {
    T5_MOVE_TURNS_AT_END = 1 << 1,         // the end yaw of the move turns the fighter at the next move change
    T5_MOVE_FOLLOWS_FLOOR = 1 << 3,        // the root height is the height over the floor
    T5_MOVE_HIT_REACTION = 1 << 6,         // the next move takes the reaction angle off its start yaw and adds no juggle weight
    T5_MOVE_KEEPS_ROOT_YAW = 1 << 13,      // the start keeps the facing: no turn by the anim
    T5_MOVE_KEEPS_TOOK_DAMAGE = 1 << 23,   // the change keeps T5Fighter.took_damage
};

// T5Move.flags that a move change in a throw reads.
enum : uint32_t {
    T5_MOVE_KEEP_HIPS = 1 << 0,         // the anim keeps the hips; in a throw, the move takes the partner's facing, not its anim's turn
    T5_MOVE_THROW_RESYNC = 1 << 10,     // a later move of a throw lines up with the partner again
    T5_MOVE_ON_PARTNER = 1 << 11,       // the move starts aligned: a thrower on the partner's spot, the facing on the partner's (the body's for a half turn)
    T5_MOVE_THROWN_STAYS = 1 << 12,     // the thrown move after this one starts where the victim is
};

// T5Move.flags that the round init reads.
enum : uint32_t {
    T5_MOVE_NO_START_SHIFT = 1 << 17,  // the round reset does not step the fighter back by the move's root travel
};

// T5Move.flags that the motion step reads (the blend, the look-at, the face). T5_MOVE_STATE_4 also turns the hips along the
// look yaw and sets face 3; T5_MOVE_KEEP_HIPS also keeps the sampled hips; T5_MOVE_FOLLOWS_FLOOR also zeroes the blend's lift.
enum : uint32_t {
    T5_MOVE_LOOKS = 1 << 2,              // the fighter looks at the opponent
    T5_MOVE_NO_BLEND_IN = 1 << 4,        // no blend in from the old pose
    T5_MOVE_NO_BLEND_OUT = 1 << 5,       // no blend out toward the next move
    T5_MOVE_BLENDS_IN_ACTIVE = 1 << 30,  // the blend out also runs in the active frames
};

// Move ids of the alias table: 32768 + the alias index. The idles a move can end in, and the moves of a reaction.
enum : uint16_t {
    T5_ALIAS_BASE = 32768,
    T5_ALIAS_IDLE_STAND = T5_ALIAS_BASE + 1,
    T5_ALIAS_IDLE_CROUCH = T5_ALIAS_BASE + 2,
    T5_ALIAS_KO = T5_ALIAS_BASE + 25,
    T5_ALIAS_LAUNCH = T5_ALIAS_BASE + 26,     // the first of the six generic launches (T5LaunchEntry)
    T5_ALIAS_GUARD_AIR = T5_ALIAS_BASE + 32,  // a guarded hit in the air
    T5_ALIAS_THROW_CLASH = T5_ALIAS_BASE + 35,  // both fighters threw at once
};

// Where a hitbox point lies. The exporter turns the game's point code of a hitbox into a kind and an index (tools/hitpoints.py).
enum T5HitPointKind : uint8_t {
    HIT_POINT_NONE,     // no point (the start of a one-point hitbox)
    HIT_POINT_BONE,     // index: a bone of skeleton B
    HIT_POINT_SPECIAL,  // index: a slot of T5SpecialPoints.point
    HIT_POINT_EFFECT,   // the move uses the effect hitboxes of its side; no point of its own, so the previous point stays
    HIT_POINT_KEEP,     // the previous point stays
    HIT_POINT_FIXED,    // index: a fixed bone point of the character
    HIT_POINT_HITSCAN,     // index: T5HitscanPoint
    HIT_POINT_PROJECTILE,  // index: T5ProjectilePoint
};
enum T5HitscanPoint { HITSCAN_TIP, HITSCAN_TAIL };
enum T5ProjectilePoint { PROJECTILE_FRONT, PROJECTILE_BACK_LEFT, PROJECTILE_BACK_RIGHT };

typedef struct {
    uint8_t kind, index;
} T5HitPoint;

// The hitbox of a slot: it ends at `end` in the new pose and starts at `start`. A hitbox without a start starts where its end
// point was before the motion step.
typedef struct {
    T5HitPoint end, start;
} T5HitPair;

// What the requirements and the move change read of a move's hitboxes (table HITS, tools/hitpoints.py).
typedef struct {
    uint32_t attack_bones;  // bit b: the move attacks with bone b of skeleton B (the hit category requirements)
    uint8_t slots;          // hitbox slots that get points while the move is active: 0..2
    bool launches;          // a hitbox runs from the projectile's point (stock code 118): the move change puts it on the body
    uint8_t pad[2];
} T5MoveHits;

// Move record (name and anim name dropped). Table refs are indexes, -1 = none.
typedef struct {
    uint32_t anim;  // which animation the move plays
    uint32_t vuln;  // body state the move puts the fighter in (copied to their state when it starts)
    uint32_t hit_level;  // attack height bits; guard checks it against the defender guard mask
    uint32_t cancels;  // first cancel entry of the move (index into cancels)
    uint16_t next_move;                  // the move id it goes to when it ends (mostly an idle alias)
    int16_t end_yaw;                     // yaw turned when the move ends
    uint16_t compare_id;  // move identity that requirements and throw looks compare
    int16_t push_speed;                  // forward push, 1/256 units
    uint32_t hit_conditions;  // index of the hit condition (damage and reaction) the move deals
    uint16_t length;                     // anim length in frames
    uint16_t window_start, window_end;   // slide/push window
    uint16_t hold_frame;  // a move with one ends and holds there instead (flight lands on it); 0 = none
    int32_t voiceclips;  // voice clip of the move, -1 = none
    int32_t extra_props;                 // per-frame properties
    int32_t start_props;                 // conditional properties at move start
    int32_t end_prop;                    // conditional property when the move changes (end_properties)
    uint32_t flags;  // T5_MOVE_* bits
    uint8_t hitbox[4];                   // two {code, partner} pairs of the game (the harnesses derive hit_pair, hits)
    uint16_t first_active, last_active;  // frames the hitbox is on
    uint16_t padding;
    uint16_t push_shape;                 // how the move changes the push spheres (body_push.c)
    T5MoveTracking tracking;             // the tracking the move starts, unless a cancel or a reaction names another
    bool rides_partner;                  // the thrower rides on the partner: the body scale lifts it to the partner's head
    T5HitPair hit_pair[2];               // the hitbox points of the two slots, from `hitbox`
    T5MoveHits hits;                     // from `hitbox`
} T5Move;

// The move ends in the standing or crouching idle alias.
[[nodiscard]] static inline bool t5_move_ends_in_idle(const T5Move *move) {
    return move->next_move == T5_ALIAS_IDLE_STAND || move->next_move == T5_ALIAS_IDLE_CROUCH;
}

// command.code of a cancel entry from the list end on. Below it are key commands.
enum {
    T5_CANCEL_END = 1 << 15,  // end entry of a cancel list
    T5_CANCEL_DASH_F,         // forward dash
    T5_CANCEL_DASH_B,         // back dash
    T5_CANCEL_TAP_U,          // tap up
    T5_CANCEL_TAP_D,          // tap down
    T5_CANCEL_GROUP,          // go to group cancel `move`
    T5_CANCEL_GROUP_END,      // back to the entry after the group entry
    T5_CANCEL_SEQUENCE,       // first input sequence; sequence i is T5_CANCEL_SEQUENCE + i
};

// Bits of T5Cancel.option.
enum {
    T5_OPTION_NO_INPUT = 1 << 0,    // no command to match
    T5_OPTION_REVERSAL = 1 << 1,    // matches on a hit taken
    T5_OPTION_NO_DAMAGE = 1 << 2,
    T5_OPTION_TRACK = 1 << 3,       // option8 is 0 inside the window, 1 once the entry passes
    T5_OPTION_INPUT = 1 << 4,       // an input window
    T5_OPTION_FIRST_FRAME = 1 << 5,
    T5_OPTION_STOP = 1 << 6,        // the scan ends on this entry
    T5_OPTION_LOCK_SKIP = 1 << 7,   // skipped while the cancel lock is set
};

// Cancel command, u32 code << 16 | buttons. Also the entry of an input sequence.
typedef struct {
    uint16_t code;  // directions, or 32768.. list end, specials, groups, sequences
    uint16_t buttons;  // buttons
} T5Command;

// T5Command.buttons: bits 0..11 as in the button word, then the mode bits.
enum {
    T5_COMMAND_ANY_PRESS = 1 << 12,         // one of the presses is enough
    T5_COMMAND_HOLD_AFTER_PRESS = 1 << 13,  // presses must be held, and one must be new
    T5_COMMAND_SUMMARY = 1 << 14,           // the buttons half is one of the summaries: no press, no hold, some press, some hold
};

// Cancel record. Table refs are indexes.
typedef struct {
    T5Command command;
    uint32_t requirements;  // first entry in requirements
    uint16_t move;          // move id, or group index for the group code
    uint16_t tracking_pick; // tracking_overrides index + 1 (the pad of the game record), 0 = the move's own tracking
    uint32_t extradata;
    uint16_t window_start;
    uint16_t window_end;
    uint16_t start_frame;
    uint16_t option;        // as the loader computes it (input.md 7.1)
} T5Cancel;

typedef struct {
    uint16_t id, param;  // list ends at id 327
} T5Requirement;

// Input sequence: `count` commands from input_extras[first], oldest first.
typedef struct {
    uint16_t window;  // how many past input frames are searched for the sequence
    uint16_t count;
    uint32_t first;  // index of the first command in input_extras
} T5InputSequence;

// Pushback entry.
typedef struct {
    uint16_t frames;        // constant frames
    int16_t distance;       // distance per frame
    uint16_t curve_frames;
    uint16_t padding;
    uint32_t curve;         // first entry in pushback_curves
} T5Pushback;

// The default pushback of the juggle launch: move id, 440, 0, 0, 0, 0, then the 8 curve entries.
extern const uint16_t t5_default_pushback[14];

// Extra move property (the move's list, ends at when 0).
typedef struct {
    uint16_t when;   // frame code, see t5_props_tick
    uint16_t id;     // T5_PROPERTY_BASE + 1..
    uint16_t value;
    uint16_t padding;
} T5Property;

// An entry of a move's start list, or its end property: the property runs when the requirement holds.
typedef struct {
    uint32_t requirements;
    uint16_t id, value;
} T5ConditionalProperty;

typedef struct {
    uint32_t requirements;
    uint16_t damage, padding;  // damage: the points (low 14 bits), and the reaction rule (T5ReactionRule) above them
    uint32_t reaction;
} T5HitCondition;

enum { HIT_CONDITION_DAMAGE_BITS = 14 };
[[nodiscard]] static inline int16_t t5_hit_condition_damage(const T5HitCondition *condition) {
    return (int16_t)(condition->damage % (1 << HIT_CONDITION_DAMAGE_BITS));
}
[[nodiscard]] static inline uint8_t t5_hit_condition_rule(const T5HitCondition *condition) { return (uint8_t)(condition->damage >> HIT_CONDITION_DAMAGE_BITS); }

// Side band record: the sector of a relative angle, see t5_relative_angles.
typedef struct {
    uint16_t offset;  // added to the angle
    uint16_t width_0, width_1, width_2;  // widths of the sectors 0, 1, 2 (sector 3 is the rest)
} T5SideBand;

typedef struct {
    uint32_t aliases[T5_ALIAS_COUNT];  // live alias table
    int32_t move_count;
    T5Move *moves;
    T5Cancel *cancels;
    int32_t cancel_count;
    T5Cancel *group_cancels;
    int32_t group_cancel_count;
    T5Requirement *requirements;
    int32_t requirement_count;
    T5InputSequence *input_sequences;  // sequence command code + i
    int32_t input_sequence_count;
    uint16_t *input_joints;            // per sequence, bit k: key k follows key k - 1 directly (':'); NULL: none, as in sim files
    T5Command *input_extras;
    int32_t input_extra_count;
    uint16_t *id_pool;                 // 0-terminated runs (reqs 123, 218, 296)
    int32_t id_pool_count;
    uint32_t alias_defaults[T5_ALIAS_COUNT];  // (the alias restore properties restore them)
    T5Pushback *pushbacks;
    int32_t pushback_count;
    uint16_t *pushback_curves;
    int32_t pushback_curve_count;
    T5Property *properties;            // T5Move.extra_props indexes it
    int32_t property_count;
    T5ConditionalProperty *start_properties;  // T5Move.start_props indexes it
    int32_t start_property_count;
    T5ConditionalProperty *end_properties;    // T5Move.end_prop indexes it
    int32_t end_property_count;
    T5HitCondition *hit_conditions;
    int32_t hit_condition_count;
    T5SideBand *side_bands;            // 8 records
    int32_t side_band_count;
    T5Reaction *reactions;             // T5HitCondition.reaction indexes it
    int32_t reaction_count;
    T5FacingRow *tracking;             // rows of the tracking table: T5MoveTracking and `PROP_TRACKING` name them; row 0 is hold
    int32_t tracking_count;
    T5MoveTracking *tracking_overrides;  // T5Cancel.tracking_pick names one
    int32_t tracking_override_count;
    T5MoveTracking *fixed_tracking;      // TRACKING_FIXED_*
    int32_t fixed_tracking_count;
    T5Body *body;                        // BODY: one row, the body measures of the character
    int32_t body_count;
    T5BodyPoints *body_points;           // ANCH: one row, the fixed bone points of the character
    int32_t body_point_count;
    T5Gaze *gaze;                        // GAZE: one row, how the character looks at the opponent
    int32_t gaze_count;
} T5Motbin;

// The body row of the character; zeros (nothing pushes, no hurtbox) when the file has none.
static inline T5Body t5_motbin_body(const T5Motbin *motbin) { return motbin->body_count > 0 ? motbin->body[0] : (T5Body){}; }
static inline T5BodyPoints t5_motbin_body_points(const T5Motbin *motbin) {
    if (motbin->body_point_count <= 0) return (T5BodyPoints){};
    T5BodyPoints points = motbin->body_points[0];
    if (points.count > T5_BODY_POINTS) points.count = T5_BODY_POINTS;
    return points;
}

// No row: no tilt, no head turn.
static inline T5Gaze t5_motbin_gaze(const T5Motbin *motbin) { return motbin->gaze_count > 0 ? motbin->gaze[0] : (T5Gaze){}; }

// .t5m bytes (tools/motbin2bin.py) into caller memory. The first thing taken from the arena is `moves`.
bool t5_motbin_storage(T5Bytes file, size_t *bytes);  // arena bytes that t5_motbin_parse takes; false if the file is bad
int32_t t5_motbin_move_count(T5Bytes bytes);        // -1 if the file is bad
int t5_motbin_parse(T5Motbin *motbin, T5Bytes bytes, T5Arena *arena);  // 0 on success

#endif
