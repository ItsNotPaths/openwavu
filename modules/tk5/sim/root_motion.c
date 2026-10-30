// Steps 0..9 and 12 of the movement step: where the fighter goes this frame (gravity, approach slide, launch, pushes, turns,
// pushback) and the pivot of the anchor.
#include <math.h>

#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/motion.h"
#include "sim/move.h"
#include "sim/units.h"

enum { APPROACH_IDLE, APPROACH_READY, APPROACH_RUNNING };

// A fall adds gravity to the vertical speed; the floor ends it and gives gravity back. NaN stays in the air.
static void gravity(T5Fighter *f) {
    float y = f->position.y;
    bool falling = y > 0 && !f->no_gravity;  // only fall when above the floor and gravity is not off
    if (falling) {  // in the air: gravity pulls the speed down, the speed moves them
        f->velocity.y = f->velocity.y - GRAVITY;
        f->position.y = f->velocity.y + y;
    }
    bool on_floor = y <= 0;  // on the floor already
    if (falling) on_floor = f->position.y <= 0;  // a fall that reaches the floor lands them
    if (!on_floor) return;
    f->position.y = 0;  // landed: snap to the floor, stop falling, gravity back on
    f->velocity.y = 0;
    f->no_gravity = 0;
}

// The move starts its window: the slide covers the way to the opponent, less a gap, in the frames of the window.
static void start_approach(const T5World *w, T5Fighter *f, const T5Move *anim_move) {
    if (anim_move->window_start > f->frame) return;  // too early: wait until the move's window starts
    int32_t frames = (int32_t)anim_move->window_end - f->frame;  // frames left in the window
    if (frames == 0) frames = 1;
    f->approach_state = APPROACH_RUNNING;  // slide is now running
    int32_t travel = APPROACH_FAR_TRAVEL;  // far from the opponent: fixed travel
    if (!(w->distance > APPROACH_FAR_DISTANCE)) travel = t5_fctiwz(w->distance) - APPROACH_STOP_GAP;  // close: reach opponent
    float step = (float)t5_divw(travel, frames);  // spread the travel evenly over the window frames
    float angle = t5_angle_to_rad(f->target_angle);  // slide points at the opponent
    f->approach_x = t5_fctiwz(t5_sin(angle) * step);
    f->approach_z = t5_fctiwz(t5_cos(angle) * step);
    f->root_mode = T5_ROOT_HEIGHT_ONLY;  // slide moves the floor position only, height is left to the animation
}

static void run_approach(T5Fighter *f, const T5Move *anim_move) {  // each frame, move by the slide step
    f->position.x = f->position.x + (float)f->approach_x;
    f->position.z = f->position.z + (float)f->approach_z;
    if (f->frame < anim_move->window_end) return;  // window still running: keep sliding
    f->position.x = f->base_position.x;  // window over: back to the base position
    f->position.z = f->base_position.z;
    f->approach_state = APPROACH_IDLE;
    f->approach_x = 0;
    f->approach_z = 0;
}

static void approach_opponent(const T5World *w, T5Fighter *f) {
    const T5Move *anim_move = t5_move_at(w, f->anim_move);
    if (f->approach_state == APPROACH_READY) start_approach(w, f, anim_move);  // ready: wait for the window; running: slide
    else if (f->approach_state == APPROACH_RUNNING) run_approach(f, anim_move);
}

// The landing of a launch: the fighter stands on the floor and, if the move holds a frame, jumps its clock there.
static void land(const T5World *w, T5Fighter *f, float x, float z) {
    f->position.x = x;
    f->position.z = z;
    f->touchdown = 1;  // touched down this frame
    f->root_mode = T5_ROOT_HEIGHT_ONLY;
    f->hold_count = T5_HOLD_NONE;  // no hold frame set
    f->position.y = 0;
    f->velocity.z = 0;
    f->velocity.y = 0;
    f->velocity.x = 0;
    f->launch_flag = 0;  // flight is over
    uint16_t hold = t5_move_at(w, f->move)->hold_frame;
    if (hold == 0) return;  // the move has no hold frame: keep the current frame
    f->frame = (int16_t)hold;  // jump the move to its hold frame
    f->clock = f->frame * CLOCK_PER_FRAME;
    f->frame_changed = (uint16_t)f->previous_frame != (uint16_t)f->frame;
    f->anim_time = (float)f->frame;
    f->anim_time_at_clock = f->anim_time;
}

// A launch flies by its speed until it is falling and at the landing height.
static void launch(const T5World *w, T5Fighter *f) {
    if (!(f->launch_flag != 0.0f)) return;  // NaN counts as set
    float x = f->base_position.x + f->velocity.x;  // fighter and base position both move by the launch speed
    float z = f->base_position.z + f->velocity.z;
    f->position.x = f->position.x + f->velocity.x;
    f->position.z = f->position.z + f->velocity.z;
    f->base_position.x = x;
    f->base_position.z = z;
    if (f->velocity.y <= 0 && f->position.y <= f->landing_y) land(w, f, x, z);  // falling and at landing height: land
}

// The move pushes forward by its speed while its window runs (one frame early).
static void forward_push(const T5World *w, T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    if (move->push_speed == 0 || move->window_start == 0) return;  // moves without a push speed or window do nothing
    if (!t5_frame_between(f->frame, (int32_t)move->window_start - 1, move->window_end)) return;  // outside the window: no push
    float speed = (float)move->push_speed;  // push speed in 1/256 mm
    float angle = t5_angle_to_rad(f->move_yaw);
    float step_x = t5_sin(angle) * speed;
    float step_z = t5_cos(angle) * speed;
    f->position.x = fmaf(step_x, -PUSH_SPEED_UNIT, f->position.x);  // push along the move's yaw
    f->position.z = fmaf(step_z, -PUSH_SPEED_UNIT, f->position.z);
}

// A drift moves the fighter and its base position steadily (`PROP_DRIFT_SPEED`).
static void drift(T5Fighter *f) {
    if (f->drift_speed == 0.0f) return;  // no drift: nothing to do
    float speed = f->drift_speed * PUSH_SPEED_UNIT;
    int16_t heading = f->drift_angle;
    if (!f->drift_absolute) heading = (int16_t)(f->move_yaw + f->drift_angle);  // relative to move yaw unless absolute
    float angle = t5_angle_to_rad(heading);
    t5_shift_root(f, -(t5_sin(angle) * speed), -(t5_cos(angle) * speed));  // drift moves the base position too
}

// An offset push moves by a fixed step for a number of frames (property 200, the throw snap).
static void offset_push(T5Fighter *f) {
    if ((uint16_t)f->slide_frames == 0) return;  // no slide frames left: nothing to do
    f->slide_frames = (int16_t)(f->slide_frames - 1);  // one slide frame used up
    t5_shift_root(f, f->slide_step[0], f->slide_step[1]);  // move by the fixed step
}


static void turn(T5Fighter *f) {
    if (f->turn_frames == 0) return;  // no turn left: nothing to do
    f->turn_frames--;  // one turn frame used up; the facing turns by the turn speed
    f->facing = (int16_t)(f->facing + f->turn_speed);
}

static void spin(T5Fighter *f) {
    if (f->spin_frames == 0) return;  // no spin left: nothing to do
    f->facing = (int16_t)(f->facing + f->spin_speed);  // the facing turns and the move direction follows
    f->move_yaw = f->facing;
    f->spin_frames = (int16_t)(f->spin_frames - 1);
    f->body_yaw = t5_wrap_pi(t5_angle65535_to_rad(f->spin_speed) + f->body_yaw);  // the body yaw turns by the same amount
}

// A curve entry is read where the cursor points; the script moves the cursor one entry on.
static int16_t curve_entry(const T5World *w, T5Ref cursor) {
    if (cursor.set == T5_SET_DEFAULT_PUSHBACK) return (int16_t)(t5_default_pushback + 6)[cursor.index];  // shared default curves
    return (int16_t)t5_set(w, cursor.set)->pushback_curves[cursor.index];
}

T5ScriptStep t5_script_step(const T5World *w, T5Script script, float distance, float curve_bonus) {
    float step = 0.0f;
    if (script.frames > 0) {  // flat distance runs for its frames
        step = distance + 0.0f;
        script.frames--;
    }
    if (script.curve_frames > 0) {  // the curve runs for its frames, one entry each
        script.curve_frames--;
        step = step + (float)curve_entry(w, script.curve);
        script.curve.index++;  // cursor steps on one entry
        if (curve_bonus != 0.0f) step = step + curve_bonus;  // a repeated hit adds its bonus on each curve step
    }
    return (T5ScriptStep){script, step};
}

// A hit that repeats within the streak window pushes further back.
static float streak_bonus(const T5Fighter *f) {
    int32_t repeats = (int16_t)f->repeat_count;
    if (repeats <= PUSHBACK_STREAK_FREE) return 0.0f;  // a short streak adds nothing
    return (float)((repeats - PUSHBACK_STREAK_FREE) * PUSHBACK_STREAK_STEP + PUSHBACK_STREAK_BASE);  // repeats add more
}

static void pushback(const T5World *w, T5Fighter *f) {
    T5Script script = {f->pushback_curve, f->pushback_frames, f->pushback_curve_frames};  // pushback state: cursor, frames left
    T5ScriptStep run = t5_script_step(w, script, f->pushback_distance, streak_bonus(f));  // run one frame of the pushback
    f->pushback_curve = run.next.curve;  // save the script state for next frame
    f->pushback_frames = run.next.frames;
    f->pushback_curve_frames = run.next.curve_frames;
    if (run.step == 0.0f) return;  // no pushback this frame
    float angle = t5_angle_to_rad(f->pushback_angle);  // push along the pushback angle
    t5_shift_root(f, run.step * t5_sin(angle), run.step * t5_cos(angle));
}

void t5_move_motion(T5World *w, T5Fighter *f) {
    const T5Fighter *opponent = t5_object(w, f->opponent);
    f->throw_immune = 0;  // clear the one-frame flags
    f->move_end = 0;
    f->touchdown = 0;
    f->old_facing = (uint16_t)f->facing;  // remember the facing from before the turns of this step
    t5_face_angles(w, f, opponent);  // work out angles to the opponent

    if (f->kind == T5_KIND_FIGHTER) gravity(f);  // only real fighters fall; extras do not
    approach_opponent(w, f);  // slide towards the opponent for approach moves
    launch(w, f);  // fly on if launched
    forward_push(w, f);  // push forward during the move's window
    drift(f);  // steady drift from the move
    offset_push(f);  // throw snap slide
    turn(f);  // slow turn around
    spin(f);  // fast spin around
    pushback(w, f);  // pushback from being hit or blocked
}

static bool pivots(const T5Fighter *f) { return f->pivot_bone >= 0 && f->pivot_bone < T5_BONES_A && !f->anim_changed; }

// Turn around a bone of last frame's pose, not the anchor. The game's matrix stack ends up holding the turn; here it
// is local. Bones the fighter has no joint for are skipped (the game reads past its bone table; no data sets one).
static void pivot_around_bone(T5Fighter *f) {
    float turn_angle = t5_angle65535_to_rad((int16_t)((int16_t)f->old_facing - f->facing));  // how far they turned this step
    const float *joint = f->joints[f->pivot_bone].v;  // last frame's position of the pivot bone
    T5Vec4 from = {{joint[0] - f->base_position.x, 0.0f, joint[2] - f->base_position.z, 1.0f}};  // offset from anchor, floor only
    T5Vec4 to;
    T5Mat4 rotation;
    t5_mat_identity(&rotation);
    t5_mat_rotate_y(&rotation, t5_rad_to_angle_round(turn_angle));  // rotate the offset by the turn
    t5_vec_times_mat(&to, &from, &rotation);
    T5Vec4 shift = vec4_subtract(to, from);  // how far the bone moved because of the turn
    t5_shift_root(f, shift.x, shift.z);  // move the anchor back by that, so the bone stays in place
    f->previous_position.x = f->previous_position.x + shift.x;  // previous position follows so no fake speed shows
    f->previous_position.z = f->previous_position.z + shift.z;
}

void t5_move_pivot(T5Fighter *f) {
    if (pivots(f)) pivot_around_bone(f);  // turn around the bone, if there is one
    int16_t lock = (int16_t)(f->cancel_lock - 1);  // cancel lock counts down one a frame
    if (lock < 0) lock = 0;  // never below zero
    f->cancel_lock = (uint16_t)lock;
}
