// The fighter reset of the round init and the start move.
#include <math.h>
#include <string.h>

#include "sim/collision.h"
#include "sim/constants.h"
#include "sim/decide.h"
#include "sim/fighter.h"
#include "sim/hit.h"
#include "sim/math.h"
#include "sim/motion.h"
#include "sim/move_change.h"
#include "sim/pose.h"
#include "sim/properties.h"
#include "sim/rng.h"
#include "sim/round.h"
#include "sim/transition.h"
#include "sim/vec.h"

enum { NO_OPTION = 65535 };
static const float START_DISTANCE = 1000.0f;  // the opponent distance a reset starts with

static constexpr T6ThrowPosition START_POSITION = {THROW_STANDING, HIT_FRONT};  // the throw position each fighter starts with

// --- the start move

static void start_move(T6World *w, T6Fighter *f, T6Fighter *opponent, bool away) {
    f->skip_motion = 0;
    uint32_t alias = away ? T6_ALIAS_AWAY : T6_ALIAS_ROUND_START;
    f->pending_id = (int16_t)t6_move_alias(w, f, alias - T6_ALIAS_BASE);  // the move id the start alias points to
    T6Ref move = t6_move_lookup(w, f, (uint16_t)f->pending_id);
    f->frame = 1;  // the start move begins on its first frame
    f->pending_frame = 1;
    f->pending_move = move;  // and is the current move at once
    f->move = move;
    f->anim_move = move;
    f->transition = t6_transition_filter(w, f,  // a start transition toward the opponent
                                         t6_transition(TRANSITION_START, START_TO_OPPONENT, MOTION_NONE));
    f->pending_flags = (T6PendingFlags){.no_root_fix = 1};  // the anim starts on the anchor as it is
    f->throw.chain = (T6ThrowChain){};  // no throw chain
    f->pending_id_high = 0;
    f->end_yaw_flag = 0;
    for (int side = 0; side < T6_FIGHTER_COUNT; side++)  // both throw targets start standing, seen from the front
        f->throw.target[side].seen = START_POSITION;
    f->play_direction = 1;  // the move plays forward
    t6_move_tick(w, f, opponent);  // run the first tick of the start move
    t6_scan_cancels(w, f, opponent);  // and scan its cancels right away
    if (f->input.control != T6_CONTROL_5)  // unless the control mode is 5, link the throw to the opponent
        t6_throw_link(w, f, (int16_t)t6_object_index(w, opponent));
}

// --- the step back of the first move

// Where the root of `move` is at `frame`, as a position of f. The step back measures the body as the round ended: a
// fight pose, so a fighter hit in an air move steps back at scale 1 (stock: the round end resets in the flow state of
// the KO).
static T6Vec4 root_at(const T6World *w, T6Fighter *f, T6Ref move, float frame) {
    T6Vec4 out = vec4_of(f->position, 1.0f);  // by default the fighter stays where they are
    if (f->kind != 0) return out;  // only fighters have a root to sample, not extras
    t6_fight_body_scale(w, f);  // measure the body as in a fight pose
    T6Vec4 root[2];
    t6_anim_sample_root(t6_anim_at(w, move), frame, root);  // the root of the move at that frame
    t6_pose_scale_root(root, f->scale_xz, f->scale_xz_add, f->scale_y);  // scaled to the body
    float root_x = root[0].x, root_y = root[0].y, root_z = root[0].z;
    float yaw = (float)(int16_t)(0 - (uint16_t)f->move_yaw) * T6_ANGLE_TO_RAD;  // the turn of the move, in radians
    float sine = t6_sin(yaw);
    float cosine = t6_cos(yaw);
    out.x = f->position.x + fmaf(cosine, root_x, sine * root_z);  // turn the root offset by that yaw, add to the position
    out.y = f->position.y + root_y;
    out.z = f->position.z + fmaf(sine, root_x, -(cosine * root_z));
    return out;
}

static bool shifts(const T6Move *move) { return (move->flags & T6_MOVE_NO_START_SHIFT) == 0; }

static void step_back(T6World *w, T6Fighter *f) {
    T6Vec4 position = vec4_of(f->position, 0.0f);
    T6Ref next = f->pending_move;  // the move that plays next: the pending one, else the current
    if (t6_ref_none(next)) next = f->move;
    if (!shifts(t6_move_at(w, f->move)) || !shifts(t6_move_at(w, next))) return;  // a move that opts out of the shift stays put
    float last_frame = (float)(uint32_t)t6_move_at(w, next)->length - 1.0f;  // the last frame of that move
    T6Vec4 first = root_at(w, f, next, 0.0f);  // the root at the first frame
    T6Vec4 last = root_at(w, f, next, last_frame);  // and at the last frame
    T6Vec4 to_first, first_to_last, step;
    t6_vec_subtract(&to_first, &first, &position);
    t6_vec_subtract(&first_to_last, &last, &first);
    t6_vec_add(&step, &to_first, &first_to_last);  // how far the fighter travels from here through the move
    t6_round_stand_at(f, f->position.x - step.x, f->position.z - step.z);  // start that far back
    if (f->kind != 0) return;  // extras keep their height
    f->position.y = 0.0f;  // a fighter starts on the floor
    f->previous_position.y = 0.0f;
    f->base_position.y = 0.0f;
    t6_root_from_base(f);  // the root follows the base position
}

// --- the reset

static void clear_wall_and_push_history(T6Fighter *f) {
    memcpy(f->last_base, &f->base_position, sizeof f->base_position);  // the last base is where they stand now
    f->last_base[3] = f->base_position_w;
    for (int axis = 0; axis < 3; axis++) f->wall_push[axis] = 0.0f;  // no wall push
    for (int sphere = 0; sphere < 6; sphere++) {  // every joint sphere starts at the base position
        memcpy(f->previous_sphere[sphere].v, &f->base_position, sizeof f->base_position);
        f->previous_sphere[sphere].w = f->base_position_w;
    }
    f->push = (T6Vec3){};  // no push from the other fighter
    t6_push_init(f);
    t6_previous_root(f);
}

// The shot stops; its mode and tail stay (FUN_001ce8bc).
static void stop_shot(T6ShotState *shot) {
    shot->free_frames = 0;
    shot->length = 0.0f;
    shot->script.frames = 0;
    shot->script.curve_frames = 0;
}

// Move var E holds a round mark of the move data; it is cleared with the round marks.
static void clear_vars(T6Fighter *f, bool marks) {
    int mark_slot = MOVE_VAR_SLOT[MOVE_VAR_E];
    uint16_t mark = f->vars[mark_slot];
    memset(f->vars, 0, sizeof f->vars);  // clear all move variables
    if (!marks) f->vars[mark_slot] = mark;  // but keep the mark unless marks are cleared
}

static void clear_move_state(T6Fighter *f, bool marks) {
    f->reaction_facing = 0;  // forget the hit and guard state of the old move
    f->approach_state = 0;
    f->hit_this_move = 0;
    f->was_guarding = 0;
    f->streak_clean = 0;
    f->reaction_rule = 0;
    f->root_mode = 0;
    f->hold_count = -1;  // no hold
    f->juggle_count = 0;  // no juggle
    f->bounds_used = 0;
    f->in_rage = 0;
    f->launch_index = 0;
    f->countdown = 0;
    f->hit_lockout = 0;  // a hit can land at once
    f->pushback_frames = 0;  // no pushback running
    f->pushback_curve_frames = 0;
    f->turn_frames = 0;  // no turn running
    f->turn_speed = 0;
    f->juggle_weight = 0;
    f->thrown_length = 0;
    f->repeat_count = 0;
    f->repeat_timer = 0;
    f->force_counter_hit = 0;
    clear_vars(f, marks);  // clear move variables
    f->slide_frames = 0;  // no slide running
    f->marked_finished = 0;
    stop_shot(&f->special.shot);  // no shot flying
    f->blend.offset = (T6Vec3){};  // no blend running
    f->blend.ratio = 0.0f;
    f->blend.done.frames = 0;
    f->pushback = t6_ref(0, -1);  // no pushback move
    f->blend.length.frames = 0;
    f->ko = 0;  // not knocked out
    f->counter_hit = 0;
    f->guarded = 0;
    f->clean_hit = 0;
    f->end_yaw_flag = 0;
    f->in_air_window = 0;
    f->self_damage = (T6SelfDamage){};  // no self damage
    f->ko_scored = 0;
    f->stage_hit_new = 0;
    f->input_window = 0;  // the cancel scan starts clean
    f->lookahead = 0;
    f->pivot_request = 0;
    f->damage_absolute = 0;  // the damage of this frame starts at zero
    f->reversal_damage = 0;
    f->damage_raw_frame = 0;
    f->damage_taken_frame = 0;
    f->damage_hits_frame = 0;
}

static bool clears_marks(const T6World *w, T6MarksRule rule) {
    if (rule == T6_MARKS_CLEARED_FIRST_ROUND) return w->round.round == 1;  // this rule clears the marks only in the first round
    return rule == T6_MARKS_CLEARED;  // otherwise only when the rule says clear
}

void t6_fighter_reset(T6World *w, T6Fighter *f, T6Fighter *opponent, T6RoundSetup setup) {
    f->right_hand_pose = (T6PoseProp){};  // before the start move, whose properties may pose again
    f->left_hand_pose = (T6PoseProp){};
    f->face_pose = (T6PoseProp){};
    f->other_pose = (T6PoseProp){};
    T6Side start_side = T6_SIDE_LEFT;  // until the host's next frame: side 2 starts on the right
    if (f->slot != 0) start_side = T6_SIDE_RIGHT;
    int16_t opponent_index = (int16_t)t6_object_index(w, opponent);
    f->opponent = opponent_index;  // each fighter targets the other
    f->target = opponent_index;
    f->distance = START_DISTANCE;  // distance to the opponent starts at its default
    f->distance2 = START_DISTANCE;
    w->distance = START_DISTANCE;
    f->sway_scale = 1.0f;
    f->roll = (uint16_t)t6_rand(&w->rng);  // a fresh random roll for the move
    f->moveset_scan = f->data;  // all movesets resolve in their own move data
    f->moveset_decided = f->data;
    f->moveset = f->data;
    f->move_overwrite_count = 0;  // the round starts with the loaded moves
    f->option8 = NO_OPTION;  // no option picked by the cancel scan
    t6_input_round_start(&f->input);  // start the input state of the round
    f->cancel_lock = 0;
    float held_x = f->base_position.x, held_z = f->base_position.z;  // remember the position
    int16_t held_move_yaw = f->move_yaw, held_facing = f->facing;
    T6StdInput pad = w->fighters[f->slot & 1]->standard_input;  // the pad of their side
    T6History *history = NULL;  // only fighters, not extras, keep an input history
    if (f->kind == 0) history = &f->history;
    t6_input_neutral(&f->input, history, pad);
    if (!setup.counts_round &&  // not a counted round and driven by the pad:
        t6_input_pad_driven(&f->input))
        t6_input_sample_of(w, f);  // sample the pad input too
    bool away = setup.other_away && f->kind == 0 &&  // the fighter not in focus plays the away move
                f->slot != t6_round_focus(w, setup);
    start_move(w, f, opponent, away);  // put the start move in
    t6_input_neutral(&f->input, history, pad);
    t6_round_stand_at(f, held_x, held_z);  // stand where they stood before the start move
    if (setup.on_entrance_point) {  // at the entrance point, keep the old turn and facing
        f->move_yaw = held_move_yaw;
        f->facing = held_facing;
    }
    if (setup.shifts) step_back(w, f);  // step back for the first move
    clear_wall_and_push_history(f);
    if (f->kind == 0) {  // a fighter gets full health, an object its start health
        t6_health_reset(f);
    } else {
        f->health = OBJECT_START_HEALTH.raw;
        f->max_health = OBJECT_START_HEALTH.raw;
    }
    bool marks = clears_marks(w, setup.marks);
    if (marks) f->last_round = T6_ROUND_NONE;  // forget who won the last round
    clear_move_state(f, marks);
    t6_input_round_end(&f->input, start_side);
    f->skip_motion = 1;  // skip the motion step this frame
    t6_hit_records_clear(w, f);  // no hits on record
    f->hit_record = 0;
    t6_hurtbox_radii(f);  // set the hurtbox sizes
    memcpy(f->last_base, &f->base_position, sizeof f->base_position);
    f->last_base[3] = f->base_position_w;
    f->last_y = f->position.y;  // remember the height
    t6_wall_clear(f);  // no wall contact
    f->neutral_guard = 1;  // by default a neutral stick guards
    if (t6_input_cpu_driven(&f->input) || f->input.control == T6_CONTROL_NONE_4)  // CPU fighters hold back to guard
        f->neutral_guard = 0;
}
