#include "sim/facing.h"

#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/motion.h"
#include "sim/transition.h"

static int16_t steps(T5Degrees degrees) { return t5_angle_s16(t5_degrees_angle(degrees)); }  // degrees to angle steps

static int16_t angle_of(float y, float x) { return t5_rad_to_angle(t5_atan2(y, x)); }  // 16-bit angle of the vector (x, y)

static uint16_t ones_abs(int16_t value) {
    if (value < 0) return (uint16_t)~value;  // negative: flip bits (ones' complement abs)
    return (uint16_t)value;
}

// The opponent's base position at the move change, from this fighter's, as an angle.
static int16_t start_spot_angle(const T5Fighter *f) {
    float to_x = (float)(int32_t)((uint32_t)f->opponent_start_x - (uint32_t)t5_fctiwz(f->base_position.x));  // to opponent start
    float to_z = (float)(int32_t)((uint32_t)f->opponent_start_z - (uint32_t)t5_fctiwz(f->base_position.z));
    return angle_of(to_x, to_z);
}

static int16_t stage_centre_angle(const T5Fighter *f) {  // angle from this fighter toward the middle of the stage (the origin)
    float to_x = (float)t5_fctiwz(0.0f - f->base_position.x);
    float to_z = (float)t5_fctiwz(0.0f - f->base_position.z);
    return angle_of(to_x, to_z);
}

static int16_t side_of_opponent_angle(const T5Fighter *f) {
    int16_t lean = angle_of(f->root_offset.x, f->root_offset.z);  // which way the fighter's root offset leans
    int16_t offset = steps(SIDE_TARGET_OFFSET);  // how far to the side of the opponent to aim
    if (lean < 0) return (int16_t)(f->target_angle + offset);  // leaning one way: aim that far one side of the opponent
    return (int16_t)(f->target_angle - offset);  // leaning the other way: aim the same far to the other side
}

static int16_t look_angle(const T5Fighter *f) { return t5_rad_to_angle65535(t5_turn_positive(f->look_yaw)); }  // yaw as an angle

static int16_t target_angle(const T5Fighter *f, T5Target kind) {
    switch (kind) {
    case TARGET_NONE:
    case TARGET_OPPONENT: return f->target_angle;  // no target: same as the opponent
    case TARGET_BEHIND_OPPONENT: return t5_angle_offset(f->target_angle, HALF_TURN);  // the opposite way from the opponent
    case TARGET_REFERENCE: return f->near_side_angle;  // the opponent, or the other way when they stand behind
    case TARGET_SIDE_OF_OPPONENT: return side_of_opponent_angle(f);
    case TARGET_STAGE_CENTRE: return stage_centre_angle(f);
    case TARGET_OPPONENT_START_SPOT: return start_spot_angle(f);
    case TARGET_FACING: return f->facing;  // keep the way the fighter faces now
    case TARGET_LOOK: return look_angle(f);
    case TARGET_WALL: return f->wall_angle;  // the angle of the wall
    case TARGET_OPPONENT_OR_REFERENCE:
        if (f->opponent_angle > BEHIND_ANGLE.bits) return f->near_side_angle;  // opponent far behind: use the reference angle
        return f->target_angle;  // else aim at the opponent
    case TARGET_REFERENCE_LESS_REACTION: return (int16_t)(f->near_side_angle - f->reaction.angle[0]);  // reference less reaction
    }
    return f->target_angle;
}

static bool when_holds(T5When when, const T5Fighter *f) {
    if (when == WHEN_ALWAYS) return true;  // always true
    if (when == WHEN_UNLESS_ANIM_CHANGED) return !f->anim_changed;  // only when the move change did not switch anim
    return false;
}

static bool opponent_busy(const T5Fighter *f, const T5Fighter *opponent) {  // opponent counting down, this fighter has hit boxes
    return opponent->countdown != 0 && f->hitbox_slots != 0;
}

// Frames up to and including first_active, at least 1.
static int32_t startup_frames_left(const T5Move *move, const T5Fighter *f) {
    int16_t left = (int16_t)(move->first_active - f->frame + 1);  // frames left of startup, counting the first active frame
    if (left > 0) return left;
    return 1;
}

static int32_t turn_rate(const T5FacingRate *rate_row, const T5Fighter *f) {
    int32_t rate = steps(rate_row->normal);  // normal turn rate a frame
    if (f->in_air_window) {  // in the air window: use the air rate
        rate = steps(rate_row->air);
    } else if (f->frame_9c >= rate_row->late_from.ticks) {  // late in the move: use the late rate
        rate = steps(rate_row->late);
        if (rate_row->halving == HALVING_LATE) rate = steps(rate_row->normal) / 2;  // late rate is half the normal rate
    }
    if (rate_row->halving == HALVING_ALL) rate = (int16_t)(rate >> 1);  // halve the picked rate
    return rate;
}

// One even turn over the rest of the startup, run by turn_speed and turn_frames in the move step.
static void spread_turn(const T5Move *move, T5Fighter *f, int16_t aim) {
    int16_t left = (int16_t)(move->first_active - f->frame);  // frames left until the move turns active
    f->turn_frames = left;
    if (left < 1) f->turn_frames = 1;  // at least one frame
    f->turn_speed = t5_clamp_s16(t5_divw(aim, f->turn_frames), steps(TURN_RATE_SPREAD_MAX));  // even share per frame, capped
    f->facing_state.phase = FACING_SCRIPTED;  // the move step now runs the turn
}

static bool spreads(const T5FacingGate *gate, const T5Fighter *f) {
    if (gate->kind == GATE_SPREAD_WHILE_BUSY) return true;  // busy opponent: always spread
    return gate->kind == GATE_SPREAD_EARLY_WHILE_BUSY && f->frame_9c <= gate->until.ticks;  // early: only while clock is early
}

// Turn toward the target by at most the rate a frame and the limit in all; the end stage runs after.
static void home(const T5World *w, T5Fighter *f, const T5Fighter *opponent, const T5FacingRow *row) {
    const T5Move *move = t5_move_at(w, f->move);  // this fighter's move and the opponent
    bool busy = opponent_busy(f, opponent);
    if (row->gate.kind == GATE_SKIP_WHILE_BUSY && (f->turn_frames != 0 || busy)) return;  // skip while turning or opponent busy

    int16_t aim = (int16_t)(target_angle(f, row->target) - f->facing);  // angle still to turn to face the target
    if (busy && spreads(&row->gate, f)) {  // busy opponent and the row asks for it: turn evenly over the startup
        spread_turn(move, f, aim);
        return;
    }

    int32_t step = t5_clamp_s16(aim / startup_frames_left(move, f), turn_rate(&row->rate, f));  // gap over startup frames, capped
    int16_t capped = (int16_t)t5_turn_cap(step, f->turn_total, steps(row->limit.total));  // rest of the allowance if over limit
    if (capped != 0) {  // the total limit stops the turn: use the capped step and go to re-aim
        f->facing_state.phase = FACING_REAIM;
        step = capped;
    }
    f->facing = (int16_t)(f->facing + step);  // turn the fighter
    f->turn_total = (int16_t)(f->turn_total + step);  // count the turn against the total limit
    if (when_holds(row->end.move_yaw_when, f)) f->move_yaw = f->facing;  // the move yaw follows the facing
    if (when_holds(row->end.pivot_when, f)) f->pivot_request = 1;  // ask for the anchor to re-pivot
    if (f->frame >= (int32_t)move->first_active + row->end.grace.ticks)  // past grace frames after first active
        f->facing_state.phase = row->end.phase;
}

// Approach by the distance: the closer the fighters, the larger the share of the gap per frame.
static int16_t close_frames(const T5World *w) {
    uint32_t distance = (uint32_t)((uint64_t)t5_fctidz(w->distance) + CLOSE_APPROACH_OFFSET);  // gap distance plus the offset
    uint32_t frames = CLOSE_APPROACH_NUMERATOR;
    if (distance != 0) frames = CLOSE_APPROACH_NUMERATOR / distance;  // divwu by zero returns the dividend
    return (int16_t)frames;
}

static void settle(const T5World *w, T5Fighter *f, const T5FacingRow *row) {
    int32_t frames = row->rate.frames.ticks;  // frames to close the gap: set by the row
    if (row->rate.frames_by_distance) frames = close_frames(w);  // or from the distance of the fighters
    int16_t yaw = t5_turn_approach(target_angle(f, row->target), f->move_yaw, frames);  // turn move yaw 1/frames toward target
    f->facing = yaw;  // facing and move yaw both take it
    f->move_yaw = yaw;
    if (when_holds(row->end.pivot_when, f)) f->pivot_request = 1;
}

// A side_band outside the sectors (the sim never makes one) reads as front.
static int32_t sweep_angle(const T5FacingLimit *limit, int16_t sector) {
    if (sector < 0 || sector >= SECTOR_COUNT) sector = SECTOR_FRONT;
    return steps(limit->sweep[sector]);
}

// Sweep the yaw to one side of the target over the move.
static void sweep(const T5World *w, T5Fighter *f, const T5FacingRow *row) {
    const T5Move *move = t5_move_at(w, f->move);
    if ((int32_t)move->length < f->frame) return;  // past the end of the move: stop
    int32_t swing = sweep_angle(&row->limit, f->side_band);  // swing angle for the side the opponent is on
    if (angle_of(f->root_offset.x, f->root_offset.z) < 0) swing = -swing;  // root offset leans the other way: swing the other way
    f->move_yaw = (int16_t)(target_angle(f, row->target) - t5_divw(f->frame * swing, move->length));  // swing grows with frame
    f->facing = t5_turn_approach(f->move_yaw, f->facing, row->rate.frames.ticks);  // the facing follows the move yaw
    if (when_holds(row->end.pivot_when, f)) f->pivot_request = 1;
}

// Close on the target a share of the gap that grows with the frame; ends with the move or its window.
static void ease_out(const T5World *w, T5Fighter *f, const T5FacingRow *row) {
    const T5Move *move = t5_move_at(w, f->move);
    int32_t last = move->window_end;  // end of the window, or of the move when it has no window
    if (last == 0) last = move->length;
    if (last < f->frame) return;  // past the end: stop
    int32_t gap = (int16_t)(target_angle(f, row->target) - f->facing);  // angle still to turn to face the target
    int32_t divisor = last;
    if (divisor == 0) divisor = 1;  // never divide by zero
    int16_t share = (int16_t)t5_divw(f->frame * gap, divisor);  // share grows with the frame
    f->facing = (int16_t)(f->facing + t5_clamp_s16(share, steps(row->rate.normal)));  // turn by the share, capped by the rate
}

// Close on the target a share of the gap that ramps up over the first frames of the move.
static void ease_in(T5Fighter *f, const T5FacingRow *row) {
    int32_t ramp = f->frame_9c;  // frames of the move so far, up to the ramp length
    if (ramp > row->rate.frames.ticks) ramp = row->rate.frames.ticks;
    int32_t gap = (int16_t)(target_angle(f, row->target) - f->facing);  // angle still to turn to face the target
    int16_t share = (int16_t)((gap * ramp) / row->rate.frames.ticks);  // share grows as the ramp fills
    f->facing = (int16_t)(f->facing + t5_clamp_s16(share, steps(row->rate.normal)));  // turn by the share, capped by the rate
}

// Face the spot where the opponent stood, on the near side of the turn.
static void leave(const T5World *w, T5Fighter *f, const T5FacingRow *row) {
    int16_t spot = target_angle(f, row->target);  // the angle where the opponent stood
    int16_t yaw = f->move_yaw;
    int16_t aim = spot;  // aim at the spot
    if (ones_abs((int16_t)(yaw - spot)) >= QUARTER_TURN.bits)  // spot a quarter turn or more away: aim opposite
        aim = t5_angle_offset(spot, HALF_TURN);
    int32_t gap = (int16_t)(aim - yaw);  // angle from the move yaw to the aim
    int16_t share = (int16_t)t5_divw(gap * f->frame, t5_move_at(w, f->move)->length);  // share grows with frame over length
    f->facing = (int16_t)(yaw + t5_clamp_s16(share, steps(row->rate.normal)));  // turn by the share, capped by the rate
    f->move_yaw = f->facing;  // move yaw follows
    if (when_holds(row->end.pivot_when, f)) f->pivot_request = 1;
}

// Every few frames of the active window, plan one scripted turn to the reference angle.
static void reaim(const T5World *w, T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    bool hit_landed = f->damage != 0 && move->window_start != 0 &&  // hit landed: damage dealt, move has a window
                      !f->in_air_window && f->frame >= (int32_t)move->last_active;  // not in air window, past last active
    if (hit_landed || f->no_reaim != 0) {  // after a landed hit, or when re-aim is off: cancel the scripted turn
        f->turn_speed = 0;
        f->turn_frames = 0;
        return;
    }
    int32_t since = f->frame - (int32_t)move->first_active;
    if (since <= 0 || since % REAIM_PERIOD.ticks != 0  // act only every few frames after first active
        || f->opponent_angle > steps(REAIM_OPPONENT_LIMIT))  // and not when the opponent is far to the side or behind
        return;
    int32_t left = (int32_t)move->length - f->frame;  // frames left in the move
    if (left < REAIM_MIN_TURN.ticks) left = REAIM_MIN_TURN.ticks;  // at least the minimum turn length
    f->turn_frames = (int16_t)left;
    if (f->turn_frames < 0) {  // move already past its length: no turn
        f->turn_frames = 0;
        return;
    }
    int16_t gap = (int16_t)(f->near_side_angle - f->facing);  // angle still to turn to the reference angle
    f->turn_speed = t5_clamp_s16(gap / f->turn_frames, steps(TURN_RATE_REAIM));  // scripted turn: gap over frames left, capped
}

void t5_facing_step(T5World *w, T5Fighter *f) {
    switch (f->facing_state.phase) {
    case FACING_FREE:  // free or scripted: this stage does nothing
    case FACING_SCRIPTED: return;
    case FACING_REAIM: reaim(w, f); return;  // after startup: plan a turn every few frames
    case FACING_RUNNING: break;
    }
    const T5FacingRow *row = t5_facing_row(w, f->facing_state);  // the row for this fighter's profile
    if (row->gate.min_distance != 0 && w->distance < (float)row->gate.min_distance) return;  // closer than row minimum: wait
    switch (row->law) {
    case LAW_HOLD: f->facing = f->move_yaw; break;  // hold: facing stays on the move yaw
    case LAW_HOME: home(w, f, t5_object(w, f->opponent), row); break;
    case LAW_SETTLE: settle(w, f, row); break;
    case LAW_SWEEP: sweep(w, f, row); break;
    case LAW_EASE_OUT: ease_out(w, f, row); break;
    case LAW_EASE_IN: ease_in(f, row); break;
    case LAW_LEAVE: leave(w, f, row); break;
    }
}

const T5FacingRow *t5_facing_row(const T5World *w, T5FacingState facing) {
    static constexpr T5FacingRow HOLD_ROW = {};
    const T5FighterData *fighter_data = NULL;
    if (facing.set < sizeof w->data / sizeof w->data[0]) fighter_data = w->data[facing.set];  // the character's data set, if any
    if (!fighter_data || facing.row >= fighter_data->moves.tracking_count) return &HOLD_ROW;  // no table or a row past it: hold
    return &fighter_data->moves.tracking[facing.row];
}

T5FacingState t5_facing_begin(const T5World *w, uint8_t set, uint8_t row) {
    T5FacingState facing = {row, FACING_RUNNING, set};  // start running at the row
    facing.phase = t5_facing_row(w, facing)->start;  // the row decides the first phase
    return facing;
}

static T5FacingState from_tracking(const T5World *w, const T5Fighter *f, uint8_t set, T5MoveTracking tracking) {
    bool far = false;
    if (tracking.far_source == FAR_BY_OPP_ANGLE) far = f->opponent_angle > tracking.far_angle;  // far: angle above the limit
    if (tracking.far_source == FAR_BY_ANGLE_84) far = f->angle_84 > tracking.far_angle;  // far by the other angle field
    if (far) return t5_facing_begin(w, set, tracking.far_row);  // far: start the far row
    return t5_facing_begin(w, set, tracking.row);  // else the normal row
}

T5FacingState t5_facing_for_move(const T5World *w, const T5Fighter *f, T5Ref move) {
    switch (f->track_pick.kind) {
    case PICK_DATA: return from_tracking(w, f, f->track_pick.set, f->track_pick.tracking);  // a cancel picked its own tracking
    case PICK_MOVE: break;  // nothing picked: use the move's own
    }
    return from_tracking(w, f, move.set, t5_move_at(w, move)->tracking);
}

T5TrackingPick t5_pick_of_cancel(const T5World *w, uint8_t owner_set, const T5Cancel *cancel, uint16_t raw, uint16_t filtered) {
    const T5Motbin *owner = t5_set(w, owner_set);
    uint8_t code = t5_transition_code(raw);  // owner of the cancel list
    bool rewritten = t5_transition_class(raw) == TRANSITION_CARRY  // a carry cancel
                     && (code < MOTION_HOMING_FIRST || code > MOTION_HOMING_LAST)
                     && t5_transition_code(filtered) == MOTION_HOMING_FIRST;  // that the filter rewrote to the soft homing code
    if (rewritten && owner->fixed_tracking_count > TRACKING_FIXED_CARRY)  // use the fixed carry tracking of the character
        return (T5TrackingPick){PICK_DATA, owner_set, owner->fixed_tracking[TRACKING_FIXED_CARRY]};
    if (cancel->tracking_pick != 0 && cancel->tracking_pick <= owner->tracking_override_count)  // override named: use it
        return (T5TrackingPick){PICK_DATA, owner_set, owner->tracking_overrides[cancel->tracking_pick - 1]};
    return (T5TrackingPick){};  // no pick: the move's own tracking
}

T5TrackingPick t5_pick_guard(const T5World *w, uint8_t owner_set) {
    const T5Motbin *owner = t5_set(w, owner_set);
    return (T5TrackingPick){PICK_DATA, owner_set, owner->fixed_tracking[TRACKING_FIXED_GUARD]};  // guard: fixed guard tracking
}

// --- move start

static constexpr T5StartRow START_ROWS[START_ALIGNMENT_COUNT] = {
    [START_KEEP] = {.turns_with_anim = true},
    [START_KEEP_ROOT] = {},
    [START_YAW_TO_FACING] = {.target = TARGET_FACING, .turns_with_anim = true},
    [START_YAW_TO_FACING_ROOT] = {.target = TARGET_FACING},
    [START_TO_OPPONENT] = {.target = TARGET_OPPONENT, .turns_with_anim = true, .sets_facing = true},
    [START_YAW_TO_OPPONENT] = {.target = TARGET_OPPONENT, .turns_with_anim = true},
    [START_YAW_TO_OPPONENT_OR_REFERENCE] = {.target = TARGET_OPPONENT_OR_REFERENCE, .turns_with_anim = true},
    [START_TO_REFERENCE] = {.target = TARGET_REFERENCE, .turns_with_anim = true, .sets_facing = true},
    [START_YAW_TO_REFERENCE] = {.target = TARGET_REFERENCE, .turns_with_anim = true},
    [START_TO_LOOK] = {.target = TARGET_LOOK, .turns_with_anim = true, .sets_facing = true},
    [START_YAW_TO_LOOK] = {.target = TARGET_LOOK, .turns_with_anim = true},
    [START_THROW_PARTNER] = {},
    [START_TO_WALL] = {.target = TARGET_WALL, .turns_with_anim = true, .sets_facing = true},
    [START_HALF_TURN] = {},
    [START_YAW_TO_REFERENCE_LESS_REACTION] = {.target = TARGET_REFERENCE_LESS_REACTION, .turns_with_anim = true},
    [START_UNUSED_15] = {.turns_with_anim = true},
};

const T5StartRow *t5_start_row(T5StartAlignment align) { return &START_ROWS[align]; }

void t5_facing_start(T5Fighter *f, const T5StartRow *row, bool reaction_yaw) {
    T5Target kind = row->target;
    if (kind == TARGET_NONE) return;  // row has no target: leave facing alone
    if (kind == TARGET_REFERENCE_LESS_REACTION && !reaction_yaw) kind = TARGET_REFERENCE;  // no reaction yaw: plain reference
    int16_t angle = target_angle(f, kind);  // angle to the target
    f->move_yaw = angle;  // the move yaw always takes it
    if (row->sets_facing) f->facing = angle;  // and the facing too when the row says so
}
