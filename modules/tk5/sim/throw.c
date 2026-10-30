// Throws: the pair, the chain of throw moves, the victim's position for the throw requirements, the start of a throw.
#include "sim/throw.h"

#include <math.h>
#include <string.h>

#include "sim/anim.h"
#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/pose.h"
#include "sim/properties.h"
#include "sim/move_change.h"
#include "sim/requirements.h"
#include "sim/transition.h"

T5ThrowChain t5_throw_chain_step(T5ThrowChain chain, T5ThrowRole role) {
    if (chain.role == role) return (T5ThrowChain){role, (uint16_t)(chain.moves + 1)};  // same role: one more move
    return (T5ThrowChain){role, 1};  // new role: the chain restarts at one move
}

// --- the pair

T5Fighter *t5_throw_partner(const T5World *w, const T5Fighter *f) { return t5_object(w, f->throw.partner); }

bool t5_throw_pair(const T5World *w, const T5Fighter *first, const T5Fighter *second) {
    return (t5_in_throw(first->throw.chain) && t5_throw_partner(w, first) == second) ||  // first throws second, or the reverse
           (t5_in_throw(second->throw.chain) && t5_throw_partner(w, second) == first);
}

void t5_throw_link(const T5World *w, T5Fighter *f, int16_t partner) {
    f->throw.partner = partner;  // f points at the partner
    t5_object(w, partner)->throw.partner = (int16_t)t5_object_index(w, f);  // and the partner points back at f
}

// --- the victim's position

static constexpr T5ThrowPosition NOT_THROWABLE = {THROW_NOT_THROWABLE, HIT_FRONT};

// The requirement ids in order: four sides of each stance.
static const T5ThrowStance REQUIREMENT_STANCE[] = {
    THROW_STANDING, THROW_CROUCHING, THROW_FACE_UP, THROW_FACE_DOWN,  // the four sides of each stance, in this order
    THROW_BEHIND, THROW_STANDING_OR_CROUCHING, THROW_AIR, THROW_AIR_FACE_DOWN,
};
static const uint8_t REQUIREMENT_SIDE[T5_HIT_SIDES] = {HIT_FRONT, HIT_BACK, HIT_LEFT, HIT_RIGHT};

T5ThrowPosition t5_throw_position_of_requirement(uint16_t requirement) {
    if (requirement < THROW_REQ_FIRST || requirement > THROW_REQ_LAST) return NOT_THROWABLE;  // not a throw requirement
    int32_t offset = requirement - THROW_REQ_FIRST;  // four ids per stance, so offset / 4 is the stance and offset % 4 the side
    return (T5ThrowPosition){REQUIREMENT_STANCE[offset / T5_HIT_SIDES], REQUIREMENT_SIDE[offset % T5_HIT_SIDES]};
}

bool t5_throw_position_takes(T5ThrowPosition wanted, T5ThrowPosition seen) {
    if (wanted.side != seen.side) return false;  // the victim must be on the wanted side
    if (wanted.stance == THROW_STANDING_OR_CROUCHING) return seen.stance == THROW_STANDING || seen.stance == THROW_CROUCHING;
    return wanted.stance == seen.stance;  // any other wanted stance must match exactly
}

// The stance of the opponent for f: in front within a sixth of a turn (standing, crouching or lying), or standing with
// their back to f.
static T5ThrowStance stance_for(const T5Fighter *f, const T5Fighter *opponent) {
    uint32_t s = opponent->state;
    bool in_front = f->opponent_angle < SIXTH_TURN.bits;  // opponent is within a sixth of a turn of straight ahead
    bool downed = t5_state_has(s, STATE_DOWNED);  // opponent is lying face down (with the lying state: face down, else face up)
    if (opponent->in_air_window != 0) {  // opponent is in the air or juggled: only throwable from the front
        if (!in_front) return THROW_NOT_THROWABLE;
        if (downed) return THROW_AIR_FACE_DOWN;  // juggled face down
        return THROW_AIR;
    }
    if (in_front) {  // on the ground and in front: the stance comes from the state bits
        if (t5_state_has(s, STATE_THROW_LYING) && downed) return THROW_FACE_DOWN;
        if (t5_state_has(s, STATE_THROW_LYING)) return THROW_FACE_UP;
        if (t5_state_has(s, STATE_THROW_STANDING)) return THROW_STANDING;
        if (t5_state_has(s, STATE_THROW_CROUCHING)) return THROW_CROUCHING;
        return THROW_NOT_THROWABLE;
    }
    if (f->opponent_angle > THIRD_TURN.bits && t5_state_has(s, STATE_STANDING)) return THROW_BEHIND;
    return THROW_NOT_THROWABLE;
}

T5ThrowPosition t5_throw_position(const T5Fighter *f, const T5Fighter *opponent) {
    if (f->hit_landed == 0 || opponent->throw_immune != 0) return NOT_THROWABLE;  // no hit landed, or opponent is throw immune
    T5ThrowStance stance = stance_for(f, opponent);  // how the opponent stands
    if (stance == THROW_NOT_THROWABLE || opponent->hit_side < 0 || opponent->hit_side >= T5_HIT_SIDES) return NOT_THROWABLE;
    return (T5ThrowPosition){stance, (uint8_t)opponent->hit_side};  // the side is the side of the opponent that was hit
}

T5ThrowTarget t5_throw_look(T5ThrowTarget target, const T5Fighter *f, const T5Fighter *opponent,  // look, or reuse the last look
                            uint16_t own_move_id, uint16_t opponent_move_id) {
    bool known = target.seen.stance != THROW_UNSEEN &&  // seen before, and nothing changed since: same move or same state
                 (opponent_move_id == target.seen_move_id || opponent->state == target.seen_state);
    if (known) return target;  // the cached look is still good: keep it
    target.seen = t5_throw_position(f, opponent);  // look again and cache the position with the state and move id it was seen at
    target.seen_state = opponent->state;
    target.seen_move_id = own_move_id;
    return target;
}

// What the game leaves in the cache with nothing seen: a state no fighter has and no move id.
static constexpr uint32_t UNSEEN_STATE = 2047;
static constexpr uint32_t UNSEEN_MOVE_ID = 65535;

void t5_throw_forget(T5Fighter *f) {
    for (int index = 0; index < T5_FIGHTER_COUNT; index++) {  // loop through the opponent slots and clear what f has seen of each
        T5ThrowTarget *target = &f->throw.target[index];
        target->seen = (T5ThrowPosition){};
        target->seen_state = UNSEEN_STATE;
        target->seen_move_id = UNSEEN_MOVE_ID;
    }
}

// --- the move change into a throw

static constexpr T5Angle QUARTER_TURN_BACK = {ANGLE_FROM_DEG(270)};
static const T5Angle SIDE_TURN[T5_HIT_SIDES] = {[HIT_FRONT] = {0},  // how far the victim turns, by the side that was hit
    [HIT_LEFT] = QUARTER_TURN_BACK, [HIT_BACK] = HALF_TURN, [HIT_RIGHT] = QUARTER_TURN};

int16_t t5_throw_victim_turn(T5ThrowPosition position, bool partner_turned) {
    if (position.stance == THROW_UNSEEN || position.stance == THROW_NOT_THROWABLE) return 0;  // no throwable position: no turn
    int32_t turn = SIDE_TURN[position.side].bits;  // turn by side: front none, back half, left/right quarter
    if (position.stance == THROW_BEHIND) turn += HALF_TURN.bits;  // victim faces away: half a turn more
    if (partner_turned) turn += HALF_TURN.bits;  // the thrower's move change turned them half a circle: half a turn more
    return t5_angle_s16(t5_angle_wrap(turn));
}

int16_t t5_thrown_frames(const T5Move *thrower, const T5Move *victim) {
    if (thrower->hold_frame != 0) return (int16_t)(victim->length + thrower->hold_frame);
    int16_t frames = (int16_t)thrower->length;  // else the thrower's move length, kept between 0 and the cap
    if (frames < 0) return 0;
    if (frames > THROWN_FRAMES_MAX.ticks) return (int16_t)THROWN_FRAMES_MAX.ticks;
    return frames;
}

void t5_throw_snap(const T5World *w, T5Fighter *thrower, T5Fighter *victim, bool on_partner) {
    if (thrower->kind != T5_KIND_FIGHTER) return;  // only fighters are placed, not extra objects
    if (on_partner) {  // the throw takes the victim's spot: copy their last position
        thrower->position.z = victim->previous_position.z;
        thrower->position.x = victim->previous_position.x;
        return;
    }
    t5_body_scale(w, thrower);  // scale the thrower's body for the throw pair
    T5Vec4 root[2];
    t5_anim_sample_root(&thrower->keys, t5_anim_at(w, thrower->pending_move), 0.0f, root);
    t5_pose_scale_root(root, thrower->scale_xz, thrower->scale_xz_add, thrower->scale_y);  // scaled by the body scale
    float root_x = root[0].x, root_z = root[0].z;
    float yaw = (float)(int16_t)(0 - (uint16_t)victim->move_yaw) * T5_ANGLE_TO_RAD;  // the victim's facing, reversed, in radians
    float sine = t5_sin(yaw);
    float cosine = t5_cos(yaw);
    float offset_z = fmaf(sine, root_x, -(cosine * root_z));  // rotate the root offset by the victim's facing (z)
    float offset_x = fmaf(cosine, root_x, sine * root_z);  // and x
    thrower->position.z = victim->position.z - ((victim->position.z + offset_z) - thrower->previous_position.z);
    thrower->position.x = victim->position.x - ((victim->position.x + offset_x) - thrower->previous_position.x);  // and x
    float frames = (float)THROW_SLIDE_FRAMES.ticks;
    victim->slide_frames = (int16_t)THROW_SLIDE_FRAMES.ticks;  // the victim slides to the thrower's spot over the slide frames
    victim->slide_step[0] = (thrower->position.x - victim->position.x) / frames;  // slide step per frame in x
    victim->slide_step[1] = (thrower->position.z - victim->position.z) / frames;  // and in z
}

// --- the start of a throw

int32_t t5_pending_throwers(const T5World *w, T5Fighter *out[], int32_t cap) {
    int32_t first = 0;
    int32_t total = t5_extra_count(w) + T5_FIGHTER_COUNT;
    int32_t count = 0;
    if (t5_phase_frozen(w)) first = T5_FIGHTER_COUNT;  // frozen fighters start no throws
    for (int32_t index = first; index < total && count < cap; index++) {  // loop through fighters and extras with a throw ready
        T5Fighter *object = t5_object(w, index);
        if (!t5_ref_none(object->pending_move) && object->frame >= object->pending_frame &&  // a move waits and its frame is here
            t5_transition_class(object->transition) == TRANSITION_THROWER)
            out[count++] = object;
    }
    return count;
}

// Both fighters throw at once; each takes the clash move.
static void clash(T5World *w, T5Fighter *f) {
    f->pending_id = (int16_t)T5_ALIAS_THROW_CLASH;  // the next move is the clash move
    f->pending_move = t5_move_lookup(w, f, T5_ALIAS_THROW_CLASH);
    f->frame = 1;  // clash starts on the next frame
    f->pending_frame = 1;
    f->transition = t5_transition_filter(w, f, t5_transition(TRANSITION_START, START_YAW_TO_FACING, MOTION_NONE));
    f->pending_id_high = 1;
    f->pending_flags = (T5PendingFlags){};
}

// The throw of the thrower connects. The victim takes the reaction move of the thrower's hit condition, from
// its move set, as a thrown move that turns half a circle; a turn that the thrower's change asked for goes to the
// victim.
static void connect(T5World *w, T5Fighter *thrown, T5Fighter *thrower) {
    thrown->moveset = thrower->moveset_decided;  // the victim takes the move set the thrower decided on
    if (thrower->pending_id_high != 0) thrown->moveset = thrower->data;  // flagged: take the thrower's data instead
    T5Ref tref = thrower->pending_move;
    const T5HitCondition *condition = t5_hit_condition(w, thrower, thrown, t5_set(w, tref.set), t5_move_at(w, tref));
    const T5Reaction *reaction = NULL;
    if (w->reactions.list) reaction = w->reactions.list(w->reactions.context, tref.set, condition->reaction);
    if (reaction) thrown->pending_id = (int16_t)reaction->move[0];  // the victim's next move is that reaction's move
    thrown->pending_move = t5_move_lookup(w, thrown, (uint16_t)thrown->pending_id);
    thrown->pending_frame = thrown->frame;  // the victim changes move this frame
    thrown->transition = t5_transition_filter(w, thrown, t5_transition(TRANSITION_THROWN, START_HALF_TURN, MOTION_THROWN));
    thrown->track_pick = (T5TrackingPick){};  // no tracking override
    thrown->pending_flags = (T5PendingFlags){.turn = thrower->pending_flags.turn};  // the thrower's asked turn goes to the victim
    thrower->pending_flags.turn = 0;  // and the thrower does not turn
    thrown->pending_id_high = 0;
}

T5ThrowStart t5_throws_start(T5World *w, T5Fighter *const throwers[], int32_t count) {
    if (count != 1) {  // none or both fighters throw: every thrower clashes, no pair returned
        for (int32_t index = 0; index < count; index++) clash(w, throwers[index]);
        return (T5ThrowStart){};
    }
    T5Fighter *thrower = throwers[0];
    T5Fighter *victim = t5_throw_partner(w, thrower);  // the victim is the thrower's partner
    connect(w, victim, thrower);  // the victim takes the thrown reaction move
    t5_move_tick(w, victim, thrower);  // victim changes move first
    t5_move_tick(w, thrower, victim);  // then the thrower
    return (T5ThrowStart){thrower, victim};
}
