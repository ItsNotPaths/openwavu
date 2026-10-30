// The push that keeps fighters apart (code-map C.3): each fighter has eight spheres on its body; the move changes their
// radii. Overlapping spheres of two fighters push both along the line of their facing.
#include <math.h>

#include "sim/collision.h"
#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/pose.h"
#include "sim/units.h"

void t5_push_init(T5Fighter *f) {
    for (int point = 0; point < T5_PUSH_POINTS; point++)  // loop through the push spheres
        f->hit.push_point[point] = vec4_of(f->base_position, f->hit.push_point[point].w);
    f->push_counter = 0;  // no throw softening running
}

void t5_previous_root(T5Fighter *f) {
    f->previous_root = f->base_position;
}

// --- the radii of the spheres

// The push shape of a move (T5Move.push_shape): a kind that scales and shifts the radii of the body, a set of spheres that
// the kind 0 switches off (always, or only while the move swings), and the sphere set of the move itself.
typedef struct {
    uint8_t kind;
    uint8_t off_spheres;  // bit i: sphere i
    bool swing_only;
} PushShape;

enum { SHAPE_KIND_BY_MASK = 0, SHAPE_KIND_COUNT = 16, SHAPE_KIND_BITS = 4, SHAPE_OFF_SHIFT = 4, SHAPE_SWING_ONLY_BIT = 1 << 12 };
enum { SWING_LEAD_FRAMES = 8 };  // the switch-off starts this many frames before the first active frame

static PushShape shape_of(uint16_t word) {
    return (PushShape){(uint8_t)(word % (1 << SHAPE_KIND_BITS)),  // kind, spheres to switch off, swing-only flag
                       (uint8_t)(word >> SHAPE_OFF_SHIFT), (word & SHAPE_SWING_ONLY_BIT) != 0};
}

// radius = body radius * scale + add
typedef struct { float scale, add; } RadiusRule;

static constexpr RadiusRule SAME = {1.0f, 0.0f};
static constexpr RadiusRule HALF = {0.5f, 0.0f};
static constexpr RadiusRule POINT = {0.0f, 1.0f};  // a point of 1 mm
static constexpr RadiusRule OFF = {0.0f, 0.0f};
static constexpr RadiusRule WIDER_60 = {1.0f, 60.0f};
static constexpr RadiusRule WIDER_100 = {1.0f, 100.0f};

// Per shape kind and sphere. Kinds 10 and 12..15 change nothing.
static const RadiusRule SHAPES[SHAPE_KIND_COUNT][T5_PUSH_POINTS] = {
    [0] = {SAME, SAME, SAME, SAME, SAME, SAME, SAME, SAME},
    [1] = {SAME, POINT, POINT, SAME, POINT, POINT, POINT, POINT},
    [2] = {POINT, POINT, POINT, POINT, POINT, POINT, POINT, POINT},
    [3] = {HALF, HALF, HALF, HALF, HALF, HALF, HALF, HALF},
    [4] = {OFF, OFF, OFF, OFF, OFF, OFF, OFF, OFF},
    [5] = {HALF, POINT, POINT, HALF, POINT, POINT, POINT, POINT},
    [6] = {HALF, POINT, POINT, HALF, POINT, POINT, POINT, POINT},
    [7] = {WIDER_60, SAME, SAME, SAME, POINT, POINT, POINT, POINT},
    [8] = {WIDER_100, WIDER_100, WIDER_100, WIDER_100, WIDER_100, WIDER_100, WIDER_100, WIDER_100},
    [9] = {WIDER_60, OFF, OFF, OFF, OFF, OFF, OFF, OFF},
    [10] = {SAME, SAME, SAME, SAME, SAME, SAME, SAME, SAME},
    [11] = {HALF, SAME, SAME, SAME, SAME, SAME, SAME, SAME},
    [12] = {SAME, SAME, SAME, SAME, SAME, SAME, SAME, SAME},
    [13] = {SAME, SAME, SAME, SAME, SAME, SAME, SAME, SAME},
    [14] = {SAME, SAME, SAME, SAME, SAME, SAME, SAME, SAME},
    [15] = {SAME, SAME, SAME, SAME, SAME, SAME, SAME, SAME},
};

static bool in_set(uint8_t spheres, int sphere) { return (spheres >> sphere) & 1; }

// Kind 0 switches its spheres off always, or when the move swings: it has no hitbox, or the active frames are near.
static bool mask_applies(const T5Fighter *f, const T5Move *move, PushShape shape) {
    if (!shape.swing_only || move->first_active == 0) return true;
    return (int32_t)move->first_active - SWING_LEAD_FRAMES < f->frame && f->frame < move->last_active;
}

// The spheres the state of the move switches off: the arms of an attack, the feet when hit or rising, the legs when crouching.
static uint8_t spheres_off_by_state(const T5Fighter *f, const T5Move *move) {
    enum : uint8_t {  // sets of spheres to switch off
        ARMS = 1 << PUSH_ARM_1 | 1 << PUSH_ARM_2,
        FEET = 1 << PUSH_FOOT_1 | 1 << PUSH_FOOT_2,
        LEGS = FEET | 1 << PUSH_SHIN_1 | 1 << PUSH_SHIN_2
    };
    if (move->first_active != 0) return ARMS;
    if (f->hit_this_move) return FEET;
    if (f->in_air_window && f->base_delta.y >= 0.0f) return FEET;
    if (move->flags & T5_MOVE_NO_LEG_PUSH) return LEGS;
    return 0;
}

void t5_push_radii(const T5World *w, T5Fighter *f) {
    if (f->kind != T5_KIND_FIGHTER) return;  // only fighters have push spheres
    const T5Move *move = t5_move_at(w, f->move);
    PushShape shape = shape_of(move->push_shape);  // the move picks a radius rule per sphere
    bool mask_off = shape.kind == SHAPE_KIND_BY_MASK && mask_applies(f, move, shape);  // switch-off by mask?
    uint8_t state_off = spheres_off_by_state(f, move);  // spheres the fighter state switches off
    for (int sphere = 0; sphere < T5_PUSH_POINTS; sphere++) {  // loop through the spheres
        RadiusRule rule = SHAPES[shape.kind][sphere];
        float radius = f->body.push[sphere].radius * rule.scale + rule.add;  // scale the body radius by the rule
        if (mask_off && in_set(shape.off_spheres, sphere)) radius = 0.0f;  // the move switches this sphere off
        if (in_set(state_off, sphere)) radius = 0.0f;  // the state switches this sphere off
        f->hit.push_point[sphere].w = radius;  // store the radius in the sphere
    }
}

static void previous_root_of(T5World *w, T5Fighter *f) {
    (void)w;  // unused
    t5_previous_root(f);
}

static void push_radii_of(T5World *w, T5Fighter *f) { t5_push_radii(w, f); }

void t5_previous_root_pass(T5World *w) { t5_each_object(w, previous_root_of); }

void t5_push_radii_pass(T5World *w) { t5_each_object(w, push_radii_of); }

// --- the push of a pair

// Deepest overlap of the push spheres.
static float push_depth(const T5Fighter *first, const T5Fighter *second) {
    float depth = 0.0f;  // deepest overlap so far
    for (int first_index = 0; first_index < T5_PUSH_POINTS; first_index++) {  // loop through the spheres of the first fighter
        const float *first_point = first->hit.push_point[first_index].v;
        if (first_point[3] == 0.0f) continue;  // radius 0: sphere is off
        for (int second_index = 0; second_index < T5_PUSH_POINTS; second_index++) {  // loop through second's spheres
            const float *second_point = second->hit.push_point[second_index].v;
            if (second_point[3] == 0.0f) continue;  // radius 0: sphere is off
            float radius_sum = first_point[3] + second_point[3];  // the spheres touch when the gap is under this
            float gap_x = second_point[0] - first_point[0];
            float gap_y = second_point[1] - first_point[1];
            float gap_z = second_point[2] - first_point[2];
            if (!(radius_sum > fabsf(gap_x) && radius_sum > fabsf(gap_y) && radius_sum > fabsf(gap_z))) continue;
            float distance_squared = fmaf(gap_z, gap_z, fmaf(gap_x, gap_x, gap_y * gap_y));
            float penetration = radius_sum - sqrtf(distance_squared);  // how far the two spheres sink into each other
            if (depth <= penetration) depth = penetration;  // keep the deepest overlap
        }
    }
    return depth;
}

// Facing lines cross: both moves have a hitbox and the fighters face past each other.
static bool facing_lines_cross(const T5World *w, const T5Fighter *first, const T5Fighter *second, float depth) {
    if (t5_move_at(w, first->move)->first_active == 0 || t5_move_at(w, second->move)->first_active == 0) return false;
    if (!(depth > 0.0f || fabsf(first->base_position.y - second->base_position.y) < PUSH_CROSS_HEIGHT)) return false;
    float to_x = second->position.x - first->position.x;  // line from the first fighter to the second
    float to_z = second->position.z - first->position.z;
    T5PushAngle facing_first = t5_push_angle_of_yaw(first->move_yaw);
    T5PushAngle facing_second = t5_push_angle_of_yaw(second->move_yaw);
    float front_first_x = fmaf(t5_push_cos(facing_first), PUSH_CROSS_REACH, first->base_position.x);
    float front_first_z = fmaf(t5_push_sin(facing_first), PUSH_CROSS_REACH, first->base_position.z);
    float front_second_x = fmaf(t5_push_cos(facing_second), PUSH_CROSS_REACH, second->base_position.x);
    float front_second_z = fmaf(t5_push_sin(facing_second), PUSH_CROSS_REACH, second->base_position.z);
    float between_x = front_second_x - front_first_x;  // line between the two front points
    float between_z = front_second_z - front_first_z;
    if (!(fabsf(between_x) < PUSH_CROSS_RANGE && fabsf(between_z) < PUSH_CROSS_RANGE)) return false;
    float part = to_z * between_z;
    return fmaf(to_x, between_x, part) < 0.0f;  // the front points lie on opposite sides: the fighters face past each other
}

static T5Push push_toward(const T5Fighter *f, float x, float z, float share) {
    return (T5Push){share * (x - f->base_position.x), share * (z - f->base_position.z)};
}

static float moved_since_last_frame(const T5Fighter *f) {
    T5Vec3 moved = vec3_subtract(f->base_position, f->previous_root);  // travel since last frame, in 3D
    return t5_length3(moved.x, moved.y, moved.z);
}

// Each fighter is pushed away from the other by the other's step since last frame, and backs off by their own share of
// the overlap (the one that walked more backs off more). Each takes half of that move; during throw softening the shares
// follow how far each walked instead.
T5PairPush t5_push_pair(const T5World *w, const T5Fighter *first, const T5Fighter *second) {
    T5PairPush none = {};
    float depth = push_depth(first, second);  // deepest sphere overlap
    bool crossed = facing_lines_cross(w, first, second, depth);  // facing lines cross: the fighters went through each other
    if (crossed && depth < PUSH_CROSS_DEPTH) depth = PUSH_CROSS_DEPTH;  // crossed fighters get at least this much depth
    if (!(depth > 0.0f)) return none;  // no overlap: no push

    float moved_first = moved_since_last_frame(first);  // how far each fighter walked since last frame
    float moved_second = moved_since_last_frame(second);

    int32_t heading = t5_fctiwz(t5_atan2(second->base_position.x - first->base_position.x,  // angle from first to second
                                         second->base_position.z - first->base_position.z) * T5_RAD_TO_ANGLE);
    T5PushAngle axis = t5_push_angle_of_heading(heading);  // direction from the first fighter to the second
    T5PushAngle facing_first = t5_push_angle_of_yaw(first->move_yaw);
    T5PushAngle facing_second = t5_push_angle_of_yaw(second->move_yaw);
    if (t5_push_angle_between(facing_first, axis) > PUSH_QUARTER_TURN.steps)  // they face away from the other: turn them around
        facing_first = t5_push_angle_add(facing_first, PUSH_HALF_TURN);
    if (t5_push_angle_between(facing_second, t5_push_angle_add(axis, PUSH_HALF_TURN)) > PUSH_QUARTER_TURN.steps)
        facing_second = t5_push_angle_add(facing_second, PUSH_HALF_TURN);
    float sine_first = t5_push_sin(facing_first);  // facing direction of each fighter, as sine and cosine
    float cosine_first = t5_push_cos(facing_first);
    float sine_second = t5_push_sin(facing_second);
    float cosine_second = t5_push_cos(facing_second);

    float first_x = fmaf(cosine_second, moved_second, first->base_position.x);
    float first_z = fmaf(sine_second, moved_second, first->base_position.z);
    float second_x = fmaf(cosine_first, moved_first, second->base_position.x);
    float second_z = fmaf(sine_first, moved_first, second->base_position.z);
    if (moved_first == 0.0f && moved_second == 0.0f) {  // both stood still: count both as a tiny equal move
        moved_first = PUSH_STANDSTILL_TRAVEL;
        moved_second = PUSH_STANDSTILL_TRAVEL;
    }
    float total = moved_first + moved_second;  // summed travel splits the depth
    if (total == 0.0f) total = 1.0f;
    float depth_second = (moved_second * depth) / total;  // each backs away by their own travel share
    float depth_first = (moved_first * depth) / total;
    first_x = first_x - cosine_first * depth_first;  // first backs away along their facing
    first_z = first_z - sine_first * depth_first;
    second_x = second_x - cosine_second * depth_second;  // second backs away along their facing
    second_z = second_z - sine_second * depth_second;

    if (crossed)  // they went through each other: both get the full push, and no softening is kept
        return (T5PairPush){push_toward(first, first_x, first_z, 1.0f), push_toward(second, second_x, second_z, 1.0f), false, 0};

    int32_t softening = first->push_counter;  // throw softening frames left, the larger of the two fighters
    if (second->push_counter > softening) softening = second->push_counter;
    if (t5_throw_pair(w, first, second)) softening = PUSH_SOFTEN_FRAMES;  // in a throw: softening starts at its full length
    float share_first = PUSH_EVEN_SHARE, share_second = PUSH_EVEN_SHARE;  // normal: each fighter takes half of the move
    if (softening != 0) {  // softening: shares follow how far each walked, plus a flat bonus
        float soften = total * PUSH_SOFTEN_SHARE;  // flat bonus: a fifth of the summed travel, to both
        share_first = (moved_first + soften) / total;  // the one that walked more takes the larger share
        share_second = (moved_second + soften) / total;
    }
    float weight_first = (float)first->push_weight / (float)PUSH_WEIGHT_FULL;  // weight 1.0 is normal; less is harder to push
    float weight_second = (float)second->push_weight / (float)PUSH_WEIGHT_FULL;
    bool full_first = first->push_weight == PUSH_WEIGHT_FULL;  // full weight fighters are not scaled
    bool full_second = second->push_weight == PUSH_WEIGHT_FULL;
    if (full_first && !full_second) {  // only the first is full: both shares use the second's lighter weight
        share_first *= weight_second;
        share_second *= weight_second;
    } else if (!full_first && full_second) {  // only the second is full: both shares use the first's lighter weight
        share_first *= weight_first;
        share_second *= weight_first;
    } else if (!full_first && !full_second) {  // neither is full: each share uses their own weight
        share_first *= weight_first;
        share_second *= weight_second;
    }
    int16_t counter = (int16_t)softening;  // keep the softening count
    if (softening > 0) counter = (int16_t)(softening - 1);  // count down one frame
    return (T5PairPush){push_toward(first, first_x, first_z, share_first),  // each is pushed by their own share
                        push_toward(second, second_x, second_z, share_second), true, counter};
}

static bool updates(const T5Fighter *f) { return f->skip_motion != 0 || f->update_divider != T5_UPDATE_INACTIVE; }

// Two fighters push each other if one of them can be pushed and both update.
static bool pair_pushes(const T5Fighter *first, const T5Fighter *second) {
    if (first->no_push && second->no_push) return false;  // both not pushable: no push
    return updates(first) && updates(second);  // both must be updating
}

// The push of a fighter is the sum of the pushes of its pairs. It is zero for a fighter that is in no pair that pushes.
typedef struct { float x, z; bool pushed_by_pair; } PushSum;

static PushSum add_push(PushSum sum, T5Push push) {
    if (!sum.pushed_by_pair) return (PushSum){push.x, push.z, true};  // first push of the frame starts the sum
    return (PushSum){sum.x + push.x, sum.z + push.z, true};  // later pushes add up
}

// The game pushes the mob bodies first in modes 10 and 27; the sim has no mobs, so it does
// nothing. The diff harness stubs it. The pairs go in index order; a pair that ends up side by side sets the counter of both.
void t5_push_pass(T5World *w) {
    PushSum sums[T5_FIGHTER_COUNT] = {};  // push sum per fighter
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {  // loop through every pair of fighters
        for (int other_side = side + 1; other_side < T5_FIGHTER_COUNT; other_side++) {
            T5Fighter *first = w->fighters[side], *second = w->fighters[other_side];
            if (!pair_pushes(first, second)) continue;  // skip a pair that does not push
            T5PairPush pair = t5_push_pair(w, first, second);  // how far each of the two is pushed
            sums[side] = add_push(sums[side], pair.first);  // add to the first fighter's sum
            sums[other_side] = add_push(sums[other_side], pair.second);  // add to the second fighter's sum
            if (!pair.settled) continue;  // only a pair that ended up side by side sets the counter
            first->push_counter = pair.counter;  // both fighters share the new softening count
            second->push_counter = pair.counter;
        }
    }
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {  // loop through the fighters and apply the summed push
        T5Fighter *f = w->fighters[side];
        if (!sums[side].pushed_by_pair) continue;  // in no pushing pair: leave as is
        f->push.x = sums[side].x;  // push is only sideways, never up or down
        f->push.y = 0.0f;
        f->push.z = sums[side].z;
        if (f->push.x == 0.0f && f->push.z == 0.0f) continue;  // no push: nothing to move
        t5_shift_root(f, f->push.x, f->push.z);  // move the base position by the push
        t5_root_from_base(f);  // keep the root in line with the base position
        f->pushed = 1;  // mark the fighter as pushed this frame
    }
}

static void clear_push_flags(T5Fighter *f) {
    f->pushed = 0;  // push flag off
    f->no_push = 0;  // can-be-pushed flag back on
}

// A throw pair does not push. The extra clears come last and can wipe a link.
void t5_clear_push_pass(T5World *w) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) clear_push_flags(w->fighters[side]);  // clear flags for every fighter
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {  // loop through the fighters
        T5Fighter *f = w->fighters[side];
        if (!t5_in_throw(f->throw.chain)) continue;  // only fighters in a throw
        f->no_push = 1;  // a fighter in a throw is not pushed
        T5Fighter *partner = t5_throw_partner(w, f);  // find the throw partner
        if (partner) partner->no_push = 1;  // the partner is not pushed either
    }
    for (int32_t extra = 0; extra < t5_extra_count(w); extra++) clear_push_flags(t5_extra_entry(w, extra));
}
