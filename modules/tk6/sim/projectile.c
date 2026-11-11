// Shots: a hitscan (a line that grows from a bone, then flies free) and a projectile (a point that flies, then goes back to the
// body). The file of a character picks its rows (T6BodyPoints); the code has no character checks.
#include "sim/projectile.h"

#include "sim/bones.h"
#include "sim/math.h"
#include "sim/move.h"

static constexpr uint16_t PROJECTILE_AURA_PLAIN = 2;  // the aura kind a move change sets; 7 after a hit (an effect, outside the sim)

// The game scales the facing vector before it normalizes it; without the scale the last bit of the direction differs.
static constexpr float DIRECTION_SCALE = 1000.0f;

// The start offsets are in the frame of the bone of skeleton A (the head and pelvis bones have the numbers of skeleton B).
const T6Hitscan T6_HITSCAN_EYE_LASER = {
    .start = {BONE_HEAD, {130.0f, 0.0f, 150.0f}},
    .free_frames = 128, .bone = BONE_HEAD,  // flies free 128 frames; tail on the head bone
};
const T6Projectile T6_PROJECTILE_FIRE = {
    .start = {BONE_PELVIS, {-230.0f, -350.0f, 0.0f}},
    .back = 800.0f, .side = 200.0f, .life = 128,
};

const T6Hitscan *const T6_HITSCANS[] = {nullptr, &T6_HITSCAN_EYE_LASER};  // index 0 is none; index 1 is the eye laser
const T6Projectile *const T6_PROJECTILES[] = {nullptr, &T6_PROJECTILE_FIRE};  // index 0 is none; index 1 is the fire projectile

const T6Hitscan *t6_hitscan_of(const T6Fighter *f) {
    if (f->body_points.hitscan >= sizeof T6_HITSCANS / sizeof *T6_HITSCANS) return nullptr;  // past the table: none
    return T6_HITSCANS[f->body_points.hitscan];  // pick the row by number
}

const T6Projectile *t6_projectile_of(const T6Fighter *f) {
    if (f->body_points.projectile >= sizeof T6_PROJECTILES / sizeof *T6_PROJECTILES) return nullptr;  // past the table: none
    return T6_PROJECTILES[f->body_points.projectile];  // pick the row by number
}

typedef struct { T6SpecialScript script; float step; } ScriptRun;  // the script after one frame, and the step that frame moved

static ScriptRun run_script(const T6World *w, T6SpecialScript script) {  // run one frame of the script
    T6ScriptStep run = t6_script_step(w, (T6Script){script.curve, script.frames, script.curve_frames},  // distance this frame
        (float)script.distance, 0.0f);
    script.curve = run.next.curve;  // keep the script state after the frame
    script.frames = run.next.frames;
    script.curve_frames = run.next.curve_frames;
    return (ScriptRun){script, run.step};
}

static T6Vec4 with_xyz(T6Vec4 to, T6Vec4 from) {
    for (int axis = 0; axis < 3; axis++) to.v[axis] = from.v[axis];  // copy x, y, z; w stays
    return to;
}

T6Vec4 t6_shot_start(T6BodyPoint start, const T6Fighter *f) {
    T6Vec4 offset = vec4_of(start.offset, 1.0f), out;  // the offset as a point (w = 1)
    t6_vec_times_mat(&out, &offset, &f->rig.bones_a[start.bone].world);  // the bone's world matrix moves it to world space
    return out;
}

// --- hitscan

static T6HitscanState stopped(T6HitscanState hitscan) {  // stop: clear the script and the length
    hitscan.script.frames = 0;
    hitscan.script.curve_frames = 0;
    hitscan.length = 0.0f;
    return hitscan;
}

T6SpecialPoints t6_hitscan_start(const T6Fighter *f, T6Hitscan row, T6SpecialScript script) {
    T6SpecialPoints special = f->special;
    special.hitscan.length = 0.0f;  // the line starts at zero length
    special.hitscan.script = script;
    special.hitscan.free_frames = 0;  // no free flight until stopped
    special.hitscan.tip = with_xyz(special.hitscan.tip, t6_shot_start(row.start, f));  // tip at the start point
    return special;
}

// The tail goes on the line bone, so the tip flies on along the line.
T6SpecialPoints t6_hitscan_stop(const T6Fighter *f, T6Hitscan row) {
    T6SpecialPoints special = f->special;
    special.hitscan = stopped(special.hitscan);  // stop the growth
    special.hitscan.free_frames = row.free_frames;  // free flight for the row's frames
    T6Vec4 origin = {{f->rig.bones_b[row.bone].world.m[3][0], f->rig.bones_b[row.bone].world.m[3][1],  // bone origin
        f->rig.bones_b[row.bone].world.m[3][2], 1.0f}};
    special.hitscan.tail = with_xyz(special.hitscan.tail, origin);
    return special;
}

T6SpecialPoints t6_hitscan_step(const T6World *w, T6SpecialPoints special) {  // grow the line, or fly it free if not grown
    T6HitscanState hitscan = special.hitscan;
    ScriptRun run = run_script(w, hitscan.script);  // run one frame of the growth script
    hitscan.script = run.script;
    if (run.step > 0.0f) {  // growth this frame adds to the length
        hitscan.length = run.step + hitscan.length;
        hitscan.speed = (int16_t)(int32_t)run.step;  // last growth step is the free-flight speed
    }
    if (hitscan.length <= 0.0f && hitscan.free_frames > 0) {  // not grown and free frames left: fly the line
        hitscan.free_frames--;
        T6Vec4 *tip = &hitscan.tip, *tail = &hitscan.tail, step;  // the ends of the line; step moves them
        t6_vec_subtract(&step, tip, tail);  // direction: tip minus tail
        t6_vec_normalize(&step, &step);  // make it unit length
        t6_vec_scale(&step, &step, (float)hitscan.speed);  // scale to the speed
        t6_vec_add_xyz(tip, tip, &step);  // move both ends the same way
        t6_vec_add_xyz(tail, tail, &step);
    }
    special.hitscan = hitscan;
    return special;
}

// --- projectile

T6ProjectileHome t6_projectile_home(T6Projectile row, const T6Fighter *f) {  // front point and unit direction from the facing
    float facing_angle = t6_angle_to_rad(f->facing);  // facing in radians
    T6Vec4 direction = {{t6_sin(facing_angle) * DIRECTION_SCALE, 0.0f,  // sin for x, cos for z
        t6_cos(facing_angle) * DIRECTION_SCALE, 0.0f}};
    t6_vec_normalize(&direction, &direction);  // make it a unit vector
    return (T6ProjectileHome){t6_shot_start(row.start, f), direction};
}

T6SpecialPoints t6_projectile_start(const T6Fighter *f, T6Projectile row, T6SpecialScript script) {
    T6SpecialPoints special = f->special;
    T6ProjectileHome home = t6_projectile_home(row, f);  // where it leaves the body
    special.projectile.script = script;
    special.projectile.frames_left = row.life;  // frames of flight: the row's life
    special.projectile.front = with_xyz(special.projectile.front, home.front);  // start at the front point
    special.projectile.direction = with_xyz(special.projectile.direction, home.direction);
    return special;
}

static T6SpecialPoints at_home(T6SpecialPoints special, T6Projectile row, const T6Fighter *f) {  // reset the flight to home
    T6ProjectileHome home = t6_projectile_home(row, f);
    special.projectile.front = home.front;
    special.projectile.direction = home.direction;
    return special;
}

T6SpecialPoints t6_projectile_step(const T6World *w, const T6Fighter *f, T6Projectile row) {  // one frame of flight
    T6SpecialPoints special = f->special;
    if (special.projectile.frames_left <= 0) return special;  // no flight left: nothing moves
    ScriptRun run = run_script(w, special.projectile.script);
    special.projectile.script = run.script;
    if (run.step > 0.0f) {  // the step moves the front along the direction
        T6Vec4 step;
        t6_vec_scale(&step, &special.projectile.direction, run.step);  // step vector: direction times the distance
        t6_vec_add_xyz(&special.projectile.front, &special.projectile.front, &step);
    }
    special.projectile.frames_left--;  // one frame of flight used up
    if (special.projectile.frames_left == 0) return at_home(special, row, f);  // flight over: back to the body
    return special;
}

// --- the fighter's shots

void t6_shots_move_change(T6Fighter *f, const T6Move *new_move) {
    const T6Hitscan *hitscan = t6_hitscan_of(f);
    const T6Projectile *projectile = t6_projectile_of(f);
    if (hitscan != nullptr) {
        if (f->special.hitscan.length > 0.0f) f->special = t6_hitscan_stop(f, *hitscan);  // a grown line stops and flies free
        else f->special.hitscan = stopped(f->special.hitscan);  // no growth yet: just clear it
    }
    if (projectile != nullptr) {
        if (new_move->first_active != 0 && new_move->hits.launches) {  // a launching move sends the projectile back to the body
            f->special.projectile.frames_left = 0;  // end the flight
            f->special = at_home(f->special, *projectile, f);
        }
        f->special.projectile.aura = PROJECTILE_AURA_PLAIN;  // set the aura to the plain kind
    }
}

void t6_shots_step(const T6World *w, T6Fighter *f) {
    const T6Hitscan *hitscan = t6_hitscan_of(f);
    const T6Projectile *projectile = t6_projectile_of(f);
    if (hitscan != nullptr) f->special = t6_hitscan_step(w, f->special);  // hitscan row: grow or fly its line
    if (projectile != nullptr) f->special = t6_projectile_step(w, f, *projectile);  // projectile row: fly it
}
