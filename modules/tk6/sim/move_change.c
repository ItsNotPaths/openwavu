// The move clock of a fighter, and the change to its pending move: the steps in game order.
#include "sim/move_change.h"

#include <math.h>
#include <stddef.h>

#include "sim/anim.h"
#include "sim/constants.h"
#include "sim/damage.h"
#include "sim/decide.h"
#include "sim/facing.h"
#include "sim/fighter.h"
#include "sim/guard.h"
#include "sim/hit.h"
#include "sim/math.h"
#include "sim/motion.h"
#include "sim/pose.h"
#include "sim/shot.h"
#include "sim/properties.h"
#include "sim/quat.h"
#include "sim/requirements.h"
#include "sim/stage.h"
#include "sim/throw.h"
#include "sim/transition.h"
#include "sim/units.h"

static bool fighter(const T6Fighter *f) { return f->kind == T6_KIND_FIGHTER; }

// --- the clock of a frame without a move change

static void tick_clock(T6Fighter *f, const T6Move *old_move) {
    int16_t frame = f->frame;
    int32_t speed = f->speed;
    int32_t elapsed = f->elapsed + speed;
    int32_t secondary = f->secondary + speed;
    f->move_start = 0;  // no move change this frame
    f->previous_frame2 = f->frame2;
    f->anim_changed = 0;
    f->move_frames++;  // one more frame in this move
    f->frame_9c = (int16_t)(elapsed / CLOCK_PER_FRAME);
    f->frame2 = (int16_t)(secondary / CLOCK_PER_FRAME);
    f->elapsed = elapsed;
    f->secondary = secondary;
    f->previous_frame = frame;
    if (f->hold_count > 0 && old_move->hold_frame == frame) {  // held on the hold frame: count the hold down, the clock stays
        f->hold_count--;
        return;
    }
    if (f->play_direction <= 0 && speed == 0) speed = -1;  // playing backward needs a negative speed
    else if (f->play_direction > 0 && speed <= 0) speed = 1;  // playing forward needs a positive speed
    f->speed = speed;
    int32_t clock = f->clock + speed;  // advance the clock
    f->clock = clock;
    f->frame = (int16_t)(clock / CLOCK_PER_FRAME);
    f->anim_time = (float)clock / (float)CLOCK_PER_FRAME;
    if (f->frame < 1) f->frame = 1;  // keep the frame inside the move
    if (f->frame > old_move->length) f->frame = (int16_t)old_move->length;
    float length = (float)old_move->length;
    if (f->anim_time > length) f->anim_time = length;
    f->anim_time_at_clock = f->anim_time;
    f->frame_changed = (uint16_t)f->previous_frame != (uint16_t)f->frame;  // note whether the frame number moved
}

// --- the move data the change reads

static const T6Cancel *end_entry(const T6Motbin *motbin, const T6Move *new_move) {
    for (uint32_t index = new_move->cancels; index < (uint32_t)motbin->cancel_count; index++)  // find the end entry
        if (motbin->cancels[index].command.code == T6_CANCEL_END) return &motbin->cancels[index];
    return NULL;
}

// The first hit condition whose requirements start with the list end or nothing: the move's own damage and reaction rule.
static const T6HitCondition *plain_hit_condition(const T6Motbin *motbin, const T6Move *new_move) {
    for (uint32_t index = new_move->hit_conditions; index < (uint32_t)motbin->hit_condition_count; index++) {  // scan rules
        uint16_t requirement_id = motbin->requirements[motbin->hit_conditions[index].requirements].id;
        if (requirement_id == T6_REQ_END || requirement_id == 0) return &motbin->hit_conditions[index];  // plain one
    }
    return NULL;
}

// --- steps 1..4: everything the new move resets

static constexpr int32_t SPEED_MAX_DEFAULT = 10 * CLOCK_PER_FRAME;
static constexpr uint16_t OPTION8_UNSEEN = 65535;  // no T6_OPTION_TRACK entry seen yet

static void reset_motion(T6Fighter *f) {
    f->speed = CLOCK_PER_FRAME;
    f->speed_max = SPEED_MAX_DEFAULT;
    f->speed_min = 1;
    f->root_mode = T6_ROOT_GROUND;
    f->approach_state = 0;
    f->hold_count = T6_HOLD_NONE;
    f->play_direction = 1;
    f->turn_total = 0;
    f->drift_speed = 0.0f;
    f->drift_angle = 0;
    f->drift_absolute = 0;
    f->pivot_bone = -1;
    f->spin_frames = 0;
    f->spin_speed = 0;
    f->scale_xz_add = 0.0f;
    f->wall_slide_mode = -1;
    f->no_gravity = 0;
    f->update_divider = T6_UPDATE_INACTIVE;
    f->push_weight = PUSH_WEIGHT_FULL;
}

static void reset_property_bytes(T6Fighter *f) {
    f->stance_rule = 0;
    f->latch_result = 0;
    f->hands_posed = false;
    f->face_posed = false;
    f->throw_linked = 1;
    f->hides_attack = 0;
    f->aims_held_side = 0;
    f->arms_unhittable = 0;
    f->raises_hurtboxes = 0;
    f->push_points_behind = 0;
    f->keeps_throw_immune = 0;
    f->sound_mask = 0;
    f->hip_drop_from_opponent = 0;
    f->limbs_off = 0;
    f->claims_stage_object = 0;
    f->moves_with_opponent = 0;
    f->keeps_own_height = 0;
    f->stage_hit_this_move = 0;
    f->can_lock_look = 1;
    f->no_reaim = 0;
    f->move_local_var = 0;
    f->side_band_table = 0;
    f->use_angle_84 = 0;
    f->no_spark = 0;
    f->marks_zero_damage = 0;
    f->damage_dealt = 0;
    f->alternate_blend_length = 1;
    f->alternate_to_frame = 1;
    f->blend_length_override = -1;
    f->alternate_move = t6_ref(0, -1);
    f->stage_hit_count = 0;
    f->stage_hit_sphere = -1;
    f->option8 = OPTION8_UNSEEN;
    f->hit_lockout = 0;
}

static void reset_for_move(T6World *w, T6Fighter *f, const T6Fighter *opponent, const T6Move *new_move, const T6Cancel *end) {
    if (f->pick_kind == PICKED_AHEAD) f->pending_frame = 1;  // picked ahead: the pending frame is the first
    f->change_frame = (uint16_t)f->frame;  // remember the frame the old move was left on
    f->change_hips = f->pending_flags.root_hips;
    f->change_turn = f->pending_flags.turn;
    if (f->update_divider != T6_UPDATE_INACTIVE) f->skip_motion = 1;  // active update divider: skip the motion this frame
    f->opponent_start_x = t6_fctiwz(opponent->base_position.x);  // remember where the opponent stood at the change
    f->opponent_start_z = t6_fctiwz(opponent->base_position.z);
    f->facing_state = t6_facing_begin(w, f->move.set, 0);  // start facing tracking for the move set
    f->input.latch_asked = T6_BUTTONS_NONE;  // clear the asked button latch
    if (fighter(f)) t6_hit_victims_clear(f);  // forget the victims already hit (fighters only)
    f->throw.camera_category = 0;
    f->throw.chain_before = f->throw.chain;  // remember the throw chain from before the change
    f->can_act_frame = new_move->length;  // by default they can act at the end of the move
    if (end->window_start != 0) f->can_act_frame = end->window_start;  // the end entry can set an earlier frame to act from
    f->roll = (uint16_t)t6_rand(&w->rng);  // roll a random number for this move
    reset_motion(f);  // reset the motion values
    reset_property_bytes(f);  // reset the property values
}

// --- steps 6..8: damage, state words and the contact flags

static void damage_for_move(T6Fighter *f, const T6Motbin *motbin, const T6Move *new_move) {
    if ((int16_t)f->reversal_damage != 0) {  // a reversal sets the damage directly
        f->damage = (int16_t)f->reversal_damage;
        return;
    }
    const T6HitCondition *condition = plain_hit_condition(motbin, new_move);  // find the move's plain hit rule
    if (condition == NULL) return;  // no rule: damage stays
    f->reaction_rule = t6_hit_condition_rule(condition);
    f->damage = t6_hit_condition_damage(condition);
    if (f->reaction_rule == REACT_HARMLESS) f->damage = 0;  // a harmless reaction does no damage
}

// Two moves in a row with T6_MOVE_STATE_4, a clean hit, or a throw keep the hit streak (hit_streak) counting.
static bool streak_goes_on(const T6Fighter *f, const T6Move *old_move, const T6Move *new_move, enum T6TransitionClass transition_class) {
    if (f->clean_hit != 0) return true;  // a clean hit keeps the streak
    if ((old_move->flags & T6_MOVE_STATE_4) && (new_move->flags & T6_MOVE_STATE_4)) return true;  // two state 4 moves in a row
    bool thrown = t6_thrown(f->throw.chain);
    if (thrown && (new_move->flags & T6_MOVE_STATE_4)) return true;
    if (f->streak_clean != 0 || thrown)  // after a clean streak or a throw, only a thrown change keeps it
        return transition_class == TRANSITION_THROWN;
    return false;
}

static void state_for_move(T6Fighter *f, const T6Motbin *motbin, const T6Move *old_move, const T6Move *new_move) {
    damage_for_move(f, motbin, new_move);
    uint32_t vuln = new_move->vuln;
    f->state = vuln;  // the move's vulnerability becomes the state
    t6_state_guard(f);
    f->hit_level = (uint16_t)new_move->hit_level;
    f->state_class = (uint8_t)(t6_state_class(vuln) % STATE_CLASS_COUNT);
    f->attack_kind = (uint8_t)(new_move->hit_level >> 8);  // attack kind is the high byte of the hit level
    f->state_copy = f->state;

    enum T6TransitionClass transition_class = t6_transition_class(f->transition);
    f->was_guarding = f->guarded != 0;  // remember whether they were guarding
    if (f->hit_taken == 0) {  // no hit taken: clear the hit and juggle tracking
        f->stage_hit_power = 0;
        f->launch_flag = 0.0f;
        f->hit_this_move = 0;
        f->juggle_count = 0;
        f->last_hits_damage = 0;
    } else if (transition_class == TRANSITION_THROWER ||
               transition_class == TRANSITION_THROWN) {  // in a throw: only the launch flag clears
        f->launch_flag = 0.0f;
    }
    if (f->hit_landed == 0) f->landed_this_move = 0;  // no hit landed: clear the landed mark
    uint8_t clean = f->clean_hit;
    f->landed_since_move_start = 0;
    if (streak_goes_on(f, old_move, new_move, transition_class)) {  // streak goes on: count it
        f->hit_streak++;
        f->streak_clean = clean;
    } else {  // streak ends: reset it
        f->streak_clean = 0;
        f->hit_streak = 0;
    }
    if (!(new_move->flags & T6_MOVE_KEEPS_TOOK_DAMAGE)) f->took_damage = 0;  // move does not keep it: clear
}

// --- the turns of the change

// Root yaw of the anim of anim_ref at frame - 1
static float anim_yaw(T6World *w, T6Fighter *f, T6Ref anim_ref, float frame) {
    if (!fighter(f)) return 0.0f;  // only fighters have a root yaw
    t6_body_scale(w, f);
    float sample_frame = frame - 1.0f;
    if (frame <= 0.0f) sample_frame = 0.0f;  // do not sample before the first frame
    T6Vec4 turn = {{0, 0, 0, 1}};
    t6_anim_sample_yaw(t6_anim_at(w, anim_ref), sample_frame, &turn);  // sample the yaw turn of the anim
    return t6_quat_yaw(&turn);
}

// The facing change that keeps the root yaw of the anim: toang(wrapA(yaw(old anim) - yaw(new anim)))
static int16_t anim_turn(T6World *w, T6Fighter *f) {
    float old_yaw = anim_yaw(w, f, f->move, (float)f->change_frame);
    float new_yaw = anim_yaw(w, f, f->pending_move, (float)f->frame - 1.0f);
    return t6_rad_to_angle65535(t6_turn_positive(old_yaw - new_yaw));
}

static void turn_by_anim(T6World *w, T6Fighter *f) { f->facing = (int16_t)(anim_turn(w, f) + f->facing); }


// body_yaw and look_yaw leave the end yaw of the old move
static void turn_body(T6Fighter *f, const T6Move *old_move) {
    float y = t6_wrap_pi(f->body_yaw - t6_angle65535_to_rad(old_move->end_yaw));
    f->body_yaw = y;
    f->look_yaw = y;
}

static void face_body(T6Fighter *f) {
    f->facing = t6_rad_to_angle65535(t6_turn_positive(f->body_yaw));
    f->move_yaw = f->facing;
}

// The cancel turned the fighter around: half a turn on every yaw.
static void pending_turn(T6Fighter *f) {
    float y = f->body_yaw + T6_PI;
    f->pending_flags.turn = 0;  // clear the turn request
    f->facing = t6_angle_offset(f->facing, HALF_TURN);
    f->move_yaw = t6_angle_offset(f->move_yaw, HALF_TURN);
    y = t6_wrap_pi(y);
    f->body_yaw = y;
    f->look_yaw = y;
}

static void end_turn(T6Fighter *f, const T6Move *old_move) {
    f->facing = (int16_t)(f->facing - old_move->end_yaw);  // take off the old move's end yaw
    turn_body(f, old_move);
    f->move_yaw = f->facing;
}

// START_THROW_PARTNER: face along the partner. The first thrown move turns by the thrower's position, a later one keeps
// the facing (or turns by its anim); a later throwing move faces along the partner when it lines up again.
static void face_throw_partner(T6World *w, T6Fighter *f, const T6Fighter *opponent, const T6Move *old_move, const T6Move *new_move) {
    T6ThrowChain chain = f->throw.chain;
    if (!t6_in_throw(chain)) {  // throw is starting: turn by what the throw saw of the position
        T6ThrowPosition seen = f->throw.target[opponent->slot % T6_FIGHTER_COUNT].seen;
        f->facing = t6_angle_offset(f->facing, (T6Angle){(uint16_t)t6_throw_victim_turn(seen, opponent->change_turn != 0)});
        f->move_yaw = opponent->move_yaw;
        if (new_move->flags & T6_MOVE_ON_PARTNER) {  // move is on the partner: face along them
            f->move_yaw = opponent->move_yaw;
            f->facing = opponent->move_yaw;
        }
    } else if (t6_thrown(chain)) {  // already thrown: a later move
        if ((old_move->flags & T6_MOVE_KEEP_HIPS) || (new_move->flags & T6_MOVE_KEEP_HIPS)) {  // hips kept: face partner
            f->move_yaw = opponent->move_yaw;
            f->facing = opponent->move_yaw;
        } else {  // else turn by the anim
            int16_t turn = anim_turn(w, f);
            f->move_yaw = opponent->move_yaw;
            f->facing = (int16_t)(turn + f->facing);
        }
    } else if (new_move->flags & T6_MOVE_THROW_RESYNC) {  // a later throwing move lines up again: face along the partner
        f->move_yaw = opponent->move_yaw;
        f->facing = opponent->move_yaw;
    }
}

// START_HALF_TURN outside a throw: the body turns half a circle; the move yaw by the reaction facing.
static void half_turn_free(T6Fighter *f, const T6Move *new_move) {
    if (new_move->flags & T6_MOVE_ON_PARTNER) {  // on the partner: face the body direction
        f->look_yaw = f->body_yaw;
        face_body(f);
        return;
    }
    float y = t6_wrap_pi(f->look_yaw + T6_PI);
    f->body_yaw = y;
    f->look_yaw = y;
    int16_t turned = t6_rad_to_angle65535(t6_turn_positive(y));
    if (f->reaction_facing == REACTION_FACING_LOOK) f->move_yaw = turned;  // reaction facing is look: use the new body yaw
    else if (f->reaction_facing == REACTION_FACING_TURNED) f->move_yaw = f->facing;  // reaction facing is turned: keep the facing
    else f->move_yaw = t6_angle_offset(f->facing, HALF_TURN);  // else half a turn from the old facing
    f->facing = turned;
}

static void face_half_turn(T6World *w, T6Fighter *f, const T6Fighter *opponent, const T6Move *old_move, const T6Move *new_move) {
    T6ThrowChain chain = f->throw.chain;
    if (!t6_in_throw(chain) || !t6_in_throw(opponent->throw.chain)) {  // not both in a throw: free half turn
        half_turn_free(f, new_move);
    } else if (t6_thrown(chain)) {  // this fighter is thrown
        if (new_move->flags & T6_MOVE_THROW_RESYNC) {  // lines up again: turn and face the body
            turn_body(f, old_move);
            face_body(f);
        }
    } else if (!(new_move->flags & T6_MOVE_KEEP_HIPS)) {  // hips not kept: turn by the anim
        turn_by_anim(w, f);
        f->move_yaw = f->facing;
    } else {  // hips kept: plain half turn
        f->facing = t6_angle_offset(f->facing, HALF_TURN);
        f->move_yaw = f->facing;
    }
}

// Step 15: facing. The alignment of the transition picks the row; the throw partner and the half turn read the throw state.
static void facing_for_move(T6World *w, T6Fighter *f, const T6Fighter *opponent, const T6Move *old_move, const T6Move *new_move) {
    T6StartAlignment align = t6_transition_align(f->transition);
    const T6StartRow *row = t6_start_row(align);
    if (row->turns_with_anim && f->end_yaw_flag == 0 &&  // keep the root yaw of the anim
        !(new_move->flags & T6_MOVE_KEEPS_ROOT_YAW))
        turn_by_anim(w, f);
    if (align == START_THROW_PARTNER) face_throw_partner(w, f, opponent, old_move, new_move);  // throw partner start
    else if (align == START_HALF_TURN) face_half_turn(w, f, opponent, old_move, new_move);  // half turn start
    else t6_facing_start(f, row, old_move->flags & T6_MOVE_HIT_REACTION);  // any other start: the row decides
}

// --- step 13: the frame the new move starts at, by class

// The juggle weight a launch or a hit pushback starts with. A move after a reaction starts none.
static int16_t juggle_value(T6Fighter *f, const T6Move *old_move, const T6Move *new_move) {
    int16_t value = 0;
    if (!(old_move->flags & T6_MOVE_HIT_REACTION)) {  // after a reaction the weight stays zero
        int16_t sum = (int16_t)((int16_t)f->juggle_weight / 2 + f->damage_absolute);
        value = sum;
        if (sum > JUGGLE_WEIGHT_MAX) value = JUGGLE_WEIGHT_MAX;  // cap the weight
    }
    f->thrown_length = (int16_t)new_move->length;  // remember the length of the new move
    return value;
}

static void set_frame(T6Fighter *f, int32_t frame) {
    f->frame = (int16_t)frame;
}

static void next_frame(T6Fighter *f, int16_t frame, int32_t length) {
    f->frame = (int16_t)(frame + 1);
    if (f->frame > length) set_frame(f, length);  // do not go past the end
}

// The frame of the start word: an offset from frame or frame2, or a frame.
static int32_t param_frame(const T6Fighter *f, uint16_t param) {
    int32_t offset = param % START_PARAM_OFFSET_RANGE;
    if (param & START_PARAM_AFTER_FRAME) return f->frame + offset;  // offset ahead of the frame
    if (param & START_PARAM_BEFORE_FRAME) return f->frame - offset;  // offset behind the frame
    if (param & START_PARAM_AFTER_FRAME2) return f->frame2 + offset;  // offset ahead of the second frame
    if (param & START_PARAM_BEFORE_FRAME2) return f->frame2 - offset;  // offset behind the second frame
    return param;  // a plain frame
}

// A frame past the end wraps into the move.
static void start_at_param(T6Fighter *f, int32_t length) {
    int32_t frame = (int16_t)(uint16_t)param_frame(f, f->start_param);
    if (frame > length && length != 0) frame %= length;  // past the end: wrap into the move
    f->frame = (int16_t)frame;
    if ((int16_t)frame < 1) set_frame(f, 1);  // never below frame 1
}

// The carry starts the new move at frame 1 when it was picked ahead, or when its active frames are past.
static bool carry_restarts(const T6Fighter *f, const T6Move *new_move, int16_t frame, int32_t length) {
    if (f->pick_kind == PICKED_AHEAD) return true;  // picked ahead: restart
    return new_move->first_active != 0 &&  // restart when the active frames are past
           (length < new_move->first_active || new_move->last_active < frame);
}

// The classes that leave a throw.
static bool ends_throw(enum T6TransitionClass transition_class) {
    return transition_class != TRANSITION_NEXT && transition_class != TRANSITION_THROWER && transition_class != TRANSITION_THROWN;
}

static void start_frame(T6World *w, T6Fighter *f, const T6Move *old_move, const T6Move *new_move, T6Ref new_ref) {
    enum T6TransitionClass transition_class = t6_transition_class(f->transition);
    if (transition_class > TRANSITION_JUGGLE) return;  // the classes no data uses change nothing
    int16_t frame = f->frame;
    int32_t length = new_move->length;
    f->anim_move = new_ref;
    if (ends_throw(transition_class)) f->throw.chain = (T6ThrowChain){};  // leaving a throw: clear the chain
    switch (transition_class) {  // pick the start frame by transition class
    case TRANSITION_START: set_frame(f, 1); break;  // start at frame 1
    case TRANSITION_CARRY:  // carry the frame over
        if (carry_restarts(f, new_move, frame, length)) set_frame(f, 1);  // restart at frame 1
        else next_frame(f, frame, length);  // else go to the next frame
        if (f->frame > length) set_frame(f, length);
        break;
    case TRANSITION_PARAM: start_at_param(f, length); break;  // frame from the start word
    case TRANSITION_END:  // start at the last frame, play backward
        set_frame(f, length);
        f->play_direction = -1;
        break;
    case TRANSITION_BACK:  // one frame back, play backward
        f->frame = (int16_t)(frame - 1);
        if (f->frame < 1) f->frame = 1;
        f->play_direction = -1;
        break;
    case TRANSITION_NEXT:  // next frame, stance held
        next_frame(f, frame, length);
        f->stance_rule = STANCE_HELD;
        break;
    case TRANSITION_THROWER: set_frame(f, 1); break;  // start at frame 1
    case TRANSITION_THROWN:
        set_frame(f, 1);
        break;
    case TRANSITION_JUGGLE:  // launch: juggle weight and the pending frame
        f->root_mode = T6_ROOT_LAUNCH;  // launched root
        f->juggle_count++;  // count a juggle hit
        f->launch_flag = 1.0f;
        f->juggle_weight = juggle_value(f, old_move, new_move);  // set the juggle weight
        t6_juggle_launch(w, f, &f->reaction);
        set_frame(f, f->pending_frame);
        break;
    }
}

// --- step 14: floor and height flags of the new and the old move

// for skeleton B: its limb table index is the side of the object
static void clear_limb_drop(T6World *w, const T6Fighter *f) {
    if ((uint16_t)f->side_index < T6_FIGHTER_COUNT) w->fighters[(uint16_t)f->side_index]->limbs.drop.fall_speed = 0.0f;
}

static void floor_for_move(T6World *w, T6Fighter *f, const T6Move *old_move, const T6Move *new_move) {
    if (new_move->flags & T6_MOVE_FOLLOWS_FLOOR) {  // new move follows the floor: back to the base height
        f->position.y = f->base_position.y;
        clear_limb_drop(w, f);
        f->blend.offset.y = 0.0f;
    } else if (!(old_move->flags & T6_MOVE_FOLLOWS_FLOOR)) {  // neither follows the floor: nothing to do
        return;
    } else if (fighter(f)) {  // leaving floor follow: a fighter drops to ground height
        f->position.y = 0.0f;
    } else {  // an object sits on the stage floor under it
        float old_y = f->position.y;
        float floor_y = t6_stage_floor(w, f->base_position);
        f->position.y = floor_y;
        f->base_position.y = f->base_position.y + (floor_y - old_y);
    }
}

// --- step 16: the root of the new move at its start frame

typedef struct { float x, z; } GroundPoint;

// The root of anim_ref at anim_frame, scaled, turned by the move yaw (hips: with the hips translation)
static GroundPoint turned_root(T6World *w, T6Fighter *f, T6Ref anim_ref, float anim_frame, bool hips) {
    T6Vec4 root[2];
    t6_anim_sample_root(t6_anim_at(w, anim_ref), anim_frame, root);
    t6_pose_scale_root(root, f->scale_xz, f->scale_xz_add, f->scale_y);
    float x = root[0].x, z = root[0].z;
    if (hips) {  // with hips: add the hips translation
        x = root[0].x + root[1].x;
        z = root[0].z + root[1].z;
    }
    float angle = (float)(int16_t)(0 - (uint16_t)f->move_yaw) * T6_ANGLE_TO_RAD;  // turn by the move yaw
    float sine = t6_sin(angle);
    float cosine = t6_cos(angle);
    return (GroundPoint){fmaf(cosine, x, sine * z), fmaf(sine, x, -(cosine * z))};
}

static float fixed_axis(float position, float now, float before, float reference) {
    float correction = (position + now) - reference;  // how far the position is off the reference
    return (position - correction) + (now - before);
}

// The anchor moves so that the root of the new anim at anim_frame stays where the old one was
static void root_fix(T6World *w, T6Fighter *f, T6Ref anim_ref, float anim_frame, bool hips) {
    if (!fighter(f)) return;
    t6_body_scale(w, f);
    GroundPoint now = turned_root(w, f, anim_ref, anim_frame, hips);
    GroundPoint before = {0, 0};
    if (anim_frame != 0.0f) before = turned_root(w, f, anim_ref, anim_frame - 1.0f, hips);  // the root one frame earlier
    T6Vec3 ref = hips ? f->base_position : f->previous_position;  // reference: base with hips, else previous
    f->position.x = fixed_axis(f->position.x, now.x, before.x, ref.x);
    f->position.z = fixed_axis(f->position.z, now.z, before.z, ref.z);
}

static void keep_position(T6Fighter *f) {
    if (!fighter(f)) return;
    f->position.x = f->previous_position.x;  // keep the position of last frame
    f->position.z = f->previous_position.z;
}

static void root_for_move(T6World *w, T6Fighter *f, T6Fighter *opponent, const T6Move *old_move, const T6Move *new_move, T6Ref new_ref) {
    if (f->pending_flags.no_root_fix) return;  // the pick asked for no root fix
    float anim_frame = (float)f->frame - 1.0f;
    bool hips = f->pending_flags.root_hips;
    T6ThrowChain chain = f->throw.chain;
    switch (t6_transition_class(f->transition)) {  // root handling by transition class
    case TRANSITION_START: case TRANSITION_PARAM: case TRANSITION_JUGGLE:  // plain start, param or juggle: fix the root
        root_fix(w, f, new_ref, anim_frame, hips);
        break;
    case TRANSITION_END: case TRANSITION_BACK:
        f->pivot_request = 1;  // ask for a pivot
        root_fix(w, f, new_ref, anim_frame, hips);
        break;
    case TRANSITION_CARRY:
        if (f->pick_kind != PICKED_AHEAD && !t6_anim_same(t6_anim_at(w, f->move), t6_anim_at(w, new_ref)))
            f->pivot_request = 1;  // anim changed and not picked ahead: ask for a pivot
        root_fix(w, f, new_ref, anim_frame, hips);
        break;
    case TRANSITION_THROWER:  // snap to the throw partner when the throw is new or lines up again
        if (!t6_throwing(chain) || (new_move->flags & T6_MOVE_THROW_RESYNC))  // throw is new or lines up again
            t6_throw_snap(w, f, opponent, (new_move->flags & T6_MOVE_ON_PARTNER) != 0);  // snap to the throw partner
        break;
    case TRANSITION_THROWN:
        if (!t6_thrown(chain) || !t6_in_throw(opponent->throw.chain)) {  // not thrown yet or partner not in throw: stay put
            f->slide_frames = 0;
            keep_position(f);
        } else if ((new_move->flags & T6_MOVE_THROW_RESYNC) ||
                   (old_move->flags & T6_MOVE_THROWN_STAYS)) {  // lines up again or thrown stays: keep position
            keep_position(f);
        }
        break;
    default: break;
    }
}

// --- step 17: the motion code. It scripts a turn, a lock or a pushback; the tracking comes from the pick of the cancel or
// reaction that set the transition, else from the move. The scripted codes force the free phase: their own turn does the work.

static void clear_turn(T6Fighter *f) {
    f->turn_frames = 0;
    f->turn_speed = 0;
}

static int16_t turn_speed(int16_t target, int16_t from, int16_t frames) { return (int16_t)((int16_t)(uint16_t)(target - from) / frames); }

// The hit pushbacks repeat when the same back, left or right reaction comes again within the window.
static bool counts_repeats(uint16_t transition) {
    return transition >= t6_transition(TRANSITION_START, START_YAW_TO_FACING_ROOT, MOTION_HIT_BACK)
        && transition <= t6_transition(TRANSITION_START, START_YAW_TO_FACING_ROOT, MOTION_HIT_RIGHT);
}

static void count_repeats(T6Fighter *f, const T6Move *new_move) {
    uint16_t transition = f->transition;
    if (!counts_repeats(transition)) return;
    if (f->repeat_timer == 0) f->repeat_count = 0;  // timer ran out: restart the count
    else if ((int16_t)f->repeat_transition == (int16_t)transition) f->repeat_count++;  // same reaction again: count it
    f->repeat_transition = transition;
    f->repeat_timer = (int16_t)(new_move->length + REPEAT_WINDOW_EXTRA.ticks);  // open the window again
}

// The pushback of a reaction list slot: the pushback record, its curve and the angle.
static void take_pushback(T6World *w, T6Fighter *f, T6Ref pushback_ref, int16_t angle) {
    const T6Pushback *pushback = t6_pushback_at(w, pushback_ref);
    if (pushback == NULL) return;
    f->pushback = pushback_ref;
    f->pushback_curve = t6_ref(pushback_ref.set, pushback->curve);
    f->pushback_frames = (int16_t)pushback->frames;
    f->pushback_distance = t6_hit_pushback_distance(w, pushback);
    f->pushback_curve_frames = (int16_t)pushback->curve_frames;
    f->pushback_angle = angle;
    f->pushback_angle_start = angle;
}

enum PushbackFrom : uint8_t { FROM_TARGET, FROM_REFERENCE_NEAR_SIDE };

// A hit pushback: the slots of the reaction list it reads, where its angle is measured from, and what it counts.
typedef struct {
    uint8_t code;
    enum T6ReactionSlot pushback, angle, yaw;
    enum PushbackFrom from;
    bool juggle, repeats;  // starts a juggle weight, counts repeats
} HitPushback;

static const HitPushback HIT_PUSHBACKS[] = {
    {MOTION_HIT_FRONT, REACTION_FRONT, REACTION_FRONT, REACTION_FRONT, FROM_REFERENCE_NEAR_SIDE, true, true},
    {MOTION_HIT_BACK, REACTION_BACK, REACTION_BACK, REACTION_BACK, FROM_TARGET, true, true},
    {MOTION_HIT_LEFT, REACTION_LEFT, REACTION_LEFT, REACTION_LEFT, FROM_TARGET, true, true},
    {MOTION_HIT_RIGHT, REACTION_RIGHT, REACTION_RIGHT, REACTION_RIGHT, FROM_TARGET, true, true},
    {MOTION_COUNTER, REACTION_COUNTER, REACTION_FRONT, REACTION_COUNTER, FROM_TARGET, true, false},
    {MOTION_HIT_DOWN, REACTION_HIT_DOWN, REACTION_HIT_DOWN, REACTION_HIT_DOWN, FROM_TARGET, true, false},
    {MOTION_GUARD, REACTION_GUARD, REACTION_FRONT, REACTION_FRONT, FROM_TARGET, false, false},
    {MOTION_HIT_TO_TARGET, REACTION_FRONT, REACTION_FRONT, REACTION_FRONT, FROM_TARGET, true, true},
};

static constexpr T6Angle BACK_HIT_TURN = {ANGLE_FROM_DEG(10)};  // a back hit without a yaw turns away from the reference side

static const HitPushback *hit_pushback_of(uint8_t code) {
    for (size_t index = 0; index < sizeof HIT_PUSHBACKS / sizeof *HIT_PUSHBACKS; index++)
        if (HIT_PUSHBACKS[index].code == code) return &HIT_PUSHBACKS[index];  // find the row of the code
    return NULL;
}

static void hit_pushback(T6World *w, T6Fighter *f, const T6Move *old_move, const T6Move *new_move, const HitPushback *pushback_row, T6FacingState tracking) {
    const T6Reaction *reaction = &f->reaction;
    if (pushback_row->juggle) f->juggle_weight = juggle_value(f, old_move, new_move);  // this hit starts a juggle weight
    int16_t base = f->target_angle;  // measure the angle from the target
    if (pushback_row->from == FROM_REFERENCE_NEAR_SIDE) base = f->reference_near_side_angle;  // or from the reference near side
    take_pushback(w, f, reaction->pushback[pushback_row->pushback],  // set the pushback, aimed away from the base
                  t6_angle_offset((int16_t)(base - reaction->angle[pushback_row->angle]), HALF_TURN));
    uint16_t yaw = reaction->yaw[pushback_row->yaw];
    if (pushback_row->code == MOTION_HIT_BACK && yaw == 0) {  // back hit with no yaw: turn a little
        yaw = BACK_HIT_TURN.bits;
        if (f->reference_side_angle < 0) yaw = (uint16_t)-BACK_HIT_TURN.bits;  // reference on the other side: turn the other way
    }
    f->facing = (int16_t)(f->facing - yaw);  // turn by the reaction yaw
    f->move_yaw = f->facing;  // move yaw follows the facing
    if (pushback_row->code == MOTION_HIT_DOWN) f->juggle_weight = 0;  // a hit down starts no juggle weight
    if (pushback_row->repeats) count_repeats(f, new_move);  // count repeated hits
    f->facing_state = tracking;
    clear_turn(f);
}

// Frames for a turn that ends on the first active frame (with none, the old move's length, at most TURN_FRAMES_MAX)
static int16_t turn_length(const T6Move *old_move, const T6Move *new_move) {
    int16_t frames = (int16_t)(new_move->first_active - 1);
    if (new_move->first_active == 0) {  // no active frames: old move length, capped
        frames = TURN_FRAMES_MAX.ticks;
        if (old_move->length < TURN_FRAMES_MAX.ticks) frames = (int16_t)old_move->length;
    }
    if (frames <= 0) return 1;  // at least one frame
    return frames;
}

// Codes that clear the scripted turn after they set the tracking.
static bool code_clears_turn(uint8_t code) {
    return (code >= MOTION_HOMING_FIRST && code <= 13) || code == MOTION_SWEEP || code == MOTION_SWEEP_LAST
        || (code >= MOTION_CHASE_FIRST && code < MOTION_CODE_END);
}

static void approach(T6Fighter *f, const T6Move *new_move, T6FacingState free) {
    int16_t frames = (int16_t)(new_move->first_active - 1);
    if (frames <= 0) frames = 1;  // at least one frame
    f->facing_state = free;
    f->turn_frames = frames;  // turn over those frames
    f->approach_x = 0;
    f->approach_z = 0;
    f->approach_state = 1;  // start the approach
    f->turn_speed = turn_speed(f->target_angle, f->facing, frames);  // turn speed toward the target
}

static void turn_to_target(T6Fighter *f, const T6Move *old_move, const T6Move *new_move, uint8_t code, T6FacingState free) {
    f->facing_state = free;
    f->turn_frames = turn_length(old_move, new_move);  // the turn ends on the first active frame
    f->near_side_angle = f->target_angle;
    if (code == MOTION_TURN_TO_TARGET && (uint16_t)f->opponent_angle >= QUARTER_TURN.bits)  // opponent far round: other side
        f->near_side_angle = t6_angle_offset(f->target_angle, HALF_TURN);
    f->turn_speed = turn_speed(f->near_side_angle, f->facing, f->turn_frames);
}

static void settle(T6Fighter *f, T6FacingState free) {
    if (!t6_in_throw(f->throw.chain)) {  // outside a throw: a short turn to the move yaw
        f->turn_frames = (int16_t)SETTLE_TURN_FRAMES.ticks;
        f->turn_speed = turn_speed(f->move_yaw, f->facing, (int16_t)SETTLE_TURN_FRAMES.ticks);
    }
    f->pushback_distance = 0.0f;  // no pushback left
    f->pushback_curve_frames = 0;
    f->facing_state = free;
    f->pushback_frames = 0;
}

static void motion_for_move(T6World *w, T6Fighter *f, const T6Move *old_move, const T6Move *new_move, T6Ref new_ref) {
    uint8_t code = t6_transition_code(f->transition);
    T6FacingState tracking = t6_facing_for_move(w, f, new_ref);  // the tracking the new move would use
    T6FacingState free = {0, FACING_FREE, new_ref.set};
    f->track_pick = (T6TrackingPick){};
    if (code == MOTION_NONE || code >= MOTION_CODE_END) return;  // the tracking stays as the move change left it
    const HitPushback *pushback_row = hit_pushback_of(code);  // look up the hit pushback row
    if (pushback_row != NULL && code == MOTION_GUARD) {  // guard pushback keeps the tracking
        hit_pushback(w, f, old_move, new_move, pushback_row, tracking);
        return;
    }
    if (pushback_row != NULL) {  // other hit pushbacks free the facing
        hit_pushback(w, f, old_move, new_move, pushback_row, free);
        return;
    }
    if (code == MOTION_APPROACH) {  // approach code
        approach(f, new_move, free);
        return;
    }
    if (code == MOTION_TURN_TO_TARGET || code == MOTION_TURN_TO_TARGET_AHEAD) {  // turn to the target codes
        turn_to_target(f, old_move, new_move, code, free);
        return;
    }
    if (code >= MOTION_SETTLE_FIRST && code <= MOTION_THROWN) {  // settle codes
        settle(f, free);
        return;
    }
    if (code == MOTION_JUGGLE) {  // juggle code: start weight, free facing
        f->juggle_weight = juggle_value(f, old_move, new_move);
        f->facing_state = free;
        clear_turn(f);
        return;
    }
    if (code == MOTION_SWEEP) f->cancel_lock = SWEEP_CANCEL_LOCK;  // a sweep locks cancels
    f->facing_state = tracking;  // the code sets the tracking
    if (code_clears_turn(code)) clear_turn(f);  // some codes clear the scripted turn
}

// --- the tail of a move change: the new move becomes current

// A pending frame no move reaches: the change waits for a new pick.
static constexpr int16_t PENDING_FRAME_NONE = 256;

static void enter_throw(T6World *w, T6Fighter *f, const T6Fighter *opponent, const T6Move *new_move) {
    enum T6TransitionClass transition_class = t6_transition_class(f->transition);
    if (transition_class == TRANSITION_THROWER) {  // thrower: step the chain as thrower
        f->throw.chain = t6_throw_chain_step(f->throw.chain, THROW_ROLE_THROWER);
        return;
    }
    if (transition_class != TRANSITION_THROWN) return;  // only thrown from here
    f->throw.chain = t6_throw_chain_step(f->throw.chain, THROW_ROLE_THROWN);  // step the chain as thrown
    const T6Move *thrower = t6_move_at(w, opponent->pending_move);
    if (thrower == NULL) {  // thrower's move is missing: error
        f->error = 1;
        return;
    }
    f->thrown_length = t6_thrown_frames(thrower, new_move);  // length of the thrown reaction
    if (f->juggle_weight > JUGGLE_WEIGHT_MAX) f->juggle_weight = JUGGLE_WEIGHT_MAX;  // clamp the juggle weight
    if (f->juggle_weight < THROWN_JUGGLE_WEIGHT_MIN) f->juggle_weight = THROWN_JUGGLE_WEIGHT_MIN;
}

static void restart_clock(T6Fighter *f) {
    f->previous_frame = f->frame;
    f->previous_frame2 = f->frame2;
    f->clock = f->frame * CLOCK_PER_FRAME;  // clock starts at the frame
    f->secondary = f->frame2 * CLOCK_PER_FRAME;
    f->elapsed = f->frame_9c * CLOCK_PER_FRAME;
    f->frame_changed = 1;
    f->speed = f->play_direction * PLAY_SPEED;  // speed by the play direction
    f->anim_time = (float)f->clock / (float)CLOCK_PER_FRAME;
    f->anim_time_at_clock = f->anim_time;
}

static void enter_move(T6World *w, T6Fighter *f, const T6Fighter *opponent, const T6Move *new_move, T6Ref new_ref) {
    enter_throw(w, f, opponent, new_move);  // step the throw chain
    f->move = new_ref;  // the new move becomes the current one
    f->applied_move_id = (uint16_t)f->pending_id;  // remember the id applied
    f->pending_id = 0;  // clear the pending id
    f->pending_move = t6_ref(0, -1);  // clear the pending move
    f->hitbox_slots = 0;
    if (new_move->first_active != 0) f->hitbox_slots = new_move->hits.slots;  // a move with active frames gets its hit slots
    f->air_move = new_move->window_start != 0 || f->juggle_count != 0;  // air move: has a window start or a juggle
    f->frame_9c = f->frame;
    if (f->anim_changed) f->frame_9c = 1;  // new anim: restart this count
    f->applied_transition = f->transition;  // keep the applied transition
    f->transition = 0;  // clear the transition
    f->move_frames = 1;
    f->frame2 = 1;
    f->pending_flags = (T6PendingFlags){};  // clear the pending flags
    f->end_yaw_flag = 0;
    f->pending_id_high = 0;
    f->reaction_facing = REACTION_FACING_HIT;  // reaction facing back to hit
    f->pending_frame = 0;
    if (f->play_direction > 0) f->pending_frame = PENDING_FRAME_NONE;  // playing forward: no pending frame
    restart_clock(f);
    t6_start_properties(w, f, t6_object(w, f->target));  // run the start properties of the move
}

// --- the move tick

// No change this frame: nothing pending, or the pending frame is not reached in the play direction.
static bool waits(const T6Fighter *f, const T6Move *old_move) {
    if (t6_ref_none(f->pending_move)) return true;  // nothing pending: wait
    int16_t frame = f->frame;
    if (f->play_direction > 0)  // forward: wait until the pending frame is reached or the move ends
        return f->pending_frame > frame && old_move->length > frame;
    return f->play_direction < 0 && f->pending_frame < frame && frame > 0;  // backward: wait until the pending frame is passed
}

static bool takes_new_anim(const T6World *w, const T6Fighter *f, T6Ref new_ref) {
    if (f->pick_kind == PICKED_AHEAD || f->pick_kind == PICKED_REACTION) return true;  // ahead or reaction: new anim
    return !t6_anim_same(t6_anim_at(w, new_ref), t6_anim_at(w, f->move));  // else only when the anim differs
}

void t6_move_tick(T6World *w, T6Fighter *f, T6Fighter *opponent) {
    const T6Move *old_move = t6_move_at(w, f->move);
    if (old_move == NULL) {  // no current move: error
        f->error = 1;
        return;
    }
    if (waits(f, old_move)) {  // no change yet: just tick the clock
        tick_clock(f, old_move);
        return;
    }
    T6Ref new_ref = f->pending_move;
    const T6Move *new_move = t6_move_at(w, new_ref);
    const T6Cancel *end = end_entry(t6_set(w, new_ref.set), new_move);
    if (end == NULL) {  // new move has no end entry: error
        f->error = 1;
        return;
    }
    reset_for_move(w, f, opponent, new_move, end);
    t6_shot_move_change(f);
    state_for_move(f, t6_set(w, new_ref.set), old_move, new_move);
    if (takes_new_anim(w, f, new_ref)) f->anim_changed = 1;  // mark the anim as changed
    f->move_start = 1;
    if (f->pending_flags.turn) pending_turn(f);  // the cancel asked for a turn
    if (f->end_yaw_flag && t6_transition_class(f->transition) != TRANSITION_THROWN)  // turn by the old end yaw unless thrown
        end_turn(f, old_move);
    t6_relative_angles(w, f, opponent, true);  // update the angles to the opponent
    if (f->pending_id_high != 0) f->moveset = f->data;
    start_frame(w, f, old_move, new_move, new_ref);  // set the start frame
    floor_for_move(w, f, old_move, new_move);  // floor flags
    facing_for_move(w, f, opponent, old_move, new_move);  // facing
    root_for_move(w, f, opponent, old_move, new_move, new_ref);  // root placement
    motion_for_move(w, f, old_move, new_move, new_ref);  // motion code: turns and pushback
    enter_move(w, f, opponent, new_move, new_ref);  // the new move becomes current
}

// for the fighters in turn order: all of them when a throw starts, else those with a move to change to.
static void end_properties(T6World *w, bool throw_starts) {
    T6TurnOrder order = t6_turn_order(w);
    if (throw_starts || !t6_ref_none(order.first->pending_move))  // first in turn order: when a throw starts or they change move
        t6_props_end(w, order.first);
    if (throw_starts || !t6_ref_none(order.second->pending_move))  // second in turn order: same
        t6_props_end(w, order.second);
}

void t6_apply_moves_pass(T6World *w) {
    enum { MAX_OBJECTS = 128 };
    if (w->skip_apply_moves) {  // skipped this frame: clear the flag
        w->skip_apply_moves = 0;
        return;
    }
    T6Fighter *throwers[MAX_OBJECTS];
    int32_t count = t6_pending_throwers(w, throwers, MAX_OBJECTS);  // gather the fighters with a pending throw
    end_properties(w, count > 0);
    T6ThrowStart started = t6_throws_start(w, throwers, count);  // start the throws
    int32_t total = t6_extra_count(w) + T6_FIGHTER_COUNT;  // all objects: extras plus fighters
    for (int32_t index = 0; index < total; index++) {  // tick the move of each object
        T6Fighter *object = t6_object(w, index);
        if (object != started.thrower && object != started.victim)  // not the ones the throw just handled
            t6_move_tick(w, object, t6_object(w, object->opponent));
    }
}
