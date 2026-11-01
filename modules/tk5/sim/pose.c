#include "sim/pose.h"

#include <math.h>
#include <string.h>

#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/math.h"
#include "sim/quat.h"

void t5_pose_frame(T5Fighter *f, const T5Anim *anim, bool keep_hips, T5Vec4 pose[T5_CHANNELS]) {
    t5_anim_sample(anim, f->anim_time - 1.0f, pose, keep_hips);
    t5_pose_scale_root(pose, f->scale_xz, f->scale_xz_add, f->scale_y);
    f->bone0 = vec3_of(pose[CHANNEL_ROOT]);
    f->bone1 = vec3_of(pose[CHANNEL_HIP]);
    f->root_offset = vec3_add(f->bone0, f->bone1);
    f->body_yaw = t5_wrap_full(t5_angle_to_rad(f->facing) + t5_quat_yaw(&pose[CHANNEL_ROOT_YAW]));
}

// --- body scale

// Visual only, not vanilla exact: stock lifts the rider only on Kuma/Panda by a fixed 1.15. This scales the ride by the
// partner's exported standing head height, which should look more correct for every partner if the export is right.
// The rider holds the lifted height, then eases back to its own scale over RIDE_EASE_FRAMES.
static float ride_scale(float own, float partner_head_top, float anim_time) {
    float lifted = own * partner_head_top / RIDE_REFERENCE_HEAD_TOP;
    float progress = (anim_time - (float)RIDE_EASE_START.ticks) / (float)RIDE_EASE_FRAMES.ticks;
    float weight = fminf(fmaxf(progress, 0.0f), 1.0f);
    return fmaf(1.0f - weight, lifted, weight * own);  // weight 0 gives the lifted height, weight 1 gives own
}

// scale_y eases from previous_scale_y to `to` while scale_blend counts down
static float eased_height(const T5Fighter *f, float to) {
    float weight = (float)f->scale_blend / (float)SCALE_EASE_STEPS;
    return fmaf(weight, f->previous_scale_y, to * (1.0f - weight));  // weight 1 holds previous_scale_y, 0 reaches `to`
}

// The pair's height: mostly the smaller of the two scales.
static float pair_height(float own, float partner) {
    if (own < partner) return fmaf(own, PAIR_HEIGHT_SMALLER, partner * PAIR_HEIGHT_LARGER);  // the smaller fighter weighs in most
    return fmaf(own, PAIR_HEIGHT_LARGER, partner * PAIR_HEIGHT_SMALLER);
}

static void hold_height(T5Fighter *f) {
    f->previous_scale_y = f->scale_y;  // the current height is where the next ease starts
    f->scale_blend = SCALE_EASE_STEPS;
}

// The pair of a throw plays its anims at the scale of the fighter who started it; the height mixes both, unless the move
// keeps the own height (eased back to) or rides the partner.
static void throw_scale(const T5World *w, T5Fighter *f) {  // scale of a fighter inside a throw
    const T5Fighter *partner = t5_throw_partner(w, f);  // the other fighter of the throw
    T5ThrowChain chain = f->throw.chain, before = f->throw.chain_before;
    float own = f->scale_base, theirs = partner->scale_base;  // each fighter's own base scale
    bool started_by_partner = !t5_throwing(before);  // not throwing before: the partner started it
    if (t5_throwing(chain)) started_by_partner = t5_thrown(before);  // throwing now: partner started it if we were thrown
    f->scale_xz = own;  // the width and depth play at the scale of whoever started the throw
    if (started_by_partner) f->scale_xz = theirs;
    if (t5_throwing(chain) && t5_move_at(w, f->move)->rides_partner)  // a throw that rides on the partner
        f->scale_y = ride_scale(own, partner->body.head_top, f->anim_time);  // lifted to the partner's head, then eases back
    else if (f->keeps_own_height != 0) f->scale_y = eased_height(f, own);  // this move keeps their own height
    else f->scale_y = pair_height(own, theirs);  // else the height mixes both scales
    if (f->keeps_own_height == 0) hold_height(f);  // remember this height as the start of the next ease
}

static void own_scale(T5Fighter *f) {
    f->scale_xz = f->scale_base;
    f->scale_y = eased_height(f, f->scale_base);  // height eases in to the base scale
}

// The scale of a fight pose: a throw mixes the pair's scales, a hit in an air move puts the fighter at scale 1, else its own.
void t5_fight_body_scale(const T5World *w, T5Fighter *f) {
    if (t5_in_throw(f->throw.chain)) {
        throw_scale(w, f);
    } else if (f->air_move != 0 && f->hit_this_move != 0) {
        f->scale_xz = 1.0f;
        f->scale_y = 1.0f;
        hold_height(f);
    } else {
        own_scale(f);
    }
}

// Out of a fight pose the fighter has its own scale (the height eases in).
void t5_body_scale(const T5World *w, T5Fighter *f) {
    if (t5_phase_row(w).fight_pose) t5_fight_body_scale(w, f);
    else own_scale(f);
}
