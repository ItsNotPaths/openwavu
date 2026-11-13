// The shot (FUN_001d6054 start point, FUN_001d62fc tip, FUN_001ba9f4 step, properties 0x80d5..0x80d7).
#include "sim/shot.h"

#include "sim/bones.h"
#include "sim/move.h"

static constexpr int16_t FREE_FRAMES = 128;  // a stopped shot flies free this long

// The start offset of each mode, on the head (game bone record 5) but for mode 14, on the hips, which grows along z.
// Mode 13 sits on ATAMA_jnt (record 74) in the game; the sim has no helper bones, so it takes the head.
typedef struct { uint8_t bone; T6Vec3 offset; } ShotMode;
static const ShotMode MODES[] = {
    {BONE_HEAD, {120, 0, 170}}, {BONE_HEAD, {180, 0, 70}}, {BONE_HEAD, {180, 0, 70}}, {BONE_HEAD, {180, 0, 70}},
    {BONE_HEAD, {180, 0, 70}},  {BONE_HEAD, {180, 0, 70}}, {BONE_HEAD, {120, 0, 70}}, {BONE_HEAD, {120, 0, 70}},
    {BONE_HEAD, {110, 0, 60}},  {BONE_HEAD, {120, 0, 170}}, {BONE_HEAD, {120, 0, 170}}, {BONE_HEAD, {180, 0, 70}},
    {BONE_HEAD, {500, 420, 0}}, {BONE_HEAD, {120, 0, 170}}, {BONE_HIPS, {0, 0, 500}},
};
static constexpr uint32_t GROWS_ALONG_Z = 14;
static constexpr uint32_t FREE_HEIGHT_MODES = 0x3615;  // modes 0, 2, 4, 9, 10, 12, 13; the others keep the start height

static ShotMode mode_of(uint32_t mode) {
    if (mode < sizeof MODES / sizeof *MODES) return MODES[mode];
    return MODES[1];  // past the table: the default offset
}

static bool keeps_start_height(uint32_t mode) { return mode > 13 || (FREE_HEIGHT_MODES >> mode & 1) == 0; }

static T6Vec4 on_bone(const T6Fighter *f, ShotMode mode, T6Vec3 offset) {
    T6Vec4 point = vec4_of(offset, 1), out;
    t6_vec_times_mat(&out, &point, &f->rig.bones_b[mode.bone].world);
    return out;
}

static T6Vec4 with_xyz(T6Vec4 to, T6Vec4 from) {
    for (int axis = 0; axis < 3; axis++) to.v[axis] = from.v[axis];  // w stays
    return to;
}

// The shot stops growing; the free flight is set apart.
static void stopped(T6ShotState *shot) {
    shot->script.frames = 0;
    shot->script.curve_frames = 0;
    shot->length = 0.0f;
}

void t6_shot_start(const T6World *w, T6Fighter *f, uint16_t pushback) {
    T6ShotState *shot = &f->special.shot;
    const T6Pushback *entry = t6_pushback_at(w, t6_ref(f->moveset, pushback));  // a pushback entry is the growth script
    shot->script = (T6SpecialScript){t6_ref(f->moveset, entry->curve), (int16_t)entry->frames, (int16_t)entry->curve_frames,
                                     entry->distance};
    shot->length = 0.0f;
    shot->free_frames = 0;
    ShotMode mode = mode_of(shot->mode);
    shot->tip = with_xyz(shot->tip, on_bone(f, mode, mode.offset));
    for (int slot = 0; slot < f->hitbox_slots; slot++)  // the hitboxes start on the tip
        f->hit.segment[slot].start = f->hit.segment[slot].end = vec3_of(shot->tip);
}

void t6_shot_stop(T6Fighter *f) {
    stopped(&f->special.shot);
    f->special.shot.free_frames = FREE_FRAMES;
}

void t6_shot_move_change(T6Fighter *f) {
    if (f->kind != 0) return;  // fighters only
    T6ShotState *shot = &f->special.shot;
    if (shot->length > 0.0f) shot->free_frames = FREE_FRAMES;
    stopped(shot);
}

void t6_shot_step(const T6World *w, T6Fighter *f) {
    if (f->kind != 0) return;  // fighters only
    T6ShotState *shot = &f->special.shot;
    T6ScriptStep run = t6_script_step(w, (T6Script){shot->script.curve, shot->script.frames, shot->script.curve_frames},
                                      (float)shot->script.distance, 0.0f);
    shot->script.curve = run.next.curve;
    shot->script.frames = run.next.frames;
    shot->script.curve_frames = run.next.curve_frames;
    if (run.step > 0.0f) {
        shot->length += run.step;
        shot->speed = (int16_t)(int32_t)run.step;  // the last growth step is the free flight speed
    }
    if (shot->length <= 0.0f && shot->free_frames > 0) {  // not growing and free frames left: fly along tail -> tip
        shot->free_frames--;
        T6Vec4 step;
        t6_vec_subtract(&step, &shot->tip, &shot->tail);
        t6_vec_normalize(&step, &step);
        t6_vec_scale(&step, &step, (float)shot->speed);
        t6_vec_add_xyz(&shot->tip, &shot->tip, &step);
        t6_vec_add_xyz(&shot->tail, &shot->tail, &step);
    }
}

void t6_shot_tip(T6Fighter *f) {
    T6ShotState *shot = &f->special.shot;
    ShotMode mode = mode_of(shot->mode);
    T6Vec3 grown = mode.offset;
    if (shot->mode == GROWS_ALONG_Z) grown.z += shot->length;
    else grown.x += shot->length;
    if (shot->free_frames == 0) shot->tip = with_xyz(shot->tip, on_bone(f, mode, grown));
    if (keeps_start_height(shot->mode)) shot->tip.y = on_bone(f, mode, mode.offset).y;
}
