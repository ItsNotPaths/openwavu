// Character move data, loaded from the pack db (load.c, src/db/tk6/schema.sql).
#ifndef T6_MOTBIN_H
#define T6_MOTBIN_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/body.h"
#include "sim/memory.h"
#include "sim/tracking.h"

#define T6_ALIAS_COUNT 69  // TK6's slots

// A record of the move data in slot `set` of the world: a move, a pushback or a pushback curve entry.
typedef struct {
    int16_t index;  // -1 = none
    uint8_t set;
    uint8_t pad;
} T6Ref;

// T6Ref.set of a pushback_curve that reads t6_default_pushback + 6 instead of move data.
#define T6_SET_DEFAULT_PUSHBACK 2

// Reaction list of a hit condition (the .t5m RLST table; the fields that
// are read here). The file holds set 0: the fighter that takes a reaction gives its pushbacks the attacker's set.
typedef struct T6Reaction {
    T6Ref pushback[7];  // by T6ReactionSlot
    uint16_t angle[6];  // by T6ReactionSlot (the counter angle has no reader)
    uint16_t yaw[6];    // by T6ReactionSlot
    uint16_t move[14];  // reaction move slots
} T6Reaction;

// The pushback, angle and yaw slots of a reaction list.
enum T6ReactionSlot : uint8_t {
    REACTION_FRONT, REACTION_BACK, REACTION_LEFT, REACTION_RIGHT, REACTION_COUNTER, REACTION_HIT_DOWN, REACTION_GUARD,
};

// T6Move.flags (TK5's live bit order; the db names each TK6 bit) that the movement code reads.
enum : uint32_t {
    T6_MOVE_GUARD_BY_INPUT = 1 << 7,  // the guard stance follows the held direction
    T6_MOVE_NO_LEG_PUSH = 1 << 8,     // the push spheres of the legs are off
    T6_MOVE_STATE_4 = 1 << 9,         // a hit-down class that ends in this move gets STATE_HURT_4; its first frame is a first
                                      // frame for the requirements, two moves with it in a row count as one hit streak
    T6_MOVE_NO_KO = 1 << 15,          // a KO does not cut this move, the current or the pending one
};

// T6Move.flags that the move change reads.
enum : uint32_t {
    T6_MOVE_TURNS_AT_END = 1 << 1,         // the end yaw of the move turns the fighter at the next move change
    T6_MOVE_FOLLOWS_FLOOR = 1 << 3,        // the root height is the height over the floor
    T6_MOVE_HIT_REACTION = 1 << 6,         // the next move takes the reaction angle off its start yaw and adds no juggle weight
    T6_MOVE_KEEPS_ROOT_YAW = 1 << 13,      // the start keeps the facing: no turn by the anim
    T6_MOVE_KEEPS_TOOK_DAMAGE = 1 << 23,   // the change keeps T6Fighter.took_damage
};

// T6Move.flags that a move change in a throw reads.
enum : uint32_t {
    T6_MOVE_KEEP_HIPS = 1 << 0,         // the anim keeps the hips; in a throw, the move takes the partner's facing, not its anim's turn
    T6_MOVE_THROW_RESYNC = 1 << 10,     // a later move of a throw lines up with the partner again
    T6_MOVE_ON_PARTNER = 1 << 11,       // the move starts aligned: a thrower on the partner's spot, the facing on the partner's (the body's for a half turn)
    T6_MOVE_THROWN_STAYS = 1 << 12,     // the thrown move after this one starts where the victim is
};

// T6Move.flags that the round init reads.
enum : uint32_t {
    T6_MOVE_NO_START_SHIFT = 1 << 17,  // the round reset does not step the fighter back by the move's root travel
};

// T6Move.flags that the motion step reads (the blend, the look-at, the face). T6_MOVE_STATE_4 also turns the hips along the
// look yaw and sets face 3; T6_MOVE_KEEP_HIPS also keeps the sampled hips; T6_MOVE_FOLLOWS_FLOOR also zeroes the blend's lift.
enum : uint32_t {
    T6_MOVE_LOOKS = 1 << 2,              // the fighter looks at the opponent
    T6_MOVE_NO_BLEND_IN = 1 << 4,        // no blend in from the old pose
    T6_MOVE_NO_BLEND_OUT = 1 << 5,       // no blend out toward the next move
    T6_MOVE_BLENDS_IN_ACTIVE = 1 << 30,  // the blend out also runs in the active frames
};

// Move ids of the alias table: 32768 + the TK6 alias slot (tk6decomp sim_contract.md 3). The idles a move can end in, and
// the moves of a reaction.
enum : uint16_t {
    T6_ALIAS_BASE = 32768,
    T6_ALIAS_ROUND_START = T6_ALIAS_BASE + 0,  // a round starts in it; its cancels pick the intro, win and loss poses
    T6_ALIAS_IDLE_STAND = T6_ALIAS_BASE + 1,
    T6_ALIAS_IDLE_CROUCH = T6_ALIAS_BASE + 2,
    T6_ALIAS_KO = T6_ALIAS_BASE + 25,
    T6_ALIAS_KO_HARD = T6_ALIAS_BASE + 26,       // a KO by hits of KO_HARD_DAMAGE or more, of an attack kind but low, high or mid
    T6_ALIAS_KO_HARD_HIGH = T6_ALIAS_BASE + 27,  // the same by a high or mid attack (ATTACK_KIND_STAND_FIRST..LAST)
    T6_ALIAS_KO_HARD_LOW = T6_ALIAS_BASE + 28,   // the same by a low attack
    T6_ALIAS_LAUNCH = T6_ALIAS_BASE + 29,      // the first of the six generic launches (T6LaunchEntry)
    T6_ALIAS_LAUNCH_LAST = T6_ALIAS_BASE + 34,
    T6_ALIAS_GUARD_AIR = T6_ALIAS_BASE + 35,   // a guarded hit in the air
    T6_ALIAS_KEEPS_BOUND = T6_ALIAS_BASE + 36,  // a plain cancel into these keeps the bound, as into the launches
    T6_ALIAS_KEEPS_BOUND_LAST = T6_ALIAS_BASE + 38,
    T6_ALIAS_THROW_CLASH = T6_ALIAS_BASE + 43,  // both fighters threw at once
    T6_ALIAS_AWAY = T6_ALIAS_BASE + 44,  // the fighter out of focus during an intro (a slot holding the idle)
    T6_ALIAS_FORCED_REACTION = T6_ALIAS_BASE + 63,  // reactions the attacker's campaign item states force: not in versus
    T6_ALIAS_FORCED_REACTION_LAST = T6_ALIAS_BASE + 67,
    T6_ALIAS_FORCED_GUARD = T6_ALIAS_BASE + 68,  // forced by a guarded hit in the body rules' guard move class
};

// Where a hitbox point lies. The exporter turns the game's point code of a hitbox into a kind and an index.
enum T6HitPointKind : uint8_t {
    HIT_POINT_NONE,     // no point (the start of a one-point hitbox)
    HIT_POINT_BONE,     // index: a bone of skeleton B
    HIT_POINT_SPECIAL,  // index: a slot of T6SpecialPoints.point
    HIT_POINT_EFFECT,   // the move uses the effect hitboxes of its side; no point of its own, so the previous point stays
    HIT_POINT_KEEP,     // the previous point stays
    HIT_POINT_FIXED,    // index: a fixed point of the character
    HIT_POINT_SHOT,     // the tip of the shot
};

typedef struct {
    uint8_t kind, index;
} T6HitPoint;

// The hitbox of a slot: it ends at `end` in the new pose and starts at `start`. A hitbox without a start starts where its end
// point was before the motion step.
typedef struct {
    T6HitPoint end, start;
} T6HitPair;

// What the requirements and the move change read of a move's hitboxes (table HITS).
typedef struct {
    uint32_t attack_bones;  // bit b: the move attacks with bone b of skeleton B (the hit category requirements)
    uint8_t slots;          // hitbox slots that get points while the move is active: 0..2
    uint8_t pad[3];
} T6MoveHits;

// A voice clip of a move: selector << T6_VOICE_SELECTOR_SHIFT | number, the TK6 form (cue.h). A list holds up to T6_VOICECLIPS.
static constexpr uint32_t T6_VOICECLIP_END = 0xffffffff;
enum { T6_VOICECLIPS = 3 };

// Move record (name and anim name dropped). Table refs are indexes, -1 = none.
typedef struct {
    uint32_t anim;  // which animation the move plays
    uint32_t vuln;  // body state the move puts the fighter in (copied to their state when it starts)
    uint32_t hit_level;  // attack height bits; guard checks it against the defender guard mask
    uint32_t cancels;  // first cancel entry of the move (index into cancels)
    uint16_t next_move;                  // the move id it goes to when it ends (mostly an idle alias)
    int16_t end_yaw;                     // yaw turned when the move ends
    uint32_t compare_id;  // move identity that requirements and throw looks compare (TK6: 32 bits)
    int16_t push_speed;                  // forward push, 1/256 units
    uint32_t hit_conditions;  // index of the hit condition (damage and reaction) the move deals
    uint16_t length;                     // anim length in frames
    uint16_t window_start;               // slide/push window
    int32_t window_end;                  // (TK6: 32 bits)
    uint16_t hold_frame;  // a move with one ends and holds there instead (flight lands on it); 0 = none
    int32_t voiceclips;  // first voice clip of the move (T6Motbin.voiceclips), -1 = none
    int32_t extra_props;                 // per-frame properties
    int32_t start_props;                 // conditional properties at move start
    int32_t end_prop;                    // conditional property when the move changes (end_properties)
    uint32_t flags;  // T6_MOVE_* bits
    uint8_t hitbox[4];                   // two {code, partner} pairs of the game, TK6 codes (hit_pair and hits hold what they mean)
    uint16_t first_active, last_active;  // frames the hitbox is on
    uint16_t padding;
    uint16_t push_shape;                 // how the move changes the push spheres (body_push.c)
    T6MoveTracking tracking;             // the tracking the move starts, unless a cancel or a reaction names another
    bool rides_partner;                  // the thrower rides on the partner: the body scale lifts it to the partner's head
    T6HitPair hit_pair[2];               // the hitbox points of the two slots, from `hitbox`
    T6MoveHits hits;                     // from `hitbox`
} T6Move;

// The move ends in the standing or crouching idle alias.
[[nodiscard]] static inline bool t6_move_ends_in_idle(const T6Move *move) {
    return move->next_move == T6_ALIAS_IDLE_STAND || move->next_move == T6_ALIAS_IDLE_CROUCH;
}

// command.code of a cancel entry from the list end on. Below it are key commands.
enum {
    T6_CANCEL_END = 1 << 15,  // end entry of a cancel list
    T6_CANCEL_DASH_F,         // forward dash
    T6_CANCEL_DASH_B,         // back dash
    T6_CANCEL_TAP_U,          // tap up
    T6_CANCEL_TAP_D,          // tap down
    T6_CANCEL_GROUP,          // go to group cancel `move`
    T6_CANCEL_GROUP_END,      // back to the entry after the group entry
    T6_CANCEL_SEQUENCE,       // first input sequence; sequence i is T6_CANCEL_SEQUENCE + i
};

// Bits of T6Cancel.option.
enum {
    T6_OPTION_NO_INPUT = 1 << 0,    // no command to match
    T6_OPTION_REVERSAL = 1 << 1,    // matches on a hit taken
    T6_OPTION_NO_DAMAGE = 1 << 2,
    T6_OPTION_TRACK = 1 << 3,       // option8 is 0 inside the window, 1 once the entry passes
    T6_OPTION_INPUT = 1 << 4,       // an input window
    T6_OPTION_FIRST_FRAME = 1 << 5,
    T6_OPTION_STOP = 1 << 6,        // the scan ends on this entry
    T6_OPTION_LOCK_SKIP = 1 << 7,   // skipped while the cancel lock is set
    T6_OPTION_BOUND_RESET = 1 << 8, // a move end into a shared move: the fighter's combo is over, its bounds count again
};

// Cancel command, u32 code << 16 | buttons. Also the entry of an input sequence.
typedef struct {
    uint16_t code;  // directions, or 32768.. list end, specials, groups, sequences
    uint16_t buttons;  // buttons
} T6Command;

// T6Command.buttons: bits 0..11 as in the button word, then the mode bits.
enum {
    T6_COMMAND_ANY_PRESS = 1 << 12,         // one of the presses is enough
    T6_COMMAND_HOLD_AFTER_PRESS = 1 << 13,  // presses must be held, and one must be new
    T6_COMMAND_SUMMARY = 1 << 14,           // the buttons half is one of the summaries: no press, no hold, some press, some hold
};

// Cancel record. Table refs are indexes.
typedef struct {
    T6Command command;
    uint32_t requirements;  // first entry in requirements
    uint16_t move;          // move id, or group index for the group code
    uint16_t tracking_pick; // tracking_overrides index + 1 (the pad of the game record), 0 = the move's own tracking
    uint32_t extradata;
    uint16_t window_start;
    uint16_t window_end;
    uint16_t start_frame;
    uint16_t option;        // as the loader computes it
} T6Cancel;

typedef struct {
    uint16_t id;     // list ends at id T6_REQ_END
    uint32_t param;  // TK6: 32 bits (a compare id, an instant property's value)
} T6Requirement;

// Input sequence: `count` commands from input_extras[first], oldest first.
typedef struct {
    uint16_t window;  // how many past input frames are searched for the sequence
    uint16_t count;
    uint32_t first;  // index of the first command in input_extras
} T6InputSequence;

// Pushback entry.
typedef struct {
    uint16_t frames;        // constant frames
    int16_t distance;       // distance per frame
    uint16_t curve_frames;
    uint16_t padding;
    uint32_t curve;         // first entry in pushback_curves
} T6Pushback;

// The default pushback of the juggle launch: move id, 440, 0, 0, 0, 0, then the 8 curve entries.
extern const uint16_t t6_default_pushback[14];

// Extra move property (the move's list, ends at when 0).
typedef struct {
    uint16_t when;   // frame code, see t6_props_tick
    uint16_t id;     // T6_PROPERTY_BASE + 1..
    uint32_t value;  // TK6: 32 bits
} T6Property;

// An entry of a move's start list, or its end property: the property runs when the requirement holds.
typedef struct {
    uint32_t requirements;
    uint16_t id;
    uint32_t value;
} T6ConditionalProperty;

typedef struct {
    uint32_t requirements;
    uint16_t damage, padding;  // damage: the points (low 14 bits), and the reaction rule (T6ReactionRule) above them
    uint32_t reaction;
} T6HitCondition;

enum { HIT_CONDITION_DAMAGE_BITS = 14 };
[[nodiscard]] static inline int16_t t6_hit_condition_damage(const T6HitCondition *condition) {
    return (int16_t)(condition->damage % (1 << HIT_CONDITION_DAMAGE_BITS));
}
[[nodiscard]] static inline uint8_t t6_hit_condition_rule(const T6HitCondition *condition) { return (uint8_t)(condition->damage >> HIT_CONDITION_DAMAGE_BITS); }

// Side band record: the sector of a relative angle, see t6_relative_angles.
typedef struct {
    uint16_t offset;  // added to the angle
    uint16_t width_0, width_1, width_2;  // widths of the sectors 0, 1, 2 (sector 3 is the rest)
} T6SideBand;

typedef struct {
    uint32_t aliases[T6_ALIAS_COUNT];  // live alias table
    int32_t move_count;
    T6Move *moves;
    T6Cancel *cancels;
    int32_t cancel_count;
    T6Cancel *group_cancels;
    int32_t group_cancel_count;
    T6Requirement *requirements;
    int32_t requirement_count;
    T6InputSequence *input_sequences;  // sequence command code + i
    int32_t input_sequence_count;
    uint16_t *input_joints;            // per sequence, bit k: key k follows key k - 1 directly (':'); NULL: none, as in sim files
    T6Command *input_extras;
    int32_t input_extra_count;
    uint32_t *id_pool;                 // compare ids, 0-terminated runs (reqs 123, 218, 296)
    int32_t id_pool_count;
    uint32_t alias_defaults[T6_ALIAS_COUNT];  // (the alias restore properties restore them)
    T6Pushback *pushbacks;
    int32_t pushback_count;
    uint16_t *pushback_curves;
    int32_t pushback_curve_count;
    T6Property *properties;            // T6Move.extra_props indexes it
    int32_t property_count;
    T6ConditionalProperty *start_properties;  // T6Move.start_props indexes it
    int32_t start_property_count;
    T6ConditionalProperty *end_properties;    // T6Move.end_prop indexes it
    int32_t end_property_count;
    uint32_t *voiceclips;              // T6Move.voiceclips indexes it; T6_VOICECLIP_END ends a list
    int32_t voiceclip_count;
    T6HitCondition *hit_conditions;
    int32_t hit_condition_count;
    T6SideBand *side_bands;            // 8 records
    int32_t side_band_count;
    T6Reaction *reactions;             // T6HitCondition.reaction indexes it
    int32_t reaction_count;
    T6FacingRow *tracking;             // rows of the tracking table: T6MoveTracking and `PROP_TRACKING` name them; row 0 is hold
    int32_t tracking_count;
    T6MoveTracking *tracking_overrides;  // T6Cancel.tracking_pick names one
    int32_t tracking_override_count;
    T6MoveTracking *fixed_tracking;      // TRACKING_FIXED_*
    int32_t fixed_tracking_count;
    T6Body *body;                        // BODY: one row, the body measures of the character
    int32_t body_count;
    T6BodyPoints *body_points;           // ANCH: one row, the fixed bone points of the character
    int32_t body_point_count;
    T6Gaze *gaze;                        // GAZE: one row, how the character looks at the opponent
    int32_t gaze_count;
    T6BodyRules *body_rules;             // one row or none, with the body
    int32_t body_rule_count;
} T6Motbin;

// The body row of the character; zeros (nothing pushes, no hurtbox) when the file has none.
static inline T6Body t6_motbin_body(const T6Motbin *motbin) { return motbin->body_count > 0 ? motbin->body[0] : (T6Body){}; }
static inline T6BodyRules t6_motbin_body_rules(const T6Motbin *motbin) {
    return motbin->body_rule_count > 0 ? motbin->body_rules[0] : (T6BodyRules){};
}
static inline T6BodyPoints t6_motbin_body_points(const T6Motbin *motbin) {
    if (motbin->body_point_count <= 0) return (T6BodyPoints){};
    T6BodyPoints points = motbin->body_points[0];
    if (points.count > T6_BODY_POINTS) points.count = T6_BODY_POINTS;
    return points;
}

// No row: no tilt, no head turn.
static inline T6Gaze t6_motbin_gaze(const T6Motbin *motbin) { return motbin->gaze_count > 0 ? motbin->gaze[0] : (T6Gaze){}; }

#endif
