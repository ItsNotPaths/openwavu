// Root and relative angles, the root passes, and the juggle launch (code-map 7).
#include "sim/motion.h"

#include <math.h>
#include <string.h>

#include "sim/constants.h"
#include "sim/decide.h"
#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/pose.h"
#include "sim/tracking.h"
#include "sim/units.h"

// The game copies the matrix through the matrix stack; the port needs no stack.
// The translation row of the root matrix is the base position in the game.
void t5_root_matrix_pass(T5World *w) {
    for (int index = 0; index < T5_FIGHTER_COUNT; index++) {  // loop through both fighters
        T5Fighter *f = w->fighters[index];
        f->root_copy = f->rig.root.local;  // start from the local matrix of the root bone
        memcpy(f->root_copy.m[3], &f->base_position, sizeof f->base_position);  // put the base position in as the translation row
        f->root_copy.m[3][3] = f->base_position_w;  // and its w part
    }
}

static void root_delta(T5World *w, T5Fighter *f) {
    (void)w;
    f->base_delta = vec3_subtract(f->base_position, (T5Vec3){f->last_base[0], f->last_base[1], f->last_base[2]});
    f->base_delta_w = f->base_position_w - f->last_base[3];  // w part of the same
    memcpy(f->last_base, &f->base_position, sizeof f->base_position);  // remember this base position for the next pass
    f->last_base[3] = f->base_position_w;
    f->last_y = f->position.y;  // remember the height too
}

void t5_root_delta_pass(T5World *w) { t5_each_object(w, root_delta); }  // every fighter gets a root delta

// The wrap: once into [-pi, pi], then into [0, 2pi). NaN stays.
float t5_turn_positive(float angle) {
    if (angle > T5_PI) angle = angle - T5_TWO_PI;  // above half a turn: bring it down a turn
    else if (angle < -T5_PI) angle = angle + T5_TWO_PI;  // below minus half a turn: bring it up a turn
    if (angle < 0.0f) angle = angle + T5_TWO_PI;  // still negative: lift into 0 to a full turn
    return angle;
}

// The band's sectors run front, right, back, left with the angle.
static const int16_t SIDE_OF_SECTOR[SECTOR_COUNT] = {SECTOR_FRONT, SECTOR_RIGHT, SECTOR_BACK, SECTOR_LEFT};

static int16_t side_of(uint16_t angle, const T5SideBand *band) {
    uint16_t right_end = (uint16_t)(band->width_0 + band->width_1);  // where the right sector ends
    uint16_t back_end = (uint16_t)(right_end + band->width_2);  // where the back sector ends
    if (angle <= band->width_0) return SIDE_OF_SECTOR[0];  // in the front sector
    if (angle <= right_end) return SIDE_OF_SECTOR[1];  // in the right sector
    if (angle <= back_end) return SIDE_OF_SECTOR[2];  // in the back sector
    return SIDE_OF_SECTOR[3];  // anything past the back sector is left
}

// The game's abs: ones' complement for a negative angle.
static int16_t ones_abs(int16_t value) {
    if (value < 0) return (int16_t)~value;  // negative angle: flip the bits to get its size
    return value;
}

// The angle that turns the nearer side, the front or the back, toward the target.
static int16_t near_side(int16_t target_angle, int16_t off) {
    if ((uint16_t)off >= QUARTER_TURN.bits) return t5_angle_offset(target_angle, HALF_TURN);
    return target_angle;
}

// The bands of a side_band_table index above 7 are other header bytes of the game; not modeled.
void t5_relative_angles(const T5World *w, T5Fighter *f, const T5Fighter *opponent) {
    const T5SideBand *band = &t5_set(w, f->moveset)->side_bands[f->side_band_table & 7];
    int16_t face = t5_rad_to_angle65535(t5_turn_positive(f->look_yaw));  // the way they look, as a binary angle
    const T5Fighter *target = opponent;  // aim at the opponent
    if (!t5_input_cpu_driven(&f->input)) target = t5_object(w, f->target);
    float offset_x = (float)t5_fctiwz(target->base_position.x - f->base_position.x);  // distance to the target along x, whole mm
    float offset_z = (float)t5_fctiwz(target->base_position.z - f->base_position.z);  // distance to the target along z, whole mm
    int16_t angle = (int16_t)t5_fctiwz(t5_atan2(offset_x, offset_z) * T5_RAD_TO_ANGLE);  // angle from this fighter to the target
    f->target_angle = angle;
    f->side_angle = (int16_t)(face - angle);  // how far the look direction is off the target
    f->reference_side_angle = (int16_t)(f->reference_yaw - angle);  // same for the reference yaw
    f->side_band = side_of((uint16_t)(band->offset + f->side_angle), band);  // which side of them the target is on, by look
    f->hit_side = side_of((uint16_t)(band->offset + f->reference_side_angle), band);
    f->opponent_angle = ones_abs(f->side_angle);  // size of the look offset
    f->angle_84 = ones_abs(f->reference_side_angle);  // size of the reference offset
    if (f->distance > NEAR_SIDE_DISTANCE) {  // target far enough away: keep the near side angles
        f->near_side_angle = near_side(angle, f->opponent_angle);  // look: turn around if the back is nearer the target
        f->reference_near_side_angle = near_side(angle, f->angle_84);  // reference: the same
    }
}

void t5_face_angles(const T5World *w, T5Fighter *f, const T5Fighter *opponent) {
    f->reference_yaw = f->facing;  // by default the reference is where they face
    if (f->reaction_facing == REACTION_FACING_TURNED) f->reference_yaw = t5_angle_offset(f->facing, HALF_TURN);
    else if (f->reaction_facing == REACTION_FACING_LOOK) f->reference_yaw = t5_rad_to_angle65535(t5_turn_positive(f->look_yaw));
    t5_relative_angles(w, f, opponent);  // then work out the angles to the opponent
}

void t5_angles_pass(T5World *w) {
    t5_face_angles(w, w->fighters[0], w->fighters[1]);  // first fighter faces the second
    t5_face_angles(w, w->fighters[1], w->fighters[0]);  // second fighter faces the first
}

// --- juggle launch

static int32_t clamp_int(int32_t value, int32_t low, int32_t high) {
    if (value < low) return low;  // below the low end: use the low end
    if (value > high) return high;  // above the high end: use the high end
    return value;
}

// The flight of a launch: the speeds, and the frames until it lands at landing_y.
typedef struct {
    int32_t lift, frames;
} Flight;

// The vertical speed and the frames a launch flies to come down `drop` lower (falls GRAVITY a frame squared).
static Flight flight_of(const T5Fighter *defender, int32_t damage, int32_t juggle, int32_t drop) {
    int32_t gravity = (int32_t)GRAVITY;  // gravity pulls down a fixed amount each frame
    int32_t carry = t5_fctiwz(defender->base_delta.y) + t5_fctiwz(defender->hit.incoming_direction.y);
    int32_t lift = (carry >> LAUNCH_CARRY_SHIFT) + damage * LAUNCH_LIFT_PER_DAMAGE -  // damage lifts more, each juggle hit less
                   LAUNCH_LIFT_PER_JUGGLE * juggle + LAUNCH_LIFT_BASE;
    lift = clamp_int(lift, -LAUNCH_LIFT_MAX, LAUNCH_LIFT_MAX);  // keep the lift within the limit, up or down
    int32_t span = drop * 2 * gravity + lift * lift;  // drop under gravity plus the lift squared
    if (span < 0) span = -span;  // keep it positive for the square root
    int32_t frames = (t5_fctiwz(sqrtf((float)span)) + lift) / gravity;  // frames until it lands
    if (frames < 1) frames = 1;  // at least one frame
    return (Flight){lift, frames};
}

typedef struct {
    int32_t first;   // the frame the launch move starts at
    int32_t frames;  // frames of flight left to cover
} LaunchStart;

// Where in the launch move the flight starts, so that it lands at `end`. A forced start frame wins; a fighter not on the
// wall starts at frame 1; the first launch of a juggle flies longer; a relaunch into the same anim near the start rewinds.
static LaunchStart launch_start(const T5World *w, const T5Fighter *defender, int32_t juggle,  // where the launch move starts
                                int32_t end, int32_t frames, int32_t forced) {
    int32_t start = end - frames + 1;  // the frame that would land on the end frame
    if (start < 1) start = 1;  // never before the first frame
    if (forced != 0) return (LaunchStart){forced, frames + start - forced};  // a forced start frame wins
    if ((defender->state & STATE_HURT_4) == 0 && start != 1) return (LaunchStart){1, start + frames - 1};
    if (juggle == 0) {  // first launch of a juggle
        int32_t longer = frames + LAUNCH_FIRST_EXTRA.ticks;  // it flies longer
        int32_t first = end - longer + 1;  // start earlier to land on time
        if (first <= 0) first = 1;  // never before the first frame
        return (LaunchStart){first, longer};
    }
    bool same_anim = t5_anim_same(t5_anim_at(w, defender->move), t5_anim_at(w, defender->pending_move));
    if (same_anim && defender->frame >= start - RELAUNCH_WINDOW.ticks && defender->frame <= start + RELAUNCH_WINDOW.ticks) {
        int32_t back = defender->frame - RELAUNCH_REWIND.ticks;  // rewind to a few frames before the current frame
        if (back <= 0) back = 1;  // never before the first frame
        return (LaunchStart){back, frames + start - back};
    }
    return (LaunchStart){start, frames};
}

// The speed up that lands the flight in time: none lower than the drop needs, none longer than the move allows.
static float landing_lift(int32_t lift, int32_t frames, int32_t first, int32_t end, int32_t y_start, int32_t y_end) {
    int32_t half_gravity = (int32_t)GRAVITY / 2;  // half of gravity, for the fall distance
    int32_t drop = y_end - y_start;  // height from start to landing
    int32_t next = frames + 1;  // one more frame
    int32_t fall = half_gravity * next * next;  // how far gravity pulls them down over that time
    float out = (float)lift;
    if (lift * next - fall + y_start < y_end) out = (float)t5_divw(drop + fall, next);
    int32_t window = end - first + LAUNCH_LANDING_SLACK.ticks;  // the most time the move allows
    if (frames > window) out = (float)t5_divw(half_gravity * window * window + drop, window);
    return out;
}

// Launch the defender into a juggle: the velocity from the hit, the frame the pending move starts at, and the
// pushback. `reaction` is the reaction list of the last hit; it is read only when defender->air_reaction_list is set:
// then its counter yaw is a lift override and the pushback world template its forced start frame.
void t5_juggle_launch(const T5World *w, T5Fighter *defender, const T5Reaction *reaction) {
    bool from_list = defender->air_reaction_list != 0;  // the last hit gave a reaction list for this air hit
    int16_t lift_override = 0;  // no lift override by default
    int32_t forced = 0;  // no forced start frame by default
    if (from_list) {  // read the reaction list
        lift_override = (int16_t)reaction->yaw[REACTION_COUNTER];  // its counter yaw is the lift override
        forced = w->pushback_template[3];  // the pushback template gives the forced start frame
    }
    int32_t juggle = (int16_t)defender->juggle_count - 1;  // how many hits into the juggle, counting from zero
    int32_t damage = (int16_t)defender->damage_absolute;  // damage of the hit
    const T5Move *move = t5_move_at(w, defender->pending_move);  // the move they will be in after the launch
    int32_t end = move->length, sample_at = move->length;  // the move ends at its length
    if (move->hold_frame != 0) {  // a move with a hold frame ends there instead
        end = move->hold_frame;  // flight lands on the hold frame
        sample_at = move->hold_frame - 1;  // sample the frame before it
    }
    int32_t y_start = t5_fctiwz(defender->base_position.y);  // height they launch from
    t5_body_scale(w, defender);  // refresh the body scale
    T5Vec4 root[2];
    t5_anim_sample_root(&defender->keys, t5_anim_at(w, defender->pending_move), (float)sample_at, root);
    t5_pose_scale_root(root, defender->scale_xz, defender->scale_xz_add, defender->scale_y);  // scale it to this fighter's body
    defender->landing_y = root[0].y + root[1].y;  // height of the root at the landing frame
    int32_t y_end = t5_fctiwz(defender->landing_y);  // height they land at

    int16_t away_angle = t5_angle_offset(defender->target_angle, HALF_TURN);  // away from the target, half a turn around
    float away = t5_angle_to_rad(away_angle);
    float speed = (float)clamp_int(juggle * LAUNCH_AWAY_PER_JUGGLE + damage + LAUNCH_AWAY_BASE, 0, LAUNCH_AWAY_MAX);
    defender->velocity.x = (float)t5_fctiwz(t5_sin(away) * speed);  // push away along x
    defender->velocity.z = (float)t5_fctiwz(t5_cos(away) * speed);  // push away along z
    Flight flight = flight_of(defender, damage, juggle, y_end - y_start);  // work out the lift and the flight time
    defender->velocity.y = (float)flight.lift;  // launch up with that lift
    LaunchStart launch = launch_start(w, defender, juggle, end, flight.frames, forced);
    defender->pending_frame = (int16_t)launch.first;  // the pending move starts at that frame
    if (lift_override != 0) defender->velocity.y = (float)lift_override;  // a lift override from the reaction wins

    if (from_list) {  // the pushback comes from the reaction list
        T5Ref pushback_ref = reaction->pushback[REACTION_FRONT];  // the front pushback of the reaction
        const T5Pushback *pushback = t5_pushback_at(w, pushback_ref);
        defender->pushback = pushback_ref;  // remember it on the defender
        defender->pushback_curve = t5_ref(pushback_ref.set, pushback->curve);  // its curve
        defender->pushback_curve_frames = (int16_t)pushback->curve_frames;  // and how long the curve runs
        defender->pushback_angle = defender->pushback_angle_start =  // the pushback runs away from the hit
            t5_angle_offset((int16_t)(defender->target_angle - reaction->angle[REACTION_FRONT]), HALF_TURN);
        defender->pushback_frames = 0;  // no extra pushback unless it has a distance
        defender->pushback_distance = 0.0f;
        if (pushback->distance != 0) {  // the pushback has a distance
            defender->pushback_frames = (int16_t)pushback->frames;  // take its frames
            defender->pushback_distance = (float)pushback->distance;  // and its distance
        }
    } else {  // no reaction list: generic launch
        defender->pushback_curve = t5_ref(T5_SET_DEFAULT_PUSHBACK, 0);  // default pushback curve
        defender->pushback_frames = 0;  // no extra pushback
        defender->pushback_distance = 0.0f;
        defender->pushback_curve_frames = LAUNCH_CURVE_FRAMES;  // generic curve length
        defender->pushback_angle = defender->pushback_angle_start = away_angle;  // pushed straight away from the target
    }
    defender->hold_count = LAUNCH_HOLD_COUNT;  // hold the hold frame of the move for a long time
    if (lift_override == 0) defender->velocity.y = landing_lift(flight.lift, launch.frames, launch.first, end, y_start, y_end);
}
