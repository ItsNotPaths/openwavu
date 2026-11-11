// Move properties : the dispatcher, the per-frame list of a move, and the conditional start and end
// properties.
#include "sim/properties.h"

#include <stddef.h>

#include "sim/constants.h"
#include "sim/decide.h"
#include "sim/facing.h"
#include "sim/fighter.h"
#include "sim/hand_poses.h"
#include "sim/hit.h"
#include "sim/math.h"
#include "sim/projectile.h"
#include "sim/requirements.h"
#include "sim/stage.h"
#include "sim/transition.h"
#include "sim/units.h"

// Property ids: T5_PROPERTY_BASE + n. Ids the sim does not list do nothing; the cue ids are the rows of CUE_ROWS.
enum : uint16_t {
    PROP_SELF_DAMAGE_FIRST = T5_PROPERTY_BASE + 59,  // a row of T5_SELF_DAMAGE_ROWS
    PROP_SELF_DAMAGE_LAST = T5_PROPERTY_BASE + 64,
    PROP_VAR_FIRST = T5_PROPERTY_BASE + 66,           // move variables (VAR_PROPS)
    PROP_VAR_LAST = T5_PROPERTY_BASE + 100,
    PROP_STANCE_RULE = T5_PROPERTY_BASE + 102,
    PROP_FORCE_COUNTER = T5_PROPERTY_BASE + 103,
    PROP_COUNTDOWN = T5_PROPERTY_BASE + 104,
    PROP_STOP_TURN = T5_PROPERTY_BASE + 105,
    PROP_HOLD_COUNT = T5_PROPERTY_BASE + 106,
    PROP_THROW_LINKED = T5_PROPERTY_BASE + 108,
    PROP_MOVES_WITH_OPPONENT = T5_PROPERTY_BASE + 109,
    PROP_KEEPS_OWN_HEIGHT = T5_PROPERTY_BASE + 110,
    PROP_HIDES_ATTACK = T5_PROPERTY_BASE + 111,
    PROP_KEEPS_THROW_IMMUNE = T5_PROPERTY_BASE + 112,
    PROP_TRACKING = T5_PROPERTY_BASE + 113,           // a row of the tracking table
    PROP_STATE = T5_PROPERTY_BASE + 115,
    PROP_HIT_LEVEL = T5_PROPERTY_BASE + 116,
    PROP_PIVOT_BONE = T5_PROPERTY_BASE + 117,
    PROP_PUSH = T5_PROPERTY_BASE + 118,               // 0: no push between the fighter and its target
    PROP_PUSH_WEIGHT = T5_PROPERTY_BASE + 119,
    PROP_SOUND_MASK = T5_PROPERTY_BASE + 120,
    PROP_HIP_DROP_FROM_OPPONENT = T5_PROPERTY_BASE + 122,
    PROP_LIMBS_OFF = T5_PROPERTY_BASE + 124,
    PROP_PUSHBACK_HEADING = T5_PROPERTY_BASE + 125,   // the heading the pushback starts with: the body yaw + value
    PROP_CLAIMS_STAGE_OBJECT = T5_PROPERTY_BASE + 126,
    PROP_NO_SPARK = T5_PROPERTY_BASE + 129,
    PROP_REACTION_TURNED = T5_PROPERTY_BASE + 130,
    PROP_REACTION_LOOK = T5_PROPERTY_BASE + 131,
    PROP_WALL_SLIDE_MODE = T5_PROPERTY_BASE + 132,
    PROP_CAN_LOCK_LOOK = T5_PROPERTY_BASE + 133,
    PROP_NO_REAIM = T5_PROPERTY_BASE + 134,
    PROP_USE_ANGLE_84 = T5_PROPERTY_BASE + 135,
    PROP_START_FRAME = T5_PROPERTY_BASE + 136,        // ..147: the start frame word of a TRANSITION_PARAM change
    PROP_START_AFTER_NOW = T5_PROPERTY_BASE + 137,
    PROP_START_BEFORE_NOW = T5_PROPERTY_BASE + 138,
    PROP_START_AFTER_FRAME = T5_PROPERTY_BASE + 139,
    PROP_START_BEFORE_FRAME = T5_PROPERTY_BASE + 140,
    PROP_START_AFTER_NOW2 = T5_PROPERTY_BASE + 141,
    PROP_START_BEFORE_NOW2 = T5_PROPERTY_BASE + 142,
    PROP_START_AFTER_FRAME2 = T5_PROPERTY_BASE + 143,
    PROP_START_BEFORE_FRAME2 = T5_PROPERTY_BASE + 144,
    PROP_START_RANDOM = T5_PROPERTY_BASE + 145,
    PROP_START_RANDOM_AFTER_NOW = T5_PROPERTY_BASE + 146,
    PROP_START_RANDOM_AFTER_NOW2 = T5_PROPERTY_BASE + 147,
    PROP_FORCE_MOVE = T5_PROPERTY_BASE + 148,         // the target takes move `value` of the fighter
    PROP_FORCE_MOVE_IN_PLACE = T5_PROPERTY_BASE + 149,
    PROP_SPEED = T5_PROPERTY_BASE + 150,
    PROP_SPEED_ADD = T5_PROPERTY_BASE + 151,
    PROP_TARGET_SPEED = T5_PROPERTY_BASE + 152,
    PROP_TARGET_SPEED_ADD = T5_PROPERTY_BASE + 153,
    PROP_SPEED_MAX = T5_PROPERTY_BASE + 154,
    PROP_SPEED_MIN = T5_PROPERTY_BASE + 155,
    PROP_OVERWRITE_MOVE = T5_PROPERTY_BASE + 156,
    PROP_ALTERNATE_TO_FRAME = T5_PROPERTY_BASE + 157,
    PROP_ALTERNATE_MOVE = T5_PROPERTY_BASE + 158,
    PROP_ALTERNATE_BLEND_LENGTH = T5_PROPERTY_BASE + 159,
    PROP_BLEND_LENGTH = T5_PROPERTY_BASE + 160,
    PROP_SCALE_XZ_ADD = T5_PROPERTY_BASE + 161,
    PROP_CLEAR_AIR_MOVE = T5_PROPERTY_BASE + 162,
    PROP_PUSHBACK = T5_PROPERTY_BASE + 163,
    PROP_PUSHBACK_FROM_WALL = T5_PROPERTY_BASE + 164,
    PROP_PUSHBACK_FROM_TARGET = T5_PROPERTY_BASE + 165,
    PROP_PUSHBACK_FROM_FACING = T5_PROPERTY_BASE + 166,
    PROP_GRAVITY = T5_PROPERTY_BASE + 167,            // stops the fall; 0 also turns gravity off
    PROP_TARGET_PUSHBACK = T5_PROPERTY_BASE + 168,
    PROP_TARGET_PUSHBACK_FROM_WALL = T5_PROPERTY_BASE + 169,
    PROP_TARGET_PUSHBACK_FROM_TARGET = T5_PROPERTY_BASE + 170,
    PROP_TARGET_TAKES_PUSHBACK = T5_PROPERTY_BASE + 171,        // the target takes the fighter's pushback record
    PROP_TARGET_TAKES_PUSHBACK_STATE = T5_PROPERTY_BASE + 172,  // the target takes the fighter's running pushback
    PROP_HITSCAN_START = T5_PROPERTY_BASE + 173,
    PROP_HITSCAN_STOP = T5_PROPERTY_BASE + 174,
    PROP_PROJECTILE_START = T5_PROPERTY_BASE + 175,
    PROP_PROJECTILE_FRAMES = T5_PROPERTY_BASE + 176,
    PROP_VELOCITY_Y = T5_PROPERTY_BASE + 179,
    PROP_FLOAT = T5_PROPERTY_BASE + 184,              // stops the fall and turns gravity off
    PROP_DRIFT_SPEED = T5_PROPERTY_BASE + 185,
    PROP_DRIFT_ANGLE = T5_PROPERTY_BASE + 186,
    PROP_DRIFT_ANGLE_ABSOLUTE = T5_PROPERTY_BASE + 187,
    PROP_TURN = T5_PROPERTY_BASE + 188,
    PROP_TARGET_TURN = T5_PROPERTY_BASE + 189,
    PROP_SPIN_FRAMES = T5_PROPERTY_BASE + 190,
    PROP_SPIN_SPEED = T5_PROPERTY_BASE + 191,
    PROP_HEIGHT = T5_PROPERTY_BASE + 192,
    PROP_HEIGHT_ADD = T5_PROPERTY_BASE + 193,
    PROP_HEIGHT_OVER_FLOOR = T5_PROPERTY_BASE + 194,
    PROP_SWAY_SCALE = T5_PROPERTY_BASE + 197,
    PROP_SKIP_MOTION = T5_PROPERTY_BASE + 201,
    PROP_TARGET_SKIP_MOTION = T5_PROPERTY_BASE + 203,
    PROP_SIDE_BAND_TABLE = T5_PROPERTY_BASE + 204,
    PROP_MOVE_FINISHED = T5_PROPERTY_BASE + 205,
    PROP_OTHER_POSE_TOGGLE = T5_PROPERTY_BASE + 225,  // the second other channel, on or off
    PROP_CLEAR_HISTORY = T5_PROPERTY_BASE + 226,
    PROP_MARKS_ZERO_DAMAGE = T5_PROPERTY_BASE + 233,
    PROP_UPDATE_DIVIDER = T5_PROPERTY_BASE + 241,
    PROP_TARGET_UPDATE_DIVIDER = T5_PROPERTY_BASE + 242,
    PROP_SCENE_TURN = T5_PROPERTY_BASE + 259,
    PROP_ALIAS_SET_FIRST = T5_PROPERTY_BASE + 263,      // alias i = value
    PROP_ALIAS_SET_LAST = T5_PROPERTY_BASE + 295,
    PROP_ALIAS_RESTORE_FIRST = T5_PROPERTY_BASE + 296,  // alias i back to its default
    PROP_ALIAS_RESTORE_LAST = T5_PROPERTY_BASE + 328,
    PROP_OTHER_POSE_FIRST = T5_PROPERTY_BASE + 337,     // the two other channels
    PROP_OTHER_POSE_LAST = T5_PROPERTY_BASE + 338,
    PROP_FACE_FIRST = T5_PROPERTY_BASE + 343,           // the face layer
    PROP_FACE_LAST = T5_PROPERTY_BASE + 344,
    PROP_THROW_WALL_HIT = T5_PROPERTY_BASE + 351,
    PROP_BASE_TO_ANCHOR = T5_PROPERTY_BASE + 353,
};

// (fcmpu order: NaN takes the first branch)
static float wrap_pi(float angle) {
    if (!(angle <= T5_PI)) return angle - T5_TWO_PI;  // above pi (or NaN): wrap down one turn
    if (angle < -T5_PI) return angle + T5_TWO_PI;  // below minus pi: wrap up one turn
    return angle;
}

// Facing and move yaw += value, body yaw += value (65535 steps per turn).
static void turn(T5Fighter *fighter, uint16_t value) {
    fighter->facing = (int16_t)(fighter->facing + value);  // value is a turn in 65535 steps per full turn; wraps as 16 bits
    fighter->move_yaw = (int16_t)(fighter->move_yaw + value);
    fighter->body_yaw = wrap_pi(t5_angle65535_to_rad((int16_t)value) + fighter->body_yaw);
}

// A homing code on a move that cannot hit turns to the target instead; a carry onto active frames still ahead homes
// softly. f's pending move is the move the word starts.
uint16_t t5_transition_filter(const T5World *w, const T5Fighter *f, uint16_t transition) {
    uint8_t code = t5_transition_code(transition);
    bool homing = code >= MOTION_HOMING_FIRST && code <= MOTION_HOMING_LAST;  // the move's motion code is one of the homing codes
    const T5Move *pending = t5_move_at(w, f->pending_move);  // the move this transition is about to start
    if (t5_transition_class(transition) == TRANSITION_CARRY) {  // carry: the next move keeps going from the current frame
        bool hits_ahead = pending->first_active != 0 &&  // the pending move has hit frames still coming
            f->pending_frame + 1 < pending->last_active && pending->last_active <= pending->length;
        if (hits_ahead && homing) return transition;  // already homing and a hit is coming: keep it
        if (hits_ahead) return t5_transition_recode(transition, MOTION_HOMING_FIRST);  // hit coming: swap in the soft homing code
        if (!homing) return transition;  // no hit ahead and not homing: nothing to change
    } else if (!t5_motion_homes(code) ||  // plain start: only a homing code on a move with no hit frames is rewritten
        pending->first_active != 0) {
        return transition;
    }
    return t5_transition(TRANSITION_START,  // homing with nothing to hit: just turn to face the target
        START_YAW_TO_REFERENCE, MOTION_TURN_TO_TARGET);
}

// Frame speed, max tested first.
static void set_speed(T5Fighter *fighter, int32_t speed) {
    if (speed > fighter->speed_max) speed = fighter->speed_max;  // the max wins if the limits cross
    else if (speed < fighter->speed_min) speed = fighter->speed_min;
    fighter->speed = speed;
}

// The fighter takes `pushback_ref`; its curve cursor starts in the same move data.
static void take_pushback(const T5World *w, T5Fighter *fighter, T5Ref pushback_ref) {
    const T5Pushback *pushback = t5_pushback_at(w, pushback_ref);
    fighter->pushback = pushback_ref;
    fighter->pushback_curve =  // the curve is in the same move set as the pushback entry
        t5_ref(pushback_ref.set, pushback->curve);
    fighter->pushback_frames = (int16_t)pushback->frames;  // how long the shove lasts
    fighter->pushback_distance = (float)pushback->distance;
    fighter->pushback_curve_frames = (int16_t)pushback->curve_frames;
}

void t5_force_move(const T5World *w, T5Fighter *f, T5Fighter *target, uint16_t id, bool in_place) {
    target->pending_id = (int16_t)id;  // queue move `id` on the target, as if it chose it
    target->moveset = f->moveset;  // the target uses the attacker's move set for this move
    target->pending_move = t5_move_lookup(w, f, id);
    target->pending_id_high = 0;
    target->pending_flags = (T5PendingFlags){.no_root_fix = in_place};  // in_place: the target is not moved by root fixing
    target->pick_kind = PICKED_CANCEL;  // the move starts like a cancel
    target->transition = t5_transition(TRANSITION_START, START_YAW_TO_FACING, MOTION_NONE);
    target->pending_frame = 1;  // start on the first frame
    target->frame = 1;
}

// The slot's overwrite entry, made on its first overwrite; NULL when the table is full.
static T5MoveOverwrite *overwrite_entry(const T5World *w, T5Ref move_ref) {
    T5Fighter *owner = w->fighters[move_ref.set];
    int32_t edited = t5_move_overwrite(owner, move_ref.index);
    if (edited >= 0) return &owner->move_overwrites[edited];
    if (owner->move_overwrite_count == T5_MOVE_OVERWRITE_COUNT) return NULL;
    T5MoveOverwrite *entry = &owner->move_overwrites[owner->move_overwrite_count];
    *entry = (T5MoveOverwrite){move_ref.index, *t5_move_at(w, move_ref)};  // the loaded move: read before the count grows
    owner->move_overwrite_count++;
    return entry;
}

// Move `value` takes the current move's data except its anim, and becomes the current move. Its tracking stays: cancels
// into it name overrides against it. The game writes the move record in the loaded move data; the port keeps the edit
// in the overwrite table of the set's fighter, so it lasts for the round. A full table drops the edit.
static void overwrite_move(const T5World *w, T5Fighter *f, uint16_t value) {
    T5Ref move_ref = t5_move_lookup(w, f, value);
    T5MoveOverwrite *entry = overwrite_entry(w, move_ref);
    if (entry) {
        T5Move current = *t5_move_at(w, f->move);  // copy the whole current move over slot `value`
        current.anim = entry->move.anim;
        current.tracking = entry->move.tracking;
        entry->move = current;
    }
    f->move = move_ref;
    f->anim_move = move_ref;  // the animation now plays from the moved slot
}

// --- move variables: one row per property

enum VarOwner : uint8_t { OWN_VAR, TARGET_VAR };
enum VarWrite : uint8_t { VAR_SET, VAR_ADD, VAR_SUBTRACT, VAR_OR, VAR_AND, VAR_NOW2_PLUS, VAR_MINUS_NOW2, VAR_NOW_PLUS, VAR_MINUS_NOW };

typedef struct {
    enum VarOwner owner;
    enum T5MoveVar var;
    enum VarWrite write;
} VarProp;

static const VarProp VAR_PROPS[PROP_VAR_LAST - PROP_VAR_FIRST + 1] = {
    {OWN_VAR, MOVE_VAR_COUNT_UP_A, VAR_SET}, {OWN_VAR, MOVE_VAR_COUNT_DOWN_A, VAR_SET}, {OWN_VAR, MOVE_VAR_COUNT_DOWN_B, VAR_SET},
    {TARGET_VAR, MOVE_VAR_COUNT_UP_A, VAR_SET}, {TARGET_VAR, MOVE_VAR_COUNT_DOWN_A, VAR_SET}, {TARGET_VAR, MOVE_VAR_COUNT_DOWN_B, VAR_SET},
    {OWN_VAR, MOVE_VAR_D, VAR_SET}, {OWN_VAR, MOVE_VAR_D, VAR_ADD}, {OWN_VAR, MOVE_VAR_D, VAR_SUBTRACT},
    {OWN_VAR, MOVE_VAR_LOCAL, VAR_SET}, {OWN_VAR, MOVE_VAR_LOCAL, VAR_ADD}, {OWN_VAR, MOVE_VAR_LOCAL, VAR_SUBTRACT},
    {OWN_VAR, MOVE_VAR_E, VAR_SET}, {OWN_VAR, MOVE_VAR_E, VAR_ADD}, {OWN_VAR, MOVE_VAR_E, VAR_SUBTRACT}, {OWN_VAR, MOVE_VAR_E, VAR_OR},
    {OWN_VAR, MOVE_VAR_E, VAR_AND},
    {OWN_VAR, MOVE_VAR_COUNT_UP_B, VAR_SET}, {OWN_VAR, MOVE_VAR_COUNT_UP_B, VAR_ADD}, {OWN_VAR, MOVE_VAR_COUNT_UP_B, VAR_SUBTRACT},
    {OWN_VAR, MOVE_VAR_COUNT_UP_B, VAR_NOW2_PLUS}, {OWN_VAR, MOVE_VAR_COUNT_UP_B, VAR_MINUS_NOW2},
    {OWN_VAR, MOVE_VAR_COUNT_UP_B, VAR_NOW_PLUS}, {OWN_VAR, MOVE_VAR_COUNT_UP_B, VAR_MINUS_NOW},
    {OWN_VAR, MOVE_VAR_G, VAR_SET}, {OWN_VAR, MOVE_VAR_G, VAR_ADD}, {OWN_VAR, MOVE_VAR_G, VAR_SUBTRACT},
    {TARGET_VAR, MOVE_VAR_D, VAR_SET}, {TARGET_VAR, MOVE_VAR_D, VAR_ADD}, {TARGET_VAR, MOVE_VAR_D, VAR_SUBTRACT},
    {TARGET_VAR, MOVE_VAR_E, VAR_SET}, {TARGET_VAR, MOVE_VAR_E, VAR_ADD}, {TARGET_VAR, MOVE_VAR_E, VAR_SUBTRACT},
    {TARGET_VAR, MOVE_VAR_E, VAR_OR}, {TARGET_VAR, MOVE_VAR_E, VAR_AND},
};

// The new value of a variable (old_value). The frame writes read the fighter f who runs the property.
static uint16_t var_written(enum VarWrite write, uint16_t old_value, uint16_t value, const T5Fighter *f) {
    switch (write) {
    case VAR_SET: return value;
    case VAR_ADD: return (uint16_t)(old_value + value);
    case VAR_SUBTRACT: return (uint16_t)(old_value - value);
    case VAR_OR: return old_value | value;
    case VAR_AND: return old_value & value;
    case VAR_NOW2_PLUS: return (uint16_t)(f->frame2 + value);  // the frame writes use the running fighter's own frame counters
    case VAR_MINUS_NOW2: return (uint16_t)(value - f->frame2);
    case VAR_NOW_PLUS: return (uint16_t)(f->frame + value);
    case VAR_MINUS_NOW: return (uint16_t)(value - f->frame);
    }
    return old_value;
}

static void var_prop(T5Fighter *f, T5Fighter *target, uint16_t id, uint16_t value) {
    VarProp row = VAR_PROPS[id - PROP_VAR_FIRST];  // the property id picks the row: whose variable and how it is written
    T5Fighter *fighter = f;
    if (row.owner == TARGET_VAR) fighter = target;  // some rows write the opponent's variable
    t5_set_move_var(fighter, row.var, var_written(row.write, t5_move_var(fighter, row.var), value, f));
}

// --- fields a property sets


static bool flag_prop(T5Fighter *f, T5Fighter *target, uint16_t id, uint16_t value) {
    uint8_t byte_value = (uint8_t)value;
    int16_t signed_value = (int16_t)value;
    switch (id) {
    case PROP_STANCE_RULE: f->stance_rule = byte_value; break;  // sets how the stance is found
    case PROP_FORCE_COUNTER: f->force_counter_hit = signed_value; break;  // forces a counter hit value
    case PROP_COUNTDOWN: f->countdown = signed_value; break;  // tracking gate countdown
    case PROP_STOP_TURN:  // cancels any scripted turn in progress
        f->turn_speed = 0;  // stop the scripted turn speed
        f->turn_frames = 0;  // and its remaining frames
        break;
    case PROP_HOLD_COUNT: f->hold_count = signed_value; break;  // hold counter
    case PROP_THROW_LINKED: f->throw_linked = byte_value; break;  // marks the throw as linked
    case PROP_MOVES_WITH_OPPONENT: f->moves_with_opponent = byte_value; break;  // the fighter moves along with the opponent
    case PROP_KEEPS_OWN_HEIGHT: f->keeps_own_height = byte_value; break;  // in a throw the fighter keeps their own height
    case PROP_HIDES_ATTACK: f->hides_attack = byte_value; break;  // hides that an attack is coming
    case PROP_KEEPS_THROW_IMMUNE: f->keeps_throw_immune = byte_value; break;  // stays immune to throws
    case PROP_STATE:
        f->state = value;  // the fighter's body state is set to value
        f->state_copy = value;  // the copy of the state gets it too
        f->state_class = t5_state_class(value);  // class comes from the state's high bits
        break;
    case PROP_HIT_LEVEL: f->hit_level = value; break;  // the heights this move hits (high, mid, low)
    case PROP_PIVOT_BONE: f->pivot_bone = signed_value; break;  // the bone the turn pivots around (-1 none)
    case PROP_PUSH:
        f->no_push = value == 0;  // value 0 turns pushing off for both fighters
        target->no_push = value == 0;  // the target gets the same setting
        break;
    case PROP_PUSH_WEIGHT: f->push_weight = signed_value; break;  // how hard the fighter pushes (4096 is full)
    case PROP_SOUND_MASK:
        f->sound_mask = 0;  // any nonzero value sets the mask to 2
        if (value != 0) f->sound_mask = 2;  // sound on
        break;
    case PROP_HIP_DROP_FROM_OPPONENT:  // the hip drop target comes from the opponent
        f->hip_drop_from_opponent = byte_value; break;
    case PROP_LIMBS_OFF: f->limbs_off = byte_value; break;  // limbs switched off
    case PROP_CLAIMS_STAGE_OBJECT: f->claims_stage_object = byte_value; break;  // the fighter claims a stage object
        break;
    case PROP_NO_SPARK: f->no_spark = byte_value; break;  // no hit spark
    case PROP_REACTION_TURNED:  // nonzero: a reaction starts turned; zero: facing the hit
        f->reaction_facing = REACTION_FACING_HIT;
        if (value != 0) f->reaction_facing = REACTION_FACING_TURNED;  // turned instead
        break;
    case PROP_REACTION_LOOK:  // nonzero: a reaction starts looking at the attacker; zero: facing the hit
        f->reaction_facing = REACTION_FACING_HIT;
        if (value != 0) f->reaction_facing = REACTION_FACING_LOOK;  // look at the attacker instead
        break;
    case PROP_WALL_SLIDE_MODE: f->wall_slide_mode = signed_value; break;  // how the fighter slides along a wall
    case PROP_CAN_LOCK_LOOK: f->can_lock_look = byte_value; break;  // the look-at may lock on
    case PROP_NO_REAIM: f->no_reaim = byte_value; break;  // no re-aim at the target
    case PROP_USE_ANGLE_84: f->use_angle_84 = byte_value; break;  // use the angle 84 field
    case PROP_ALTERNATE_TO_FRAME: f->alternate_to_frame = byte_value; break;  // the alternate blend samples frame value - 1
    case PROP_ALTERNATE_BLEND_LENGTH:  // blend length in frames to the alternate move
        f->alternate_blend_length = byte_value; break;
    case PROP_BLEND_LENGTH: f->blend_length_override = signed_value; break;  // overrides the blend length
    case PROP_CLEAR_AIR_MOVE: f->air_move = 0; break;  // the move no longer counts as an air move
    case PROP_DRIFT_ANGLE:
    case PROP_DRIFT_ANGLE_ABSOLUTE:
        f->drift_angle = signed_value;  // the drift direction
        f->drift_absolute = id == PROP_DRIFT_ANGLE_ABSOLUTE;  // absolute: the angle is the world heading, not relative
        break;
    case PROP_SPIN_FRAMES: f->spin_frames = signed_value; break;  // how long the spin lasts
    case PROP_SPIN_SPEED: f->spin_speed = signed_value; break;  // how fast the spin is
    case PROP_SKIP_MOTION: f->skip_motion = byte_value; break;  // the fighter's motion step is skipped
    case PROP_TARGET_SKIP_MOTION: target->skip_motion = byte_value; break;  // the opponent's motion step is skipped
    case PROP_SIDE_BAND_TABLE: f->side_band_table = byte_value; break;  // which side band table to use
    case PROP_MOVE_FINISHED: f->marked_finished = byte_value; break;  // marks the move as finished
    case PROP_MARKS_ZERO_DAMAGE: f->marks_zero_damage = byte_value; break;  // a hit of 0 damage still marks the defender
    case PROP_UPDATE_DIVIDER:  // slow motion: updates only every value-th frame (-1 inactive)
        f->update_divider = signed_value; break;
    case PROP_TARGET_UPDATE_DIVIDER: target->update_divider = signed_value; break;  // same for the opponent
    case PROP_THROW_WALL_HIT:  // a throw already marked as wall hit (1) keeps the mark
        if (!(t5_in_throw(f->throw.chain) && f->throw.wall_hit == 1)) f->throw.wall_hit = signed_value;  // set the wall hit mark
        break;
    default: return false;
    }
    return true;
}

// The start frame word of the next TRANSITION_PARAM change.
static bool start_frame_prop(T5World *w, T5Fighter *f, uint16_t id, uint16_t value) {
    switch (id) {
    case PROP_START_FRAME: f->start_param = value; break;  // the start frame word is value as is
    case PROP_START_AFTER_NOW: f->start_param = (uint16_t)(f->frame + value); break;  // frame now plus value
    case PROP_START_BEFORE_NOW: f->start_param = (uint16_t)(f->frame - value); break;  // frame now minus value
    case PROP_START_AFTER_FRAME: f->start_param = (uint16_t)(value + START_PARAM_AFTER_FRAME); break;  // a fixed frame, after it
    case PROP_START_BEFORE_FRAME:  // a fixed frame, before it
        f->start_param = (uint16_t)(value + START_PARAM_BEFORE_FRAME); break;
    case PROP_START_AFTER_NOW2: f->start_param = (uint16_t)(f->frame2 + value); break;  // second counter plus value
    case PROP_START_BEFORE_NOW2: f->start_param = (uint16_t)(f->frame2 - value); break;
    case PROP_START_AFTER_FRAME2:  // a fixed frame of the second counter, after it
        f->start_param = (uint16_t)(value + START_PARAM_AFTER_FRAME2); break;
    case PROP_START_BEFORE_FRAME2:  // a fixed frame of the second counter, before it
        f->start_param = (uint16_t)(value + START_PARAM_BEFORE_FRAME2); break;
    case PROP_START_RANDOM:  // random 0 up to value; 0 becomes 1
        f->start_param = (uint16_t)t5_rand_n(&w->rng, value);  // random pick below value, from the match rng
        if (f->start_param == 0) f->start_param = 1;
        break;
    case PROP_START_RANDOM_AFTER_NOW:  // frame now plus a random pick below value
        f->start_param = (uint16_t)(f->frame + t5_rand_n(&w->rng, value)); break;
    case PROP_START_RANDOM_AFTER_NOW2:  // second counter plus a random pick below value
        f->start_param = (uint16_t)(f->frame2 + t5_rand_n(&w->rng, value)); break;
    default: return false;
    }
    return true;
}

// Moves, speed and pushback.
static bool move_prop(const T5World *w, T5Fighter *f, T5Fighter *target, uint16_t id, uint16_t value) {
    int16_t signed_value = (int16_t)value;
    switch (id) {
    case PROP_TRACKING:  // starts tracking with row `value` of the move set's tracking table
        f->facing_state = t5_facing_begin(w, f->move.set, (uint8_t)value); break;
    case PROP_FORCE_MOVE:  // the target is forced into move value of this fighter
        t5_force_move(w, f, target, value, false); break;
    case PROP_FORCE_MOVE_IN_PLACE:  // same, but the target is not moved by root fixing
        t5_force_move(w, f, target, value, true); break;
    case PROP_SPEED: set_speed(f, signed_value); break;  // playback speed of the move
    case PROP_SPEED_ADD: set_speed(f, f->speed + signed_value); break;  // speed is limited by the max and min
    case PROP_TARGET_SPEED: set_speed(target, signed_value); break;  // the opponent's speed, limited by their own max and min
    case PROP_TARGET_SPEED_ADD: set_speed(target, target->speed + signed_value); break;  // the opponent's speed plus value
    case PROP_SPEED_MAX: f->speed_max = signed_value; break;  // upper speed limit
    case PROP_SPEED_MIN: f->speed_min = signed_value; break;  // lower speed limit
    case PROP_OVERWRITE_MOVE: overwrite_move(w, f, value); break;  // copy this move over move value (see overwrite_move)
    case PROP_ALTERNATE_MOVE:  // a move to blend to later
        f->alternate_move = t5_move_lookup(w, f, value);
        f->alternate_from_frame = (uint8_t)f->frame;  // remember the frame the alternate was set on
        break;
    case PROP_PUSHBACK:  // the shove (distance, frames, curve) is entry `value` of the move set
        take_pushback(w, f, t5_ref(f->moveset, value)); break;
    case PROP_TARGET_PUSHBACK: take_pushback(w, target, t5_ref(f->moveset, value)); break;  // the opponent gets shove entry value
    case PROP_TARGET_TAKES_PUSHBACK:  // the opponent gets this fighter's shove record
        if (!t5_ref_none(f->pushback)) take_pushback(w, target, f->pushback);  // only when the fighter has a pushback
        break;
    case PROP_TARGET_TAKES_PUSHBACK_STATE:  // copies the running shove, not the record
        target->pushback_curve_frames = f->pushback_curve_frames;  // copy the curve length
        target->pushback_curve = f->pushback_curve;  // copy the curve position
        target->pushback_frames = f->pushback_frames;  // copy the frames left
        target->pushback_distance = f->pushback_distance;  // copy the distance
        break;
    case PROP_PUSHBACK_FROM_WALL:  // shove direction: wall angle plus value
        f->pushback_angle = (int16_t)(f->wall_angle + value); break;
    case PROP_PUSHBACK_FROM_TARGET:  // shove direction: away from the target (half turn from it) plus value
        f->pushback_angle = t5_angle_offset((int16_t)(f->target_angle + value), HALF_TURN); break;
    case PROP_PUSHBACK_FROM_FACING:  // shove direction: facing plus value
        f->pushback_angle = (int16_t)(f->facing + value); break;
    case PROP_TARGET_PUSHBACK_FROM_WALL:  // the target's shove direction: wall angle plus value
        target->pushback_angle = (int16_t)(f->wall_angle + value); break;
    case PROP_TARGET_PUSHBACK_FROM_TARGET:  // the target's shove direction: away from the fighter, plus value
        target->pushback_angle = t5_angle_offset((int16_t)(f->target_angle + value), HALF_TURN); break;
    default: return false;
    }
    return true;
}

// A pushback entry of the moveset becomes the script of a shot.
static T5SpecialScript script_of(const T5World *w, const T5Fighter *f, uint16_t value) {
    const T5Pushback *pushback = t5_pushback_at(w, t5_ref(f->moveset, value));  // shots reuse pushback entries for their path
    return (T5SpecialScript){t5_ref(f->moveset, pushback->curve), (int16_t)pushback->frames,  // curve, then length in frames
                             (int16_t)pushback->curve_frames, pushback->distance};
}

// The shots of the fighter's rows; a fighter without the row has nothing to start.
static bool shot_prop(const T5World *w, T5Fighter *f, uint16_t id, uint16_t value) {
    const T5Hitscan *hitscan = t5_hitscan_of(f);
    const T5Projectile *projectile = t5_projectile_of(f);
    switch (id) {
    case PROP_HITSCAN_START:
        if (hitscan != nullptr)  // only fighters with a hitscan row (the eye laser)
            f->special = t5_hitscan_start(f, *hitscan, script_of(w, f, value));
        break;
    case PROP_HITSCAN_STOP:
        if (hitscan != nullptr) f->special = t5_hitscan_stop(f, *hitscan);  // ends the beam, if the fighter has one
        break;
    case PROP_PROJECTILE_START:
        if (projectile != nullptr)  // only fighters with a projectile row (the fire)
            f->special = t5_projectile_start(f, *projectile, script_of(w, f, value));
        break;
    case PROP_PROJECTILE_FRAMES:  // sets how many frames the projectile has left
        f->special.projectile.frames_left = (int16_t)value; break;
    default: return false;
    }
    return true;
}

static constexpr float SCALE_UNIT = 4096.0f;  // the scale properties count 1/4096

// Angles, height and velocity.
static bool motion_prop(T5World *w, T5Fighter *f, T5Fighter *target, uint16_t id, uint16_t value) {
    int16_t signed_value = (int16_t)value;
    float y;
    switch (id) {
    case PROP_PUSHBACK_HEADING:
        y = wrap_pi(f->body_yaw);  // body yaw as 0 to a full turn
        if (y < 0.0f) y += T5_TWO_PI;
        f->pushback_angle_start = (int16_t)(t5_rad_to_angle65535(y) + value);  // heading from the body yaw plus value
        break;
    case PROP_SCALE_XZ_ADD: f->scale_xz_add = (float)signed_value / SCALE_UNIT; break;  // extra horizontal body scale, in 1/4096
    case PROP_GRAVITY:  // value 0 turns gravity off, anything else on; the fall stops either way
        f->velocity.y = 0.0f;
        f->no_gravity = value == 0;  // gravity off when value is 0
        break;
    case PROP_VELOCITY_Y: f->velocity.y = (float)signed_value; break;  // vertical speed set directly
    case PROP_FLOAT:  // hangs in the air: no fall, no gravity
        f->velocity.y = 0.0f;
        f->no_gravity = 1;  // gravity off
        break;
    case PROP_DRIFT_SPEED: f->drift_speed = (float)signed_value; break;  // drift speed set directly
    case PROP_TURN: turn(f, value); break;  // turn the fighter by value
    case PROP_TARGET_TURN: turn(target, value); break;  // turns the opponent
    case PROP_HEIGHT:
        f->position.y = (float)signed_value;  // set the height
        f->base_position.y = (float)signed_value;  // the base height too
        break;
    case PROP_HEIGHT_ADD:
        y = f->position.y + (float)signed_value;  // raise or lower by value
        f->base_position.y = (float)signed_value + f->base_position.y;
        if (y < 0.0f) y = 0.0f;  // NaN stays
        f->position.y = y;
        break;
    case PROP_HEIGHT_OVER_FLOOR:
        y = (float)value + t5_stage_floor(w, f->base_position);  // value above the stage floor under the fighter
        f->base_position.y += y - f->position.y;  // base moves by the same shift
        f->position.y = y;
        break;
    case PROP_SWAY_SCALE: f->sway_scale = (float)value / SCALE_UNIT; break;  // floor sway scale, in 1/4096
    case PROP_BASE_TO_ANCHOR:  // after the scripted controller step (not ported), which keeps the position
        f->base_position.x = f->position.x;  // the base follows the fighter's x and z
        f->base_position.z = f->position.z;  // and z
        break;
    default: return false;
    }
    return true;
}

// Battle globals, the input history, the alias table.
static void global_prop(T5World *w, T5Fighter *f, uint16_t id, uint16_t value) {
    T5Motbin *motbin = t5_set_mutable(w, f->data);  // the alias table is live data
    if (id >= PROP_ALIAS_SET_FIRST && id <= PROP_ALIAS_SET_LAST) {
        motbin->aliases[id - PROP_ALIAS_SET_FIRST] = value;  // alias slot gets the value
        return;
    }
    if (id >= PROP_ALIAS_RESTORE_FIRST && id <= PROP_ALIAS_RESTORE_LAST) {
        motbin->aliases[id - PROP_ALIAS_RESTORE_FIRST] =  // alias slot goes back to its original value
            motbin->alias_defaults[id - PROP_ALIAS_RESTORE_FIRST];
        return;
    }
    switch (id) {
    case PROP_SCENE_TURN: w->scene_turn = (int16_t)value; break;  // used at a scene start
    case PROP_CLEAR_HISTORY:
        if (f->kind == T5_KIND_FIGHTER) t5_history_clear(&f->history);  // a fighter wipes their own input history
        else t5_history_clear(NULL);  // other objects: the call with no history
        break;
    default: break;
    }
}

// --- presentation: pose fields and cues

// The pose property sets its layer's field; the presenter plays the channels.
static bool pose_prop(const T5World *w, T5Fighter *f, uint16_t id, uint16_t value) {
    T5PoseProp pose = {id, value, w->frame};  // stamped with the frame it was set
    if (id >= T5_HAND_PROPERTY_FIRST && id <= T5_HAND_PROPERTY_LAST) {  // hand pose: the table says which hands it poses
        T5HandProperty hands = T5_HAND_PROPERTIES[id - T5_HAND_PROPERTY_FIRST];
        if (hands.right) f->right_hand_pose = pose;  // the right hand takes the pose
        if (hands.left) f->left_hand_pose = pose;  // the left hand takes the pose
        f->hands_posed = true;  // the hands now follow pose properties
    } else if (id >= PROP_FACE_FIRST && id <= PROP_FACE_LAST) {  // face pose
        f->face_pose = pose;  // the face takes the pose
        f->face_posed = true;  // the face now follows pose properties
    } else if ((id >= PROP_OTHER_POSE_FIRST && id <= PROP_OTHER_POSE_LAST) ||  // other pose channels, the toggle too
               id == PROP_OTHER_POSE_TOGGLE) f->other_pose = pose;
    else return false;
    return true;
}

// Whose voice bank, body or slot a cue plays on.
enum CueOwner : uint8_t { ON_SELF, ON_TARGET, ON_NOBODY };

typedef struct {
    uint16_t first, last;
    T5PropPass pass;
    T5CueKind kind;
    enum CueOwner owner;
} CueRow;

// The one-shot properties (docs/code-map.md tables B, C, D). A voice passes once until the sound ids clear (t5_sound_once).
static const CueRow CUE_ROWS[] = {
    {T5_PROPERTY_BASE + 1, T5_PROPERTY_BASE + 8, T5_PASS_LOGIC, T5_CUE_CAMERA, ON_NOBODY},      // shakes
    {T5_PROPERTY_BASE + 9, T5_PROPERTY_BASE + 11, T5_PASS_LOGIC, T5_CUE_FX, ON_SELF},
    {T5_PROPERTY_BASE + 13, T5_PROPERTY_BASE + 13, T5_PASS_LOGIC, T5_CUE_FX, ON_SELF},
    {T5_PROPERTY_BASE + 16, T5_PROPERTY_BASE + 16, T5_PASS_LOGIC, T5_CUE_FX, ON_SELF},
    {T5_PROPERTY_BASE + 20, T5_PROPERTY_BASE + 20, T5_PASS_LOGIC, T5_CUE_FX, ON_SELF},
    {T5_PROPERTY_BASE + 21, T5_PROPERTY_BASE + 21, T5_PASS_LOGIC, T5_CUE_FX, ON_TARGET},
    {T5_PROPERTY_BASE + 22, T5_PROPERTY_BASE + 22, T5_PASS_LOGIC, T5_CUE_FX, ON_SELF},
    {T5_PROPERTY_BASE + 23, T5_PROPERTY_BASE + 23, T5_PASS_LOGIC, T5_CUE_FX, ON_TARGET},
    {T5_PROPERTY_BASE + 24, T5_PROPERTY_BASE + 24, T5_PASS_LOGIC, T5_CUE_FX, ON_SELF},
    {T5_PROPERTY_BASE + 25, T5_PROPERTY_BASE + 25, T5_PASS_EFFECTS, T5_CUE_FX, ON_SELF},       // sparks and effects at an anchor
    {T5_PROPERTY_BASE + 27, T5_PROPERTY_BASE + 33, T5_PASS_EFFECTS, T5_CUE_FX, ON_SELF},
    {T5_PROPERTY_BASE + 43, T5_PROPERTY_BASE + 58, T5_PASS_EFFECTS, T5_CUE_FX, ON_SELF},       // and the effect settings before them
    {T5_PROPERTY_BASE + 177, T5_PROPERTY_BASE + 177, T5_PASS_LOGIC, T5_CUE_FX, ON_SELF},
    {T5_PROPERTY_BASE + 221, T5_PROPERTY_BASE + 221, T5_PASS_LOGIC, T5_CUE_SOUND, ON_SELF},
    {T5_PROPERTY_BASE + 222, T5_PROPERTY_BASE + 222, T5_PASS_LOGIC, T5_CUE_SOUND, ON_NOBODY},
    {T5_PROPERTY_BASE + 224, T5_PROPERTY_BASE + 224, T5_PASS_LOGIC, T5_CUE_SOUND, ON_SELF},    // a sound bank
    {T5_PROPERTY_BASE + 243, T5_PROPERTY_BASE + 247, T5_PASS_LOGIC, T5_CUE_FX, ON_SELF},       // auras
    {T5_PROPERTY_BASE + 249, T5_PROPERTY_BASE + 254, T5_PASS_LOGIC, T5_CUE_CAMERA, ON_NOBODY},  // screen fades
    {T5_PROPERTY_BASE + 255, T5_PROPERTY_BASE + 255, T5_PASS_LOGIC, T5_CUE_FX, ON_NOBODY},
    {T5_PROPERTY_BASE + 339, T5_PROPERTY_BASE + 339, T5_PASS_LOGIC, T5_CUE_CAMERA, ON_SELF},   // cinematic camera
    {T5_PROPERTY_BASE + 340, T5_PROPERTY_BASE + 340, T5_PASS_LOGIC, T5_CUE_CAMERA, ON_TARGET},
    {T5_PROPERTY_BASE + 341, T5_PROPERTY_BASE + 341, T5_PASS_LOGIC, T5_CUE_CAMERA, ON_SELF},
    {T5_PROPERTY_BASE + 345, T5_PROPERTY_BASE + 345, T5_PASS_LOGIC, T5_CUE_VOICE, ON_NOBODY},  // the common bank
    {T5_PROPERTY_BASE + 346, T5_PROPERTY_BASE + 346, T5_PASS_LOGIC, T5_CUE_VOICE, ON_SELF},
    {T5_PROPERTY_BASE + 347, T5_PROPERTY_BASE + 347, T5_PASS_LOGIC, T5_CUE_VOICE, ON_TARGET},  // the target's yell
    {T5_PROPERTY_BASE + 348, T5_PROPERTY_BASE + 349, T5_PASS_LOGIC, T5_CUE_SOUND, ON_NOBODY},  // the stage sound picks at random
    {T5_PROPERTY_BASE + 350, T5_PROPERTY_BASE + 350, T5_PASS_LOGIC, T5_CUE_SOUND, ON_SELF},
};

static CueRow cue_row(uint16_t id, T5PropPass pass) {
    for (size_t row_index = 0; row_index < sizeof CUE_ROWS / sizeof *CUE_ROWS; row_index++)
        if (id >= CUE_ROWS[row_index].first && id <= CUE_ROWS[row_index].last &&  // id in the row's range and the same pass
            pass == CUE_ROWS[row_index].pass) return CUE_ROWS[row_index];
    return (CueRow){.kind = T5_CUE_NONE};
}

static void send_cue(T5World *w, T5Cue cue) { t5_cue_add(&w->cues, w->frame, cue); }

// Effect anchors 0x6e..0x73 name these special points.
static const int8_t ANCHOR_SPECIAL[] = {SPECIAL_L_FOOT_LOW, SPECIAL_L_FOOT_HIGH, SPECIAL_R_FOOT_HIGH, SPECIAL_HEAD_AHEAD,
    SPECIAL_CHEST_AHEAD, SPECIAL_CHEST_BEHIND};
enum { ANCHOR_SPECIAL_FIRST = 0x6e };

// Where an effect property plays: a bone of skeleton B or a special point of the fighter, or of its target for the two
// ids that name the target. The ids with a record in the low byte keep the anchor in the high byte.
// (hole effect-anchor-slots :tags (tk5mod effects) :sev polish) anchors 0x6c, 0x6d and 0x74..0x79 name the game's special slots 6..9, which properties 0x80ad..0x80b0 set; the sim has no such slots, so they play at the fighter's base position. tekken 6 as well modules/tk6/sim/properties.c:effect_anchor
static T5Vec3 effect_anchor(const T5World *w, const T5Fighter *f, uint16_t id, uint16_t value) {
    uint16_t offset = (uint16_t)(id - T5_PROPERTY_BASE);
    bool on_target = offset == 0x1d || offset == 0x2c;
    bool high_byte = on_target || offset == 0x1b || offset == 0x2b || offset == 0x3a;
    uint16_t anchor = high_byte ? (uint16_t)(value >> 8) : value;
    const T5Fighter *on = on_target ? t5_object(w, f->target) : f;
    if (on == nullptr) on = f;
    if (anchor < T5_BONES_B) return vec3_of(*(const T5Vec4 *)on->rig.bones_b[anchor].world.m[3]);
    int32_t special = anchor - ANCHOR_SPECIAL_FIRST;
    if (special >= 0 && special < (int32_t)(sizeof ANCHOR_SPECIAL / sizeof *ANCHOR_SPECIAL))
        return vec3_of(on->special.point[ANCHOR_SPECIAL[special]]);
    return on->position;
}

static T5Who owner_of(const T5World *w, const T5Fighter *f, enum CueOwner owner) {
    if (owner == ON_TARGET) return t5_side_of(w, t5_object(w, f->target));  // the cue belongs to the target's side
    if (owner == ON_NOBODY) return T5_NOBODY;  // the cue belongs to nobody
    return t5_side_of(w, f);  // default: the fighter's own side
}

static T5CueKey firing(const T5World *w, const T5Fighter *f, T5PropSource source, int32_t entry) {
    return (T5CueKey){t5_side_of(w, f), source, f->move, entry};  // names which list entry fired, for the presenter
}

void t5_property(T5World *w, uint16_t id, uint16_t value, T5Fighter *f, T5PropPass pass, T5CueKey key) {
    if (id < T5_PROPERTY_BASE) return;  // ids below the base are not properties
    CueRow cue = cue_row(id, pass);
    if (cue.kind == T5_CUE_VOICE && !t5_sound_once(f, (int16_t)value)) return;  // a voice that already played is skipped
    if (cue.kind != T5_CUE_NONE) {
        T5Vec3 position = cue.kind == T5_CUE_FX ? effect_anchor(w, f, id, value) : (T5Vec3){};
        send_cue(w, (T5Cue){cue.kind, id, value,  // presentation only: tell the presenter, change nothing in the sim
            owner_of(w, f, cue.owner), key, position, {}});
        return;
    }
    if (pass != T5_PASS_LOGIC ||  // the effects pass stops here; a pose property is done by pose_prop
        pose_prop(w, f, id, value)) return;
    if (id >= PROP_SELF_DAMAGE_FIRST && id <= PROP_SELF_DAMAGE_LAST) {
        T5SelfDamage row = T5_SELF_DAMAGE_ROWS[id - PROP_SELF_DAMAGE_FIRST];  // the id picks the effect, the value is the points
        row.points = (int16_t)value;  // the points come from the value
        f->self_damage = row;  // this move now hurts or heals its own fighter
        return;
    }
    T5Fighter *target = t5_object(w, f->target);  // the opponent the fighter is aimed at
    if (id >= PROP_VAR_FIRST && id <= PROP_VAR_LAST) {
        var_prop(f, target, id, value);  // move variable properties
        return;
    }
    if (flag_prop(f, target, id, value) || start_frame_prop(w, f, id, value) ||  // try each group until one knows the id
        move_prop(w, f, target, id, value) || shot_prop(w, f, id, value)
        || motion_prop(w, f, target, id, value))
        return;
    global_prop(w, f, id, value);  // everything else
}

static void run_both_passes(T5World *w, uint16_t id, uint16_t value, T5Fighter *f, T5CueKey key) {
    t5_property(w, id, value, f, T5_PASS_EFFECTS, key);  // effects pass first: cues only
    t5_property(w, id, value, f, T5_PASS_LOGIC, key);  // then the pass that changes fighter state
}

void t5_instant_props(T5World *w, T5Fighter *f, const T5Motbin *motbin, int32_t first, T5PropSource source) {
    for (int32_t index = first;  // run each property of the list until the end marker
        motbin->requirements[index].id != T5_REQ_END; index++)
        run_both_passes(w, motbin->requirements[index].id, motbin->requirements[index].param, f, firing(w, f, source, index));
}

// --- the per-frame list of a move (T5Property.when)

enum : uint16_t {
    WHEN_UNTIL = 1 << 13,   // frames up to n
    WHEN_FROM = 1 << 14,    // frames from n on
    WHEN_FRAME2 = 1 << 15,  // frame n of the second counter (second loop)
};

static bool fires(uint16_t when, int32_t frame, bool second_counter) {
    if (second_counter) return (when & WHEN_FRAME2) &&  // second counter loop: only flagged entries, exact frame
        (when & ~WHEN_FRAME2) == frame;
    if (when & WHEN_FROM) return (when & ~WHEN_FROM) <= frame;  // fires on every frame from n on
    if (when & WHEN_UNTIL) return (when & ~WHEN_UNTIL) >= frame;  // fires on every frame up to n
    return !(when & WHEN_FRAME2) && when == frame;  // plain entry: fires on exactly that frame
}

// The entries that fire on `frame`. The list is read again per frame (a prop can change the move).
static void fire_frame(T5World *w, T5Fighter *f, T5PropPass pass, int32_t frame, bool second_counter) {
    const T5Move *move = t5_move_at(w, f->move);
    if (move->extra_props < 0) return;  // the move has no per-frame list
    const T5Property *list = t5_set(w, f->move.set)->properties;  // the move's property list
    for (int32_t index = move->extra_props; list[index].when != 0; index++)  // the list ends at an entry with when 0
        if (fires(list[index].when, frame, second_counter))  // entry fires on this frame
            t5_property(w, list[index].id, list[index].value, f, pass, firing(w, f, T5_FROM_FRAMES, index));
}

// Frames (low, high] from high down, then the same on the second counter.
void t5_props_tick(T5World *w, T5Fighter *f, T5PropPass pass) {
    if (!f->skip_motion && f->update_divider == T5_UPDATE_INACTIVE) return;  // a fighter that does not update runs no properties
    if (t5_move_at(w, f->move)->extra_props < 0) return;
    int16_t first = 0;
    if (f->move_start) first = 1;  // on the first frame of a move, include the frame before so frame 0 entries fire
    int32_t high = f->frame;  // newest frame
    int32_t low = (int16_t)(f->previous_frame - first);  // frames passed since the last update: low is exclusive
    if (high < low && f->speed < 0) {  // playing backward
        int32_t swap = high;  // swap so high is the larger frame
        high = low;
        low = swap;
    }
    for (int32_t frame = high; frame > low; frame--)  // every frame stepped over fires, newest first, so none are skipped
        fire_frame(w, f, pass, frame, false);
    low = (int16_t)(f->previous_frame2 - first);  // same walk for the second counter
    for (int32_t frame = f->frame2; frame > low; frame--) fire_frame(w, f, pass, frame, true);
}

void t5_props_changed(T5World *w, T5Fighter *f) {
    t5_props_tick(w, f, T5_PASS_LOGIC);  // after a move change, run the list again for the new move
}

// --- the conditional properties: the start list and the end property

void t5_start_properties(T5World *w, T5Fighter *f, const T5Fighter *target) {
    const T5Move *move = t5_move_at(w, f->move);
    const T5Motbin *motbin = t5_set(w, f->move.set);
    if (move->start_props < 0) return;  // no start list on this move
    for (int32_t index = move->start_props;  // each entry has a requirement that must pass
        index < motbin->start_property_count; index++) {
        const T5ConditionalProperty *entry = &motbin->start_properties[index];
        const T5Requirement *requirement = &motbin->requirements[entry->requirements];
        if (requirement->id == 0) break;  // a zero requirement ends the list
        if (requirement->id == T5_REQ_END ||  // end marker requirement: always runs; else only if it holds
            t5_requirements(w, requirement, f, target))
            run_both_passes(w, entry->id, entry->value, f, firing(w, f, T5_FROM_START, index));
    }
}

void t5_props_end(T5World *w, T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    if (move->end_prop < 0) return;  // no end property on this move
    const T5Motbin *motbin = t5_set(w, f->move.set);
    const T5ConditionalProperty *entry = &motbin->end_properties[move->end_prop];
    if (!t5_requirements(w, &motbin->requirements[entry->requirements],  // the end property only runs if its requirement holds
                         f, t5_object(w, f->target))) return;
    run_both_passes(w, entry->id, entry->value, f, firing(w, f, T5_FROM_END, move->end_prop));
}

// --- one-shot sounds

enum { SOUND_IDS = 8, SOUND_NONE = -1 };

// Humans only: an id passes once, until the ids are cleared. A full list lets every new id pass.
bool t5_sound_once(T5Fighter *f, int16_t id) {
    if (f->kind != T5_KIND_FIGHTER) return true;  // non-human objects always play
    for (int index = 0; index < SOUND_IDS; index++)
        if (f->sound_ids[index] == id) return false;  // already played: skip
    for (int index = 0; index < SOUND_IDS; index++) {
        if (f->sound_ids[index] == SOUND_NONE) {  // remember it in the first free slot
            f->sound_ids[index] = id;
            break;
        }
    }
    return true;
}

void t5_sound_ids_clear(T5Fighter *f) {
    for (int index = 0; index < SOUND_IDS; index++) f->sound_ids[index] = SOUND_NONE;  // empty all sound slots
}

// The object effect updates are presentation, left out.
void t5_props_pass(T5World *w, bool fighters_blocked, T5PropPass pass) {
    if (fighters_blocked) return;  // no properties while fighters are blocked
    if (pass == T5_PASS_LOGIC)  // once per update the remembered sound ids reset, so a sound can play again
        for (int index = 0; index < T5_FIGHTER_COUNT; index++)  // every fighter forgets the sounds they played
            t5_sound_ids_clear(w->fighters[index]);
    for (int index = 0; index < T5_FIGHTER_COUNT; index++)  // each fighter runs their list
        t5_props_tick(w, w->fighters[index], pass);
}
