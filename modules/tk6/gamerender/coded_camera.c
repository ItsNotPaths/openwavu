// Stock TK6 presenter (gamerender.wasm): the hand-coded throw shots, camera ids below 0x67. Not bit
// exact: the same shot within a few cm. A spot 3 m from the fighters at an angle from the line between them, picked once;
// then each frame it keeps its bearing, aims between the fighters and backs off to fit both. Its weight eases in (or cuts
// in) and eases out once the throw lets go.
#include <math.h>
#include <stdlib.h>

#include "gamerender/presenter.h"

enum {
    WAIT_FRAMES = 16,      // the camera on screen stays this long first; 1 with the hold flag
    EASE_IN_FRAMES = 45,
    EASE_OUT_FRAMES = 50,  // once the throw lets go
    TEST_ANGLES_FIRST = 30, TEST_ANGLES_SECOND = 66, TEST_ANGLES_END = 102,  // ids of a fixed angle in 10 degree steps
    WIDER_ID = 0x66,       // id 0x11 from further away
};

static const float SPOT_DISTANCE = 3000;    // mm from the fighters' middle
static const float POINT_RAISE = 968;       // a fighter's point is at least this far above its floor
static const float EYE_RAISE = 200;         // the eye stays this far above the floor
static const float FIT_MARGIN = 500;        // mm kept past each fighter
static const float FIT_ACROSS = 0.9259259f;  // distance per mm the fighters span across the view
static const float FIT_ACROSS_BASE = 1120;
static const float FIT_UP = 2.5f;           // distance per mm the fighters span up the view
static const float FIT_LEAST = 4200;        // a global the game reads, never written
static const float FIT_MOST = 80000;
static const float CLOSER_RATE = 0.35f, FURTHER_RATE = 0.7f;  // per frame, toward the new eye and target
static const float SAME_VIEW = 0.705f;      // a cut-in shot this close to the view on screen eases in instead
static const float PI = 3.14159265f;

// Per id mod 15: low nibble the eye height shape, high nibble the angle class.
static const uint8_t SHAPES[15] = {0x00, 0x01, 0x10, 0x20, 0x21, 0x02, 0x03, 0x12, 0x22, 0x23, 0x04, 0x05, 0x14, 0x24, 0x25};
// Eye height above the focus by shape: lowest, plus up to spread at random (mm). Shape 0 is flat on infinite stages.
static const struct { float lowest, spread; } HEIGHTS[6] = {{-200, 400}, {0, 0}, {-500, -1000}, {-200, -300}, {1000, 1800}, {200, 800}};

static float random_unit(void) { return (float)rand() / ((float)RAND_MAX + 1.0f); }

static T6Vec3 plus(T6Vec3 a, T6Vec3 b) { return (T6Vec3){a.x + b.x, a.y + b.y, a.z + b.z}; }
static T6Vec3 minus(T6Vec3 a, T6Vec3 b) { return (T6Vec3){a.x - b.x, a.y - b.y, a.z - b.z}; }
static T6Vec3 scaled(T6Vec3 a, float by) { return (T6Vec3){a.x * by, a.y * by, a.z * by}; }
static T6Vec3 toward(T6Vec3 from, T6Vec3 to, float rate) { return plus(from, scaled(minus(to, from), rate)); }
static float dot(T6Vec3 a, T6Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static float length(T6Vec3 a) { return sqrtf(dot(a, a)); }
static T6Vec3 unit(T6Vec3 a) { return length(a) > 0 ? scaled(a, 1 / length(a)) : a; }

// 0 to 1 along a half cosine.
static float eased(float part) { return 0.5f * (1 - cosf(PI * fminf(part, 1))); }

// A fighter's point for the camera: the hips, raised to at least POINT_RAISE above its floor.
static T6Vec3 fighter_point(const T6ViewFighter *fighter) {
    const T6Mat4 *hips = &fighter->rig.bones_a[0].world;
    return (T6Vec3){hips->m[3][0], fmaxf(hips->m[3][1], fighter->position.y + POINT_RAISE), hips->m[3][2]};
}

static float floor_under(const T6View *view) { return fminf(view->fighters[0].position.y, view->fighters[1].position.y); }

// How far back the eye sits to show both points, each pushed FIT_MARGIN away from the target on the floor.
static float fit_distance(T6Vec3 eye, T6Vec3 target, T6Vec3 first, T6Vec3 second) {
    T6Vec3 pushed[2] = {first, second};
    for (int at = 0; at < 2; at++) {
        T6Vec3 out = minus(pushed[at], target);
        out.y = 0;
        pushed[at] = plus(pushed[at], scaled(unit(out), FIT_MARGIN));
    }
    T6Vec3 forward = unit(minus(target, eye));
    T6Vec3 right = unit((T6Vec3){-forward.z, 0, forward.x});
    T6Vec3 up = {right.y * forward.z - right.z * forward.y, right.z * forward.x - right.x * forward.z, right.x * forward.y - right.y * forward.x};
    T6Vec3 span = minus(pushed[0], pushed[1]);
    float distance = fmaxf(fabsf(dot(span, up)) * FIT_UP, fabsf(dot(span, right)) * FIT_ACROSS + FIT_ACROSS_BASE);
    return fminf(fmaxf(distance, FIT_LEAST), FIT_MOST);
}

// The angle off the line from thrower to victim, in degrees, and the eye height shape. `right`: the thrower is
// on the right of the screen, which mirrors the angle.
static float spot_angle(int id, bool right, bool wide, int *shape, bool *cut_in) {
    if (id >= TEST_ANGLES_FIRST && id < TEST_ANGLES_END) {
        *cut_in = true;
        bool second = id >= TEST_ANGLES_SECOND;
        *shape = second ? 2 : 1;
        return (float)(10 * (id - (second ? TEST_ANGLES_SECOND : TEST_ANGLES_FIRST))) + (right ? 180 : 0);
    }
    int table_id = id == WIDER_ID ? 0x11 : id;
    *shape = SHAPES[table_id % 15] & 0xf;
    *cut_in = table_id >= 15;
    float turn = wide ? 20 + 10 * random_unit() : 28 + 42 * random_unit();
    bool even = ((int)turn & 1) == 0;  // the game's random sign for class 1
    switch (SHAPES[table_id % 15] >> 4) {
    case 0: return right ? 90 + turn : 90 - turn;  // behind the victim
    case 1: return right ? (even ? 180 - turn : 180 + turn) : (even ? -turn : turn);
    default: return right ? 270 - turn : 270 + turn;  // behind the thrower
    }
}

void t6_coded_shot_start(T6CodedShot *shot, T6CodedThrow throw_move, int id, bool thrower_right, bool wide, bool hold,
                         bool walled_stage, uint32_t frame) {
    *shot = (T6CodedShot){
        .throw_move = throw_move, .id = id, .thrower_right = thrower_right, .wide = wide, .walled_stage = walled_stage,
        .set_up_frame = frame + (hold ? 1 : WAIT_FRAMES),
    };
}

static void set_up(T6CodedShot *shot, const T6View *view, OwCamera shown) {
    int side = shot->throw_move.thrower;
    T6Vec3 thrower = fighter_point(&view->fighters[side]), victim = fighter_point(&view->fighters[1 - side]);
    int shape;
    float degrees = spot_angle(shot->id, shot->thrower_right, shot->wide, &shape, &shot->cut_in);
    float angle = degrees * PI / 180 - atan2f(victim.z - thrower.z, victim.x - thrower.x);
    shot->target = scaled(plus(thrower, victim), 0.5f);
    shot->line_point = shot->target;
    shot->line_direction = minus(victim, thrower);
    float height = shape == 0 && !shot->walled_stage ? 0 : HEIGHTS[shape].lowest + HEIGHTS[shape].spread * random_unit();
    shot->eye = plus(shot->target, (T6Vec3){SPOT_DISTANCE * sinf(angle), height, SPOT_DISTANCE * cosf(angle)});
    shot->eye.y = fmaxf(shot->eye.y, floor_under(view) + EYE_RAISE);
    shot->fov = (44 - 3 * random_unit() + (shot->wide ? 5 : 0)) * PI / 180;
    shot->distance_scale = shot->id == WIDER_ID ? 1.4f : 1;
    T6Vec3 shown_back = {(shown.position.x - shown.target.x) / MM, (shown.position.y - shown.target.y) / MM, (shown.position.z - shown.target.z) / MM};
    if (dot(unit(shown_back), unit(minus(shot->eye, shot->target))) > SAME_VIEW) shot->cut_in = false;
}

// The throw is letting go: its thrower is past the release frame, in another move or out of the throw.
static bool released(const T6CodedShot *shot, const T6View *view) {
    const T6ViewFighter *thrower = &view->fighters[shot->throw_move.thrower];
    return thrower->throw_role != THROW_ROLE_THROWER || thrower->move.index != shot->throw_move.move ||
           (shot->throw_move.release > 0 && thrower->move_frame > shot->throw_move.release);
}

// One sim frame: aim between the fighters, the nearer one weighing more, keep the bearing and fit both.
static void step(T6CodedShot *shot, const T6View *view) {
    int side = shot->throw_move.thrower;
    T6Vec3 thrower = fighter_point(&view->fighters[side]), victim = fighter_point(&view->fighters[1 - side]);
    float to_thrower = length(minus(thrower, shot->eye)), to_victim = length(minus(victim, shot->eye));
    T6Vec3 target = toward(thrower, victim, to_thrower / (to_thrower + to_victim));
    float distance = fit_distance(shot->eye, target, thrower, victim) * shot->distance_scale;
    T6Vec3 back = minus(shot->eye, shot->target);
    float across = sqrtf(back.x * back.x + back.z * back.z);
    T6Vec3 eye = across > 0 ? plus(target, scaled(back, distance / across)) : shot->eye;
    eye.y = fmaxf(eye.y, floor_under(view) + EYE_RAISE);
    float rate = length(minus(eye, target)) <= length(back) ? CLOSER_RATE : FURTHER_RATE;
    shot->eye = toward(shot->eye, eye, rate);
    shot->target = toward(shot->target, target, rate);
    if (shot->easing_out || released(shot, view)) shot->easing_out++;
}

float t6_coded_shot(T6CodedShot *shot, const T6View *view, OwCamera shown, OwCamera *camera) {
    if (view->frame < shot->set_up_frame) {
        if (released(shot, view)) shot->easing_out = EASE_OUT_FRAMES;  // over before it showed
        return 0;
    }
    if (shot->easing_out >= EASE_OUT_FRAMES) return 0;
    if (!shot->stepped_frame) set_up(shot, view, shown);
    else if (view->frame > shot->stepped_frame) step(shot, view);
    shot->stepped_frame = view->frame;
    *camera = (OwCamera){
        .position = {shot->eye.x * MM, shot->eye.y * MM, shot->eye.z * MM},
        .target = {shot->target.x * MM, shot->target.y * MM, shot->target.z * MM},
        .fov = shot->fov,
    };
    float easing_in = shot->cut_in ? 1 : eased((float)(view->frame - shot->set_up_frame) / EASE_IN_FRAMES);
    return easing_in * (1 - eased((float)shot->easing_out / EASE_OUT_FRAMES));
}
