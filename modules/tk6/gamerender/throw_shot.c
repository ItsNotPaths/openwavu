// Stock TK6 presenter (gamerender.wasm): a throw's camera shot (tk6decomp docs/data.md "Coded throw shot"). It waits,
// then takes a spot turned off the fight camera's bearing, keeps its height and its offset from a target that follows
// the fighters, and eases out once the throw lets go.
#include <math.h>

#include "gamerender/presenter.h"

enum {
    SET_UP_AGE = 17,       // sim frames after the draw
    EASE_IN_FRAMES = 45,
    EASE_OUT_FRAMES = 49,  // once the throw lets go; the shot is off a frame later
};

static const float APART = 600;            // mm on the floor: fighters this far apart, out of the throw, let go
static const float TARGET_KEEP = 0.1f;     // per frame, the target is (aim + keep * target) / (1 + keep)
static const float POINT_RAISE = 968;      // a fighter's point is at least this far above its floor
static const float PI = 3.14159265f;
static const float DEGREE = 3.14159265f / 180;

static T6Vec3 plus(T6Vec3 a, T6Vec3 b) { return (T6Vec3){a.x + b.x, a.y + b.y, a.z + b.z}; }
static T6Vec3 minus(T6Vec3 a, T6Vec3 b) { return (T6Vec3){a.x - b.x, a.y - b.y, a.z - b.z}; }
static T6Vec3 scaled(T6Vec3 a, float by) { return (T6Vec3){a.x * by, a.y * by, a.z * by}; }
static float length(T6Vec3 a) { return sqrtf(a.x * a.x + a.y * a.y + a.z * a.z); }

// 1 falling to 0 as part goes 0 to 1, the game's ease curve.
static float falling(float part) {
    part = fminf(part, 1);
    return 0.5f * (1 + cosf(PI * (3 * part - part * part) / 2));
}

// A fighter's point for the camera: the hips, raised to at least POINT_RAISE above its floor.
static T6Vec3 fighter_point(const T6ViewFighter *fighter) {
    const T6Mat4 *hips = &fighter->rig.bones_a[0].world;
    return (T6Vec3){hips->m[3][0], fmaxf(hips->m[3][1], fighter->position.y + POINT_RAISE), hips->m[3][2]};
}

// Between the fighters, the one nearer the eye weighing more (the TK5 shot's aim; TK6's FUN_0026e590 is not read).
static T6Vec3 aim(const T6ThrowShot *shot, const T6View *view) {
    T6Vec3 thrower = fighter_point(&view->fighters[shot->thrower]), victim = fighter_point(&view->fighters[1 - shot->thrower]);
    float to_thrower = length(minus(thrower, shot->eye)), to_victim = length(minus(victim, shot->eye));
    float share = to_thrower + to_victim > 0 ? to_thrower / (to_thrower + to_victim) : 0.5f;
    return plus(thrower, scaled(minus(victim, thrower), share));
}

static T6Vec3 to_mm(OwVec3 metres) { return (T6Vec3){metres.x / MM, metres.y / MM, metres.z / MM}; }

void t6_throw_shot_start(T6ThrowShot *shot, int thrower, T6ThrowShotPlan plan, uint16_t thrower_moves) {
    *shot = (T6ThrowShot){.thrower = thrower, .plan = plan, .thrower_moves = thrower_moves};
}

static void set_up(T6ThrowShot *shot, const T6View *view, OwCamera fight) {
    T6Vec3 eye = to_mm(fight.position), target = to_mm(fight.target), back = minus(eye, target);
    shot->distance = length(back) * shot->plan.distance_scale;
    shot->yaw = atan2f(back.z, back.x) + shot->plan.yaw * DEGREE;
    shot->pitch = shot->plan.pitch * DEGREE;
    T6Vec3 direction = {cosf(shot->yaw) * cosf(shot->pitch), sinf(shot->pitch), sinf(shot->yaw) * cosf(shot->pitch)};
    shot->eye = plus(target, scaled(direction, shot->distance));
    shot->target = aim(shot, view);
    const T6ViewFighter *thrower = &view->fighters[shot->thrower], *victim = &view->fighters[1 - shot->thrower];
    shot->line_point = shot->target;
    shot->line_direction = minus(victim->position, thrower->position);
}

static bool lets_go(const T6ThrowShot *shot, const T6View *view, bool releases_ahead) {
    const T6ViewFighter *thrower = &view->fighters[shot->thrower];
    T6Vec3 apart = minus(fighter_point(thrower), fighter_point(&view->fighters[1 - shot->thrower]));
    bool thrown_off = thrower->throw_role != THROW_ROLE_THROWER && sqrtf(apart.x * apart.x + apart.z * apart.z) > APART;
    bool next_throw_move = thrower->throw_role == THROW_ROLE_THROWER && thrower->camera.throw_moves != shot->thrower_moves;
    return thrown_off || !releases_ahead || next_throw_move;
}

// One sim frame: the target follows the fighters; the eye keeps its height and offset until the throw lets go.
static void step(T6ThrowShot *shot, const T6View *view, bool releases_ahead) {
    shot->target = scaled(plus(aim(shot, view), scaled(shot->target, TARGET_KEEP)), 1 / (1 + TARGET_KEEP));
    if (shot->letting_go) {
        shot->letting_go++;
        return;
    }
    float across = shot->distance * cosf(shot->pitch);
    shot->eye.x = shot->target.x + across * cosf(shot->yaw);
    shot->eye.z = shot->target.z + across * sinf(shot->yaw);
    if (lets_go(shot, view, releases_ahead)) shot->letting_go = 1;
}

float t6_throw_shot(T6ThrowShot *shot, const T6View *view, OwCamera fight, bool releases_ahead, OwCamera *camera) {
    if (shot->thrower < 0) return 0;
    if (view->frame != shot->stepped_frame) {
        shot->stepped_frame = view->frame;
        shot->age++;
        if (shot->age < SET_UP_AGE && view->fighters[shot->thrower].throw_role != THROW_ROLE_THROWER) shot->thrower = -1;  // broke early
        else if (shot->age == SET_UP_AGE) set_up(shot, view, fight);
        else if (shot->age > SET_UP_AGE) step(shot, view, releases_ahead);
        if (shot->letting_go > EASE_OUT_FRAMES) shot->thrower = -1;
    }
    if (shot->thrower < 0 || shot->age < SET_UP_AGE) return 0;
    *camera = (OwCamera){
        .position = {shot->eye.x * MM, shot->eye.y * MM, shot->eye.z * MM},
        .target = {shot->target.x * MM, shot->target.y * MM, shot->target.z * MM},
        .fov = shot->plan.fov * DEGREE,
    };
    if (shot->letting_go) return falling((float)shot->letting_go / EASE_OUT_FRAMES);
    return shot->plan.cut_in ? 1 : 1 - falling((float)(shot->age - SET_UP_AGE) / EASE_IN_FRAMES);
}
