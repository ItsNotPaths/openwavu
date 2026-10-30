#include "sim/decide.h"

#include <stdint.h>

#include "sim/constants.h"
#include "sim/damage.h"
#include "sim/facing.h"
#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/motion.h"
#include "sim/properties.h"
#include "sim/requirements.h"
#include "sim/state.h"
#include "sim/transition.h"
#include "sim/units.h"

// --- reactions

// Slots of the reaction list (T5Reaction.move). The standing slots have the crouching variant after them.
enum {
    SLOT_FRONT = 0, SLOT_COUNTER = 2, SLOT_LEFT = 4, SLOT_RIGHT = 6, SLOT_BACK = 8, SLOT_GUARD = 10,
    SLOT_WALL = 12, SLOT_DOWNED = 13,
};

// A reaction on the ground: its motion code, its start alignment, and its slot of the reaction list.
typedef struct { uint8_t code; T5StartAlignment align; uint8_t slot; } ReactionRow;

static constexpr ReactionRow GUARD = {MOTION_GUARD, START_KEEP, SLOT_GUARD};
static constexpr ReactionRow DOWNED = {MOTION_HIT_DOWN, START_KEEP, SLOT_DOWNED};
static constexpr ReactionRow WALL = {MOTION_HIT_DOWN, START_KEEP, SLOT_WALL};
static constexpr ReactionRow COUNTER = {MOTION_COUNTER, START_KEEP, SLOT_COUNTER};
static const ReactionRow BY_SIDE[T5_HIT_SIDES] = {
    [HIT_FRONT] = {MOTION_HIT_FRONT, START_YAW_TO_FACING, SLOT_FRONT},
    [HIT_LEFT] = {MOTION_HIT_LEFT, START_YAW_TO_FACING, SLOT_LEFT},
    [HIT_BACK] = {MOTION_HIT_BACK, START_YAW_TO_FACING, SLOT_BACK},
    [HIT_RIGHT] = {MOTION_HIT_RIGHT, START_YAW_TO_FACING, SLOT_RIGHT},
};

// The alignment that keeps the root turn of the anim out of the facing (the next row of the start table).
static T5StartAlignment root_align(T5StartAlignment align) {
    if (align == START_YAW_TO_FACING) return START_YAW_TO_FACING_ROOT;
    return START_KEEP_ROOT;
}

static uint16_t juggle_word(T5World *w, T5Fighter *f) {  // build the word that starts a launch reaction
    return t5_transition_filter(w, f, t5_transition(TRANSITION_JUGGLE, START_YAW_TO_REFERENCE_LESS_REACTION, MOTION_JUGGLE));
}

// The reaction of a row: the root turn of the anim stays out of the facing unless the reaction faces the look direction.
static void react(T5World *w, T5Fighter *f, ReactionRow row, bool variant) {
    T5StartAlignment align = row.align;
    if (f->reaction_facing != REACTION_FACING_LOOK)  // the reaction does not face the look direction:
        align = root_align(align);  // keep the anim's root turn out of the facing
    f->transition = t5_transition_filter(w, f,  // start the reaction move from its first frame
        t5_transition(TRANSITION_START, align, row.code));
    f->pending_flags.turn = f->reaction_facing == REACTION_FACING_TURNED;  // reaction turns the fighter around
    f->pending_id = (int16_t)f->reaction.move[row.slot + variant];  // reaction move: row slot, plus one if crouching
}

// The generic launches by the side of the hit; a fighter in a downed state turns the other way.
typedef struct { int16_t standing, downed; } LaunchRow;

static const LaunchRow LAUNCH_BY_SIDE[T5_HIT_SIDES] = {
    [HIT_FRONT] = {LAUNCH_PLAIN, LAUNCH_DOWN_FRONT_RIGHT},
    [HIT_LEFT] = {LAUNCH_LEFT, LAUNCH_DOWN_BACK_LEFT},
    [HIT_BACK] = {LAUNCH_PLAIN, LAUNCH_DOWN_BACK_LEFT},
    [HIT_RIGHT] = {LAUNCH_RIGHT, LAUNCH_DOWN_FRONT_RIGHT},
};

// Low: near the floor, or already in the low launch.
static bool launched_low(const T5World *w, const T5Fighter *f) {
    uint32_t low_launch = t5_set(w, f->data)->alias_defaults[T5_ALIAS_LAUNCH + LAUNCH_LOW - T5_ALIAS_BASE];
    return f->base_position.y <= LOW_LAUNCH_HEIGHT || f->applied_move_id == (int32_t)low_launch;
}

// A downed fighter hit from the front or the back takes the low launch when they are low.
static int16_t launch_entry(const T5World *w, const T5Fighter *f) {
    LaunchRow row = LAUNCH_BY_SIDE[f->hit_side];  // launch pair for the side that was hit
    if (!t5_state_has(f->state, STATE_DOWNED)) return row.standing;  // not downed: the standing launch of that side
    bool face_on = f->hit_side == HIT_FRONT || f->hit_side == HIT_BACK;  // hit from the front or the back
    if (face_on && launched_low(w, f)) return LAUNCH_LOW;  // and low to the floor: the low launch
    return row.downed;
}

void t5_juggle_reaction(const T5World *w, T5Fighter *f) {
    f->launch_index = launch_entry(w, f);  // pick which generic launch to play
    f->pending_id = (int16_t)(T5_ALIAS_LAUNCH + f->launch_index);  // launch moves are aliases after the first launch alias
}

static void air_reaction(const T5World *w, T5Fighter *f) {
    if (f->air_reaction_list == 0) {  // no air reaction list: fall back to the generic launch
        t5_juggle_reaction(w, f);
        return;
    }
    bool downed = t5_state_has(f->state, STATE_DOWNED);  // downed picks the variant after the slot
    f->pending_flags.turn = f->reaction_facing == REACTION_FACING_TURNED;  // reaction turns the fighter around
    f->pending_id = (int16_t)f->reaction.move[BY_SIDE[f->hit_side].slot + downed];  // air reaction of the hit side
}

// The reaction on the ground that is not guarded.
static void ground_reaction(T5World *w, T5Fighter *f) {
    bool crouching = !t5_state_has(f->state, STATE_STANDING);  // crouching is anything but standing; it picks the crouch variant
    if (t5_state_has(f->state, STATE_DOWNED)) react(w, f, DOWNED, false);  // downed: the downed reaction
    else if (t5_state_has(f->state, STATE_AT_WALL)) react(w, f, WALL, false);  // at a wall: the wall reaction
    else if (f->counter_hit != 0 && f->hit_side == HIT_FRONT)  // counter hit from the front
        react(w, f, COUNTER, crouching);
    else react(w, f, BY_SIDE[f->hit_side], crouching);  // else the reaction of the side that was hit
}

static void set_pending_move(T5World *w, T5Fighter *f) {
    f->pending_id_high = (uint16_t)f->pending_id >= T5_ALIAS_BASE;  // ids from the alias base up are the fighter's own moves
    f->pending_move = t5_move_lookup(w, f, (uint16_t)f->pending_id);  // find the move data for the pending id
}

// The attacker (its second argument) is only passed on to the air launch, which ignores it.
void t5_reaction_move(T5World *w, T5Fighter *f) {
    f->track_pick = (T5TrackingPick){};  // forget any tracking picked for an earlier move
    f->pending_flags = (T5PendingFlags){};  // clear the flags of an earlier pending move
    if (f->guarded != 0 && !t5_off_ground(f)) {  // guarding on the ground: play the guard reaction
        react(w, f, GUARD, !t5_state_has(f->state, STATE_STANDING));
        f->track_pick = t5_pick_guard(w, (uint8_t)f->moveset);  // pick the tracking for the guard
    } else if (f->guarded != 0) {  // guarding in the air: a launch that plays the air guard move
        f->transition = juggle_word(w, f);
        f->launch_index = LAUNCH_PLAIN;  // plain launch
        f->pending_id = (int16_t)T5_ALIAS_GUARD_AIR;
    } else if (t5_off_ground(f)) {  // hit in the air: juggle launch, then the air reaction
        f->transition = juggle_word(w, f);
        air_reaction(w, f);
    } else {  // hit on the ground
        ground_reaction(w, f);
    }
    f->pending_frame = f->frame;  // the reaction starts at the frame the fighter is on
    set_pending_move(w, f);
}

// The KO move starts at once, as a clean hit.
void t5_ko_move(T5World *w, T5Fighter *f) {
    f->pending_id = (int16_t)T5_ALIAS_KO;  // queue the KO move
    f->pending_move = t5_move_lookup(w, f, T5_ALIAS_KO);
    f->frame = 1;  // it starts at frame 1 right away
    f->pending_frame = 1;
    f->transition = t5_transition_filter(w, f,  // start facing the fighter, no motion code
        t5_transition(TRANSITION_START, START_YAW_TO_FACING, MOTION_NONE));
    f->pending_id_high = 1;
    f->clean_hit = 1;  // counts as a clean hit
    f->guarded = 0;  // no longer guarding
    f->pending_flags.no_blend_out = 0;  // clear the flags that would alter the KO move
    f->guard_mask = 0;
    f->pending_flags.no_root_fix = 0;
    f->pending_flags.root_hips = 0;
}

// --- the cancel scan

// One scan of a cancel list: `plain` owns the list and its requirements, `group` the group cancels
// and the input sequences. A cancel taken from a group entry reads the requirements of the group's set.
typedef struct {
    T5World *world;
    T5Fighter *f;
    const T5Fighter *opponent;
    const T5Motbin *plain, *group;
    uint8_t plain_set, group_set;
} Scan;

static bool in_group(const Scan *scan, const T5Cancel *cancel) {
    uintptr_t address = (uintptr_t)cancel,  // where the cancel sits in memory
              first = (uintptr_t)scan->group->group_cancels;  // start of the group cancels
    return address >= first &&  // inside the group's cancels?
           address < first + (uintptr_t)scan->group->group_cancel_count * sizeof *cancel;
}

static uint8_t owner_set(const Scan *scan, const T5Cancel *cancel) {
    if (in_group(scan, cancel)) return scan->group_set;  // group cancel: the group's set owns it
    return scan->plain_set;
}

static const T5Requirement *requirements_of(const Scan *scan, const T5Cancel *cancel) {
    if (in_group(scan, cancel))  // group cancel: the group's requirements
        return &scan->group->requirements[cancel->requirements];
    return &scan->plain->requirements[cancel->requirements];
}

static void scan_reset(void *context) { t5_throw_forget(((Scan *)context)->f); }  // scan hook: a new scan forgets the throw cache

static bool scan_check(void *context, const T5Cancel *cancel) {  // scan hook: do the cancel's requirements pass
    Scan *scan = context;
    return t5_requirements(scan->world, requirements_of(scan, cancel), scan->f, scan->opponent);
}

static void scan_apply(void *context, const T5Cancel *cancel) {  // scan hook: run the cancel's instant properties
    Scan *scan = context;
    if (in_group(scan, cancel))  // a group cancel reads the group's set
        t5_instant_props(scan->world, scan->f, scan->group, (int32_t)cancel->requirements, T5_FROM_GROUP_CANCEL);
    else
        t5_instant_props(scan->world, scan->f, scan->plain, (int32_t)cancel->requirements, T5_FROM_CANCEL);
}

static Scan scan_in(T5World *w, T5Fighter *f, const T5Fighter *opponent, uint32_t set) {
    return (Scan){w, f, opponent, t5_set(w, set), t5_set(w, f->moveset_scan), (uint8_t)set, (uint8_t)f->moveset_scan};
}

// A scan with its group cancels from `group_set`. The game keeps that slot on the fighter.
static Scan scan_from(T5World *w, T5Fighter *f, const T5Fighter *opponent, uint32_t set, uint8_t group_set) {
    f->moveset_scan = group_set;
    return scan_in(w, f, opponent, set);
}

// A walk over a cancel list by hand: a group entry steps into the group's cancels, the group's end steps back past it.
typedef struct { const T5Cancel *entry, *group; } Walk;

// A stray group end (no group) stops the walk with `entry` NULL; the game would read a bad address.
static Walk walk_enter(const Scan *scan, Walk walk) {
    if (walk.entry->command.code == T5_CANCEL_GROUP)  // group entry: step into the group's cancels, remember the entry
        return (Walk){&scan->group->group_cancels[walk.entry->move], walk.entry};
    if (walk.entry->command.code != T5_CANCEL_GROUP_END) return walk;  // an ordinary entry: stay on it
    if (walk.group == NULL) return (Walk){NULL, NULL};  // stray group end with no group: stop
    return walk_enter(scan, (Walk){walk.group + 1, walk.group});  // group end: step back to the entry after the group entry
}

static Walk walk_start(const Scan *scan, uint32_t first) {  // first entry of a list
    return walk_enter(scan, (Walk){&scan->plain->cancels[first], NULL});
}
static Walk walk_next(const Scan *scan, Walk walk) {  // next entry, stepping through groups
    return walk_enter(scan, (Walk){walk.entry + 1, walk.group});
}
static bool walk_done(Walk walk) {  // the list ends at its end entry
    return walk.entry == NULL || walk.entry->command.code == T5_CANCEL_END;
}

// on the list that starts at `first` in the set of `scan`. The scan reads and writes option8 of f.
static const T5Cancel *scan_list(Scan *scan, uint32_t first, int32_t frame, bool *input_window) {
    T5Fighter *f = scan->f;
    T5CancelScan cancel_scan = {&f->input, &f->history, scan->group, f->cancel_lock, f->option8, false,  // scan state
                         {scan_reset, scan_check, scan_apply, scan}};
    const T5Cancel *cancel = t5_cancel_scan(&scan->plain->cancels[first], frame, &cancel_scan);  // first fit that stops
    f->option8 = cancel_scan.option8;  // keep the option8 the scan left
    *input_window = cancel_scan.input_window;  // report whether an input window entry was open
    return cancel;
}

const T5Cancel *t5_cancel_walk(T5World *w, T5Fighter *f, const T5Fighter *opponent, uint32_t set, uint32_t first, int32_t frame,
                               bool *input_window) {
    Scan scan = scan_in(w, f, opponent, set);
    return scan_list(&scan, first, frame, input_window);
}

// A move id at T5_ALIAS_BASE and up names an alias of the fighter's own moves.
static bool own_alias(uint16_t move) { return move >= T5_ALIAS_BASE; }

// The transition word of a cancel, through the filter of the pending move, and the tracking it picks.
static void take_transition(T5World *w, T5Fighter *f, const T5Cancel *cancel, uint8_t owner) {
    uint16_t raw = t5_extradata_transition(cancel->extradata);  // transition word of the cancel
    f->transition = t5_transition_filter(w, f, raw);  // through the filter of the pending move
    f->track_pick = t5_pick_of_cancel(w, owner, cancel, raw, f->transition);  // pick the tracking that goes with the cancel
}

static void take_end_yaw(const T5World *w, T5Fighter *f) {
    f->end_yaw_flag = (t5_move_at(w, f->move)->flags & T5_MOVE_TURNS_AT_END) != 0;  // move turns at its end
}

// A cancel of the move: the pending move starts at its start frame (its window end when playing backward).
static void take_cancel(T5World *w, T5Fighter *f, const T5Cancel *cancel, uint8_t owner) {
    enum { START_FRAME_LAST = 255 };  // the cancel's start frame 255: the last frame of the current move
    f->pending_id = (int16_t)cancel->move;  // pending move is the cancel's move
    f->pending_move = t5_move_lookup(w, f, cancel->move);
    f->pending_frame = (int16_t)cancel->start_frame;  // start at the cancel's start frame
    if (f->play_direction < 0)  // playing backward: start at the window end instead
        f->pending_frame = (int16_t)cancel->window_end;
    if (f->pending_frame == START_FRAME_LAST)  // start frame 255 means the last frame of the current move
        f->pending_frame = (int16_t)t5_move_at(w, f->move)->length;
    take_transition(w, f, cancel, owner);
    f->pending_flags = t5_pending_flags_of(cancel->extradata);  // flags of the cancel go to the pending move
    f->pick_kind = PICKED_CANCEL;  // remember a cancel picked the move
    f->pending_id_high = own_alias(cancel->move);  // alias ids are the fighter's own moves
}

static bool first_frame_hit(Scan *scan, const T5Cancel *cancel, int32_t frame) {  // in window, input and requirements fit?
    return (cancel->option & T5_OPTION_FIRST_FRAME) && t5_frame_between(frame, cancel->window_start, cancel->window_end)
        && t5_command_match(&scan->f->input, &scan->f->history, scan->group, cancel) && scan_check(scan, cancel);
}

// A first-frame cancel was taken: the move starts at frame 1. The filter sees the pending frame of before.
static void take_first_frame(T5World *w, T5Fighter *f, const T5Cancel *cancel, uint8_t owner) {
    f->pending_id = (int16_t)cancel->move;
    f->pending_move = t5_move_lookup(w, f, cancel->move);
    take_transition(w, f, cancel, owner);
    f->pending_flags = t5_pending_flags_of(cancel->extradata);
    f->pick_kind = PICKED_CANCEL;
    f->pending_frame = 1;  // the move starts at frame 1
    f->frame = 1;
    f->pending_id_high = own_alias(cancel->move);
}

// No throw cache reset and no option 2 test, unlike the main scan. A stray group end returns none (the game would
// read a bad address).
enum T5FirstFrame t5_first_frame_select(T5World *w, T5Fighter *f, T5Fighter *opponent) {
    if (!f->move_start) return FIRST_FRAME_NONE;  // only on the first frame of a move
    Scan scan = scan_from(w, f, opponent, f->move.set, f->moveset);  // group cancels come from the fighter's moveset
    bool matched = false;
    Walk walk = walk_start(&scan, t5_move_at(w, f->move)->cancels);
    for (; !walk_done(walk); walk = walk_next(&scan, walk)) {  // walk every cancel of the current move
        if (!first_frame_hit(&scan, walk.entry, f->frame)) continue;  // not a first-frame hit: next entry
        scan_apply(&scan, walk.entry);  // a hit runs the instant properties of the cancel
        if (!(walk.entry->option & T5_OPTION_STOP)) {  // no stop flag: note the match and keep looking
            matched = true;
            continue;
        }
        take_first_frame(w, f, walk.entry, owner_set(&scan, walk.entry));  // stop flag: take this cancel
        return FIRST_FRAME_TAKEN;
    }
    if (matched && walk.entry != NULL) return FIRST_FRAME_MATCHED;  // something matched but nothing was taken: matched
    return FIRST_FRAME_NONE;
}

// The game turns the facing by one step less than half a turn here, and the yaws by half a turn.
static constexpr int16_t HALF_TURN_LESS_ONE = 32767;

// The facing a cancel's follow-up move is scanned from: past the end yaw of the current move, and half a turn
// more when the cancel turns the fighter around.
static void face_next_move(T5Fighter *f, int16_t end_yaw, uint32_t extradata) {
    float body_yaw = f->body_yaw, look_yaw = f->look_yaw;  // keep the facing and yaws as they are now
    if (end_yaw != 0) {  // the move turns at its end: rotate facing and yaws back by the end yaw
        f->facing = (int16_t)(f->facing - end_yaw);
        float turn = t5_angle65535_to_rad(end_yaw);
        f->body_yaw = t5_wrap_pi(body_yaw - turn);
        f->look_yaw = t5_wrap_pi(look_yaw - turn);
    }
    if (t5_extradata_turns(extradata)) {  // the cancel turns the fighter around: half a turn more
        f->body_yaw = t5_wrap_pi(f->body_yaw + T5_PI);
        f->facing = (int16_t)(f->facing + HALF_TURN_LESS_ONE);
        f->look_yaw = t5_wrap_pi(f->look_yaw + T5_PI);
    }
}

// The scan looks ahead past the end of the move when the end entry's window is near (with a press) or open.
static bool wants_lookahead(const T5Fighter *f, const T5Cancel *end) {
    if (f->play_direction < 1) return false;  // not playing forward: no look ahead
    if (f->frame < end->window_start)  // before the end window: look ahead only when close, with a button pressed
        return f->frame >= end->window_start - LOOKAHEAD_FRAMES.ticks &&  // within a few frames of it
               t5_input_pressed_any(&f->input);  // and a button is pressed
    return f->frame <= end->window_end;  // inside the window: yes
}

// The scan ahead from the end entry (requirements 124..126 read it; the entry stays set after the scan)
static void set_scan_mode(T5Fighter *f, enum T5ScanMode mode, const T5Cancel *end) {
    f->scan_ahead = (T5ScanAhead){mode, true, end->window_start, end->window_end};
}

// A follow-up cancel of the move that comes after `end`: the change goes straight to it at the end window. The transition
// takes the follow-up's word; a carried follow-up after a param end stays a param start.
static void take_ahead(T5World *w, T5Fighter *f, Scan *current, Scan *ahead, const T5Cancel *end, const T5Cancel *follow) {
    bool own_moves = own_alias(end->move);  // the end entry leads to one of the fighter's own moves
    f->pending_id = (int16_t)follow->move;  // the follow-up is the pending move
    f->lookahead_move = end->move;  // remember the move the end entry leads to
    scan_apply(ahead, follow);  // run the instant properties of the follow-up
    scan_apply(current, end);  // and of the end entry
    if (own_moves) f->pending_move = t5_own_move(w, f, (uint16_t)f->pending_id);
    else f->pending_move = t5_move_lookup(w, f, (uint16_t)f->pending_id);
    f->pending_frame = (int16_t)end->window_start;  // the change happens at the start of the end window
    take_transition(w, f, follow, owner_set(ahead, follow));
    f->pending_flags = t5_pending_flags_of(end->extradata);  // flags come from the end entry
    f->pending_flags.turn =  // turn if the follow-up and the end entry disagree on turning
        t5_extradata_turns(follow->extradata) != t5_extradata_turns(end->extradata);
    enum T5TransitionClass follow_class = t5_transition_class(t5_extradata_transition(follow->extradata));
    bool carried = follow_class == TRANSITION_CARRY || follow_class == TRANSITION_PARAM;  // frame carried or from a param
    if (carried &&  // a carried follow-up after a param end stays a param start
        t5_transition_class(t5_extradata_transition(end->extradata)) == TRANSITION_PARAM)
        f->transition = t5_transition_reclass(f->transition, TRANSITION_PARAM);
    f->pending_id_high = own_moves;  // alias ids are the fighter's own moves
    f->pick_kind = PICKED_AHEAD;
    take_end_yaw(w, f);  // flag if the current move turns the fighter at its end
}

// Scan the cancels of the move after `end` at its frame 1, facing as it will. Returns whether one was taken.
static bool look_ahead(T5World *w, T5Fighter *f, T5Fighter *opponent, Scan *current, const T5Cancel *end) {
    f->input_window = 1;  // looking ahead counts as an input window
    f->lookahead = 1;  // flag that this change is a look ahead
    T5Ref next = t5_move_lookup(w, f, end->move);  // the move the end entry leads to
    int16_t facing = f->facing;  // keep the facing and yaws to restore after
    float body_yaw = f->body_yaw, look_yaw = f->look_yaw;
    face_next_move(f, t5_move_at(w, f->move)->end_yaw, end->extradata);  // face as the next move will
    t5_relative_angles(w, f, opponent);  // recompute the angles to the opponent from that facing
    uint8_t group_set = f->moveset;  // group cancels come from the fighter's moveset
    if (own_alias(end->move)) group_set = f->data;  // an own alias: from the fighter's data set instead
    Scan ahead = scan_from(w, f, opponent, next.set, group_set);  // scan the next move's cancels
    set_scan_mode(f, SCAN_AHEAD, end);
    bool input_window;
    const T5Cancel *follow = scan_list(&ahead, t5_move_at(w, next)->cancels, 1, &input_window);  // next move, frame 1
    set_scan_mode(f, SCAN_OWN_MOVE, end);  // back to scanning the current move
    f->facing = facing;  // restore the real facing and yaws
    f->body_yaw = body_yaw;
    f->look_yaw = look_yaw;
    t5_relative_angles(w, f, opponent);  // and the real angles to the opponent
    if (follow->command.code == T5_CANCEL_END) return false;  // the next move has no cancel for this frame: nothing taken
    take_ahead(w, f, current, &ahead, end, follow);  // take the follow-up cancel
    return true;
}

// The move runs out this frame: its end entry starts the move it ends in, at the frame it is on.
static void take_move_end(T5World *w, T5Fighter *f, Scan *current, const T5Cancel *end) {
    int32_t frame = f->frame;  // current frame
    int32_t after = frame + f->play_direction;  // frame after this one, in the play direction
    if (t5_move_at(w, f->move)->length >= after && after >= 1) return;  // the move still has frames left: it does not end yet
    f->pending_frame = (int16_t)frame;  // the next move starts at the frame the fighter is on
    f->pending_id = (int16_t)end->move;  // the move the end entry leads to
    scan_apply(current, end);  // run the instant properties of the end entry
    f->pending_move = t5_move_lookup(w, f, (uint16_t)f->pending_id);
    take_transition(w, f, end, owner_set(current, end));
    f->pending_flags = t5_pending_flags_of(end->extradata);  // flags of the end entry go to the pending move
    f->pick_kind = PICKED_MOVE_END;  // remember the move end picked the move
    take_end_yaw(w, f);
    f->pending_id_high = own_alias(end->move);  // alias ids are the fighter's own moves
}

void t5_scan_cancels(T5World *w, T5Fighter *f, T5Fighter *opponent) {
    f->input_window = 0;  // no cancel input window seen yet
    f->lookahead = 0;  // no look ahead yet
    if (!t5_ref_none(f->pending_move) ||  // a move is already pending, or
        (int16_t)f->cancel_lock > CANCEL_LOCK_LIMIT) return;  // the cancel lock is high: no scan
    Scan current = scan_from(w, f, opponent, f->move.set, f->moveset);  // group cancels come from the fighter's moveset
    bool input_window;
    const T5Cancel *cancel = scan_list(&current, t5_move_at(w, f->move)->cancels, f->frame, &input_window);  // this frame
    if (input_window) f->input_window = 1;  // an input window was open
    if (cancel->command.code != T5_CANCEL_END) {  // a real cancel was found (not the end entry): take it
        take_cancel(w, f, cancel, owner_set(&current, cancel));
        return;
    }
    if (wants_lookahead(f, cancel) && look_ahead(w, f, opponent, &current, cancel)) return;  // end entry: look ahead
    take_move_end(w, f, &current, cancel);  // else maybe the move runs out now
}

// --- reversals: a fighter who was hit answers with an option 2 cancel of its move

// Window, option 2, input and requirements of one entry. A passing entry also runs its instant properties.
static bool reversal_stops(Scan *scan, const T5Cancel *cancel, int32_t frame) {
    T5Fighter *f = scan->f;
    if (!t5_frame_between(frame, cancel->window_start, cancel->window_end) ||  // outside its window, or
        !(cancel->option & T5_OPTION_REVERSAL)) return false;  // not a reversal entry
    if (!t5_command_match(&f->input, &scan->world->fighters[f->slot]->history,  // input does not match: no
                          scan->group, cancel)) return false;
    if (!scan_check(scan, cancel)) return false;  // requirements fail: no
    scan_apply(scan, cancel);  // it passes: run the instant properties
    return cancel->option & T5_OPTION_STOP;  // stops the scan if it has the stop flag
}

// The reversal move replaces the hit: no hit taken or landed this frame.
static void take_reversal(T5World *w, T5Fighter *f, T5Fighter *opponent, const T5Cancel *cancel, uint8_t owner) {
    f->pending_id = (int16_t)cancel->move;  // the reversal move is the pending move
    f->pending_move = t5_move_lookup(w, f, cancel->move);
    f->clean_hit = 0;  // the hit is undone: not a clean hit
    f->hit_this_move = 0;
    f->hit_taken = 0;
    f->guarded = 0;
    f->pending_frame = (int16_t)cancel->start_frame;
    f->hit_lockout = 0;  // no hit lockout
    opponent->hit_landed = 0;  // the opponent's hit counts as not landed
    t5_hit_victims_clear(f);  // forget who this fighter was hit by
    opponent->landed_since_move_start = 0;
    opponent->landed_this_move = 0;
    take_transition(w, f, cancel, owner);
    f->pending_flags = (T5PendingFlags){};
    f->pending_id_high = own_alias(cancel->move);
    for (int index = 0; index < T5_HIT_RECORDS; index++) f->records[index].flags &= ~T5_HIT_LIVE;  // records stop being live
    if (!(cancel->option & T5_OPTION_NO_DAMAGE))  // unless the cancel has no damage: the reversal deals damage
        f->reversal_damage = (uint16_t)(t5_ratio_of(opponent->damage, REVERSAL_DAMAGE_SHARE)  // half the attacker's damage
                                        + REVERSAL_DAMAGE_ADD);  // plus a flat bonus
}

void t5_reversal(T5World *w, T5Fighter *f, T5Fighter *opponent) {
    f->reversal_damage = 0;  // no reversal damage unless one is taken
    if (!f->hit_taken) return;  // only after a hit was taken
    Scan scan = scan_from(w, f, opponent, f->move.set, f->moveset);  // group cancels come from the fighter's moveset
    for (Walk walk = walk_start(&scan, t5_move_at(w, f->move)->cancels);  // walk every cancel of the move
         !walk_done(walk); walk = walk_next(&scan, walk)) {
        if (!reversal_stops(&scan, walk.entry, f->frame)) continue;  // not a reversal that stops the scan: next entry
        take_reversal(w, f, opponent, walk.entry, owner_set(&scan, walk.entry));  // take the reversal and stop
        return;
    }
}

// The second call sees what the first changed.
void t5_reversals_pass(T5World *w) {
    T5TurnOrder order = t5_turn_order(w);  // players in turn order
    t5_reversal(w, order.first, t5_object(w, order.first->opponent));
    t5_reversal(w, order.second, t5_object(w, order.second->opponent));
}

// --- the decide pass

// A hit of the attacker's move plays a reaction move.
static bool reacts(const T5Fighter *f, uint8_t rule) {
    if (rule == REACT_ALWAYS) return true;  // the move always reacts
    return rule == REACT_GROUNDED && f->in_air_window == 0 &&  // grounded rule: not in an air window
           !t5_state_has(f->state, STATE_AT_WALL);  // and not at a wall
}

// The reaction to the hit that counts. Reaction ids index the attacker's move set.
static void take_hit(T5World *w, T5Fighter *f, uint8_t moveset) {
    T5Fighter *attacker = t5_object(w, f->records[f->hit_record].attacker);  // the attacker of the hit that counts
    t5_relative_angles(w, f, attacker);  // work out the angles to the attacker
    f->moveset = attacker->moveset_decided;  // reaction ids index the attacker's move set
    if (attacker->reaction_rule == REACT_HARMLESS) {  // harmless hit: no reaction, keep our own move set
        f->moveset = moveset;
    } else if (reacts(f, attacker->reaction_rule)) {  // the hit reacts: pick the reaction move
        t5_reaction_move(w, f);
        f->pick_kind = PICKED_REACTION;
        if (t5_throwing(f->throw.chain))  // they are the thrower: their own hits become harmless
            f->reaction_rule = REACT_HARMLESS;
    }
}

// The KO move cuts the pending move unless it has T5_MOVE_NO_KO: a move back to idle, or one with no wall state and no air window.
static bool ko_cuts(const T5Move *move) {
    if ((move->flags & T5_MOVE_NO_KO) != 0) return false;  // the move may not be cut by KO
    return t5_move_ends_in_idle(move) ||  // it ends in idle, or
           (!t5_state_has(move->vuln, STATE_AT_WALL) && move->window_start == 0);  // has no wall state and no air window
}

// The stats (outside the sim) are left out.
void t5_decide_object(T5World *w, T5Fighter *f) {
    uint8_t moveset = f->moveset;  // keep the move set from before the hit
    f->self_damage.effect = SELF_DAMAGE_NONE;  // the points stay, as in the game
    if (f->hit_taken != 0) take_hit(w, f, moveset);  // a hit was taken: pick the reaction
    T5Fighter *opponent = t5_object(w, f->opponent);  // the opponent
    t5_relative_angles(w, f, opponent);  // angles to the opponent
    if (t5_ref_none(f->pending_move)) {  // no pending move yet: look for one
        f->moveset = moveset;  // back to our own move set
        if (f->kind == T5_KIND_FIGHTER) t5_scan_cancels(w, f, opponent);  // only fighters scan cancels
        // (hole port-extra-scan :tags (port tk5mod) :sev gap) the cancel scan of the extras (kind != 0): not ported, so an extra never picks a move from its cancels.
    }
    if (f->health == 0 && f->clean_hit != 0 && w->mode != T5_MODE_PRACTICE) {  // dead from a clean hit, outside practice mode
        if (ko_cuts(t5_move_at(w, t5_move_lookup(w, f, (uint16_t)f->pending_id))))  // the KO move cuts the pending move
            t5_ko_move(w, f);
    }
    if (t5_transition_class(f->transition) == TRANSITION_THROWER)  // thrower: pair up with the opponent
        t5_throw_link(w, f, f->opponent);
}

static void latch(T5Fighter *object) {
    object->frame_decided = object->frame;  // remember the frame decided on
    object->moveset_decided = object->moveset;  // and the move set decided on
}

void t5_decide_pass(T5World *w) {
    int32_t extras = t5_extra_count(w);  // stage extras
    if (!t5_phase_frozen(w)) {  // not frozen (the fighters stand still when frozen)
        for (int index = 0; index < T5_FIGHTER_COUNT; index++)  // remember frame and move set before anyone decides
            latch(w->fighters[index]);
        for (int32_t index = 0; index < extras; index++) latch(t5_extra_entry(w, index));  // and of the extras
        T5TurnOrder order = t5_turn_order(w);  // turn order
        t5_decide_object(w, order.first);  // first in turn order decides
        t5_decide_object(w, order.second);  // then the second, who sees what the first changed
    }
    for (int32_t index = 0; index < extras; index++)  // extras decide even when frozen
        t5_decide_object(w, t5_extra_entry(w, index));
}
