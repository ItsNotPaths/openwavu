// The move blend producer. It starts and stops the blend of A locals that t5_pose_blend consumes:
// at a start it samples two poses once and stores their difference in f->blend.delta. The pause test is false for
// every call from the battle frame, and installing the producer stands for the gate byte being 1. The scratch rig
// is f->pose_scratch (one per fighter): the spine frames of a pose read the translation rows of its bones 1 and 13,
// which only the reset (and the aim prediction) write. The second scratch rig is a local: nothing writes its
// translation rows, so they stay 0.
#include <math.h>
#include <string.h>

#include "sim/blend.h"
#include "sim/bones.h"
#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/pose.h"
#include "sim/quat.h"
#include "sim/transition.h"
#include "sim/units.h"
#include "sim/vec.h"

enum { BLEND_LENGTH_PICK = -1 };  // T5Fighter.blend_len_override: the blend in picks its length

static const T5BlendStart NO_BLEND = {BLEND_OFF, {0, 0}};

// same move means same index and same move set (an empty ref matches any empty ref)
static bool same_move(T5Ref first, T5Ref second) { return first.index == second.index && (first.index < 0 || first.set == second.set); }

static T5BlendSpan span_of(int32_t frames) { return (T5BlendSpan){frames, frames * CLOCK_PER_FRAME}; }

// --- state helpers

void t5_blend_snapshot(T5Fighter *f) {
    f->blend.previous_move = f->move;  // remember which move the fighter is in, to spot a move change next frame
    f->root_local = f->bone1;  // fighter state: the next blend in reads it
}

void t5_blend_reset(T5Fighter *f) {
    t5_blend_snapshot(f);
    T5MoveBlend *blend = &f->blend;
    blend->ratio = 0.0f;  // no blend mixed in
    blend->resume = 0;
    blend->mode = BLEND_OFF;  // no blend running
    blend->started = 0;  // no blend started this frame
    blend->length = (T5BlendSpan){0, 0};
    blend->done = (T5BlendSpan){0, 0};
    blend->offset = (T5Vec3){};
    for (int bone = 0; bone < T5_POSE_BONES; bone++) f->pose_scratch[bone].local = f->rig.bones_a[bone].local;  // to scratch rig
}

typedef struct {
    T5BlendSpan length, done;
} BlendClock;

// One step of |speed| clock units: down to 0 in BLEND_IN, up to the length in the others; off clears the clock.
static BlendClock clock_step(enum T5BlendMode mode, BlendClock clock, int32_t step) {
    if (mode == BLEND_IN) {  // blend in: the clock counts down to 0
        if (clock.done.clock > 0) clock.done = (T5BlendSpan){clock.done.frames - 1, clock.done.clock - step};  // still running
        else if (clock.done.clock < 0) clock.done = (T5BlendSpan){0, 0};  // went below 0: clear it
    } else if (mode == BLEND_TO_PENDING || mode == BLEND_OUT) {  // blend to pending or out: the clock counts up to the length
        if (clock.done.clock < clock.length.clock)  // not at the length yet
            clock.done = (T5BlendSpan){clock.done.frames + 1, clock.done.clock + step};
        else if (clock.done.clock > clock.length.clock) clock.done = clock.length;  // went past the length: hold at the length
    } else if (mode == BLEND_OFF) {  // no blend: clear the length and the clock
        clock = (BlendClock){{0, 0}, {0, 0}};
    }
    return clock;
}

void t5_blend_clock(T5Fighter *f) {
    int32_t step = f->speed;  // the clock moves by the fighter's move speed, even when negative
    if (step < 0) step = -step;
    BlendClock clock = clock_step(f->blend.mode, (BlendClock){f->blend.length, f->blend.done}, step);  // advance one step
    f->blend.length = clock.length;
    f->blend.done = clock.done;
}

int16_t t5_blend_pending_start_frame(const T5Fighter *f) {
    enum T5TransitionClass kind = t5_transition_class(f->transition);
    if (kind == TRANSITION_CARRY) return f->pending_frame;  // carry: the pending move starts at the frame already planned
    if (kind != TRANSITION_PARAM) return 0;  // other transitions: start at frame 0
    uint16_t param = f->start_param;
    uint16_t low = param % START_PARAM_OFFSET_RANGE;  // the offset part of the start parameter
    uint16_t here = (uint16_t)f->frame2 - (uint16_t)f->frame + (uint16_t)f->pending_frame;
    if (param & START_PARAM_AFTER_FRAME) return (int16_t)(low + (uint16_t)f->pending_frame);  // pending frame plus offset
    if (param & START_PARAM_BEFORE_FRAME) return (int16_t)((uint16_t)f->pending_frame - low);  // pending frame minus offset
    if (param & START_PARAM_AFTER_FRAME2) return (int16_t)(here + low);  // start at the frame2 position plus the offset
    if (!(param & START_PARAM_BEFORE_FRAME2)) return low;  // no flag: the offset is the start frame
    return (int16_t)(here - low);  // start at the frame2 position minus the offset
}

// --- the three starts

// Frames of a blend in, 0 for none: up to the first active frame (at most BLEND_IN_FRAMES_MAX), or BLEND_IN_FRAMES into a
// move without active frames (BLEND_IN_FRAMES_MAX while thrown); never past the end of the move.
static int32_t blend_in_frames(const T5Fighter *f, const T5Move *move) {
    int32_t left = move->length - f->frame;  // frames left in the new move
    if (left <= 0) return 0;  // no frames left, no blend
    int32_t frames = f->blend_length_override;  // a move property can set the blend length
    if (frames == BLEND_LENGTH_PICK) {  // the move did not set a length: pick one
        if (move->first_active == 0) {  // the new move has no active frames
            frames = BLEND_IN_FRAMES.ticks;  // short default blend
            if (t5_thrown(f->throw.chain)) frames = BLEND_IN_FRAMES_MAX.ticks;  // being thrown: longest blend
        } else {
            if (move->first_active - 1 <= f->frame) return 0;  // already at the active frames, no blend
            frames = move->first_active - f->frame - 1;  // blend until just before the first active frame
            if (frames > BLEND_IN_FRAMES_MAX.ticks) frames = BLEND_IN_FRAMES_MAX.ticks;  // cap the length
        }
    }
    if (left < frames) frames = left;  // never longer than what is left of the move
    return frames;
}

// The move changed, or a cancel past the end picked the same move with a new anim.
T5BlendStart t5_blend_start_in(const T5World *w, const T5Fighter *f) {
    bool picked_again = f->pick_kind == PICKED_AHEAD && f->anim_changed != 0;  // cancel past move end picked a new-anim move
    if (same_move(f->blend.previous_move, f->move) && !picked_again) return NO_BLEND;  // no move change, no blend in
    int32_t frames = blend_in_frames(f, t5_move_at(w, f->move));  // length of the blend into the new move
    if (frames <= 1) return NO_BLEND;
    return (T5BlendStart){BLEND_IN, span_of(frames)};  // blend in: from the old pose into the new move
}

// The move runs out with nothing pending. Playing backward the blend is as long as the frames behind, not the frames left
// (stock, kept; may become an issue for backward moves later).
T5BlendStart t5_blend_start_out(const T5World *w, const T5Fighter *f) {
    if (!t5_ref_none(f->pending_move)) return NO_BLEND;  // a move is pending, that blend handles the change
    int32_t left = t5_move_at(w, f->move)->length - f->frame;  // frames left in this move
    if (left > BLEND_OUT_WINDOW.ticks) return NO_BLEND;  // too early, the move is not about to end
    int32_t frames = f->frame;  // playing backward: the frames behind
    if (f->play_direction > 0) frames = left + 1;  // playing forward: the frames left, one more
    if (frames <= 1) return NO_BLEND;
    return (T5BlendStart){BLEND_OUT, span_of(frames)};  // blend out: from the end of this move into the next move
}

// A pending move starts later in this move, or alternate_move asks for a blend. A pending blend while either move is in its active
// frames has no length: it starts and ends at once.
T5BlendStart t5_blend_start_pending(const T5World *w, const T5Fighter *f) {
    if (!t5_ref_none(f->pending_move) && f->pick_kind != PICKED_AHEAD && f->frame < f->pending_frame) {  // pending starts later
        const T5Move *move = t5_move_at(w, f->move);
        const T5Move *pending = t5_move_at(w, t5_move_lookup(w, f, (uint16_t)f->pending_id));  // the pending move
        T5BlendStart start = {BLEND_TO_PENDING, span_of(f->pending_frame - f->frame + 1)};  // frames to pending start, plus one
        bool blends_in_active = (move->flags & T5_MOVE_BLENDS_IN_ACTIVE) != 0;  // this move blends in active frames
        if (!blends_in_active && move->last_active >= f->frame) {  // this move is in or before its last active frame
            start.asked = (T5BlendSpan){0, 0};
        } else if (!blends_in_active && pending->first_active != 0) {  // the pending move has active frames
            int32_t start_frame = t5_blend_pending_start_frame(f) + 1;  // the frame the pending move starts at, one based
            if (pending->first_active <= start_frame && pending->last_active >= start_frame)  // starts inside its active frames
                start.asked = (T5BlendSpan){0, 0};  // no length
        }
        return start;
    }
    if (!t5_ref_none(f->alternate_move))  // alternate move: blend to it over the length it asks for
        return (T5BlendStart){BLEND_TO_PENDING, span_of(f->alternate_blend_length)};
    return NO_BLEND;
}

void t5_blend_start(T5Fighter *f, T5BlendStart start) {
    if (start.mode == BLEND_OFF) return;  // nothing to start
    f->blend.asked = start.asked;  // the length asked for
    f->blend.mode = start.mode;
    f->blend.started = 1;  // the start frame samples the poses
}

// --- the start frame: the two poses and the running length

typedef struct {
    T5PoseAt from, to;
    T5BlendSpan length, done;
} BlendRun;

// From the old pose (as stored) into the new move; the clock counts down from the end.
static BlendRun run_in(const T5Fighter *f) {
    T5BlendSpan asked = f->blend.asked;
    return (BlendRun){
        .from = {f->blend.previous_move, f->frame_decided - 1},  // from the old move, at the frame it was left on
        .to = {f->move, f->frame - 1},  // to the new move, at its current frame
        .length = asked,
        .done = {asked.frames - 1, asked.clock - CLOCK_PER_FRAME},  // clock starts one frame short, counts down
    };
}

static BlendRun run_pending(const T5World *w, const T5Fighter *f) {
    T5BlendSpan asked = f->blend.asked;
    BlendRun run = {.from = {f->move, f->pending_frame}, .length = asked, .done = {0, 0}};  // from here at the takeover frame
    run.to = (T5PoseAt){t5_move_lookup(w, f, (uint16_t)f->pending_id), t5_blend_pending_start_frame(f)};  // pending start frame
    if (!t5_ref_none(f->alternate_move)) {  // an alternate move replaces both poses
        run.from.frame = f->alternate_from_frame + asked.frames - 1;  // alternate start frame plus blend length
        run.to = (T5PoseAt){f->alternate_move, f->alternate_to_frame - 1};  // to the alternate move, at its alternate frame
    }
    return run;
}

static BlendRun run_out(const T5World *w, const T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    BlendRun run = {.from = {f->move, 0},  // from this move to its next move
                    .to = {t5_move_lookup(w, f, move->next_move), 0},
                    .length = f->blend.asked,
                    .done = {0, 0}};
    if (f->play_direction > 0) run.from.frame = move->length;  // playing forward: start from the last frame
    return run;
}

// --- the poses

static void sample_scaled(const T5World *w, T5Fighter *f, T5PoseAt pose_at, T5Vec4 pose[T5_CHANNELS]) {
    bool keep_hips = (t5_move_at(w, pose_at.move)->flags & T5_MOVE_KEEP_HIPS) != 0;  // some moves keep the anim hips
    t5_anim_sample(t5_anim_at(w, pose_at.move), (float)pose_at.frame, pose, keep_hips);  // sample anim at this frame
    t5_pose_scale_root(pose, f->scale_xz, f->scale_xz_add, f->scale_y);  // scale the root by the fighter's size
}

// x and z of the hip key turned by rows 0 and 2 of `frame`
static T5Vec4 turned_hip(T5Vec4 hip, const T5Mat4 *frame) {
    float x = hip.x, z = hip.z;
    hip.x = fmaf(x, frame->m[0][0], z * frame->m[0][2]);  // turn the hip x and z by the frame rows
    hip.z = fmaf(x, frame->m[2][0], z * frame->m[2][2]);
    return hip;
}

static T5Mat4 matrix_difference(const T5Mat4 *left, const T5Mat4 *right) {
    T5Mat4 out;
    for (int row = 0; row < 4; row++)  // subtract row by row
        t5_vec_subtract((T5Vec4 *)out.m[row], (const T5Vec4 *)left->m[row], (const T5Vec4 *)right->m[row]);
    return out;
}

// The new spine faces back from its hips (more than 120 degrees) while the move change turned the fighter.
static bool spine_turned_back(const T5World *w, const T5Fighter *f, const T5Bone *locals) {
    if ((t5_move_at(w, f->blend.to.move)->flags & T5_MOVE_KEEP_HIPS) != 0 || f->change_turn == 0)  // needs a turn, hips not kept
        return false;
    T5Mat4 spine;
    t5_mat_set(&spine, &locals[BONE_HIPS].local);  // spine matrix: hips then spine
    t5_mat_multiply(&spine, &locals[BONE_SPINE].local);
    // the spine faces away from the hips by more than 120 degrees
    return t5_vec_dot3((const T5Vec4 *)locals[BONE_HIPS].local.m[2], (const T5Vec4 *)spine.m[2]) < BLEND_TURN_BACK;
}

static T5Mat4 half_turned(T5Mat4 matrix) {
    T5Mat4 turned;
    t5_mat_identity(&turned);
    t5_mat_rotate_y(&turned, HALF_TURN.bits);  // half a turn around the up axis
    t5_mat_multiply(&turned, &matrix);
    return turned;
}

// BLEND_IN: delta = the stored old locals minus the locals of the new pose
static void pose_in(T5World *w, T5Fighter *f) {
    T5Vec4 pose[T5_CHANNELS] = {};
    T5Bone *locals = f->pose_scratch;
    sample_scaled(w, f, f->blend.to, pose);  // sample the new move's pose
    pose[CHANNEL_HIP] = turned_hip(pose[CHANNEL_HIP], &f->stored[BONE_HIPS]);  // turn the new hip offset by the old hip facing
    f->blend.offset = vec3_subtract(f->root_local, vec3_of(pose[CHANNEL_HIP]));  // old hip minus new hip
    t5_skel_pose(locals, &w->data[f->data]->skeleton, pose);  // build the new pose's bone locals in the scratch rig
    bool back = spine_turned_back(w, f, locals);  // does the old spine need a half turn to match
    for (int bone = 0; bone < T5_POSE_BONES; bone++) {
        T5Mat4 old = f->stored[bone];  // the old local of this bone
        if (back && (bone == BONE_SPINE || bone == BONE_PELVIS)) old = half_turned(old);  // spine or pelvis: old one half turned
        f->blend.delta[bone] = matrix_difference(&old, &locals[bone].local);  // delta: old pose minus new pose
    }
    t5_blend_snapshot(f);
}

// BLEND_TO_PENDING and BLEND_OUT: delta = the locals of the "to" pose minus those of the "from" pose
static void pose_pair(T5World *w, T5Fighter *f) {
    T5Vec4 from[T5_CHANNELS] = {}, to[T5_CHANNELS] = {};  // the two poses to blend between
    T5Bone *from_locals = f->pose_scratch, to_locals[T5_POSE_BONES] = {};
    sample_scaled(w, f, f->blend.from, from);  // sample the from pose
    sample_scaled(w, f, f->blend.to, to);  // sample the to pose
    T5Mat4 hips = {};
    t5_quat_to_mat(&hips, &from[CHANNEL_HIPS]);  // the from hip facing as a matrix
    to[CHANNEL_HIP] = turned_hip(to[CHANNEL_HIP], &hips);  // turn the to hip offset by the from hip facing
    f->blend.offset = vec3_subtract(vec3_of(to[CHANNEL_HIP]), vec3_of(from[CHANNEL_HIP]));  // to hip minus from hip
    const T5Skeleton *skeleton = &w->data[f->data]->skeleton;
    t5_skel_pose(from_locals, skeleton, from);  // bone locals of the from pose (in the scratch rig)
    t5_skel_pose(to_locals, skeleton, to);  // bone locals of the to pose
    for (int bone = 0; bone < T5_POSE_BONES; bone++)  // delta per bone: to pose minus from pose
        f->blend.delta[bone] = matrix_difference(&to_locals[bone].local, &from_locals[bone].local);
    t5_blend_snapshot(f);
}

// --- the producer

static bool no_blend_in(const T5Fighter *f, const T5Move *move) {
    return (move->flags & T5_MOVE_NO_BLEND_IN) != 0 ||  // the move forbids it
           (f->hit_this_move != 0 && !t5_in_throw(f->throw.chain));  // hit this move, not in a throw
}

static bool in_active_frames(const T5Fighter *f, const T5Move *move) {
    return move->first_active != 0 && f->frame <= move->last_active &&  // before or in the active frames
           (move->flags & T5_MOVE_BLENDS_IN_ACTIVE) == 0;  // unless the move allows blending there
}

static bool no_blend_out(const T5Fighter *f, const T5Move *move) {
    return (move->flags & T5_MOVE_NO_BLEND_OUT) != 0 ||  // the move forbids it
           f->pending_flags.no_blend_out != 0 ||  // the pending cancel forbids it
           in_active_frames(f, move) ||  // in active frames
           f->juggle_count != 0 || (f->in_air_window != 0 && f->hit_this_move != 0);  // juggled, or in the air after being hit
}

static bool blend_ends(const T5Fighter *f, bool no_in, bool no_out) {
    const T5MoveBlend *blend = &f->blend;
    bool over = blend->done.clock >= blend->length.clock;  // the clock reached the length
    if (blend->mode == BLEND_IN) return blend->done.clock < 1 || no_in;  // ends when clock runs down or forbidden
    if (blend->mode == BLEND_TO_PENDING) return over || no_out;  // ends at the length, or when a move forbids it
    if (blend->mode == BLEND_OUT) return over || f->anim_changed != 0 || no_out;  // also ends when the move changes anim
    return false;
}

// The first blend that starts: after a move change, else toward a pending move, else (none running) at the end of the move.
static T5BlendStart next_blend(const T5World *w, const T5Fighter *f, bool no_in, bool no_out) {
    T5BlendStart blend_in = no_in ? NO_BLEND : t5_blend_start_in(w, f);  // a move change comes first
    if (blend_in.mode != BLEND_OFF) return blend_in;  // a blend in starts
    enum T5BlendMode running = f->blend.mode;  // the blend running now
    if (no_out || running == BLEND_IN || running == BLEND_TO_PENDING) return NO_BLEND;  // running in/pending, or out forbidden
    T5BlendStart pending = t5_blend_start_pending(w, f);  // a blend toward a pending move
    if (pending.mode != BLEND_OFF || running != BLEND_OFF) return pending;  // pending starts or one runs: no new blend out
    return t5_blend_start_out(w, f);  // nothing else: maybe blend out at the move end
}

// Stops a running blend, then starts one: after a move change, toward a pending move, or at the end of the move.
static void update_mode(const T5World *w, T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    T5MoveBlend *blend = &f->blend;
    blend->started = 0;  // no blend started this frame
    bool no_in = no_blend_in(f, move);  // a move forbids blending in
    bool no_out = no_blend_out(f, move);  // a move forbids blending out
    if (f->clean_hit != 0) {  // a clean hit this frame: no blending at all
        no_in = true;
        no_out = true;
    }
    if (blend_ends(f, no_in, no_out)) blend->mode = BLEND_OFF;  // the running blend is over
    t5_blend_start(f, next_blend(w, f, no_in, no_out));  // start the next blend, if any
}

static const T5Frames *const SNAP_OF_CUT[] = {
    [T5_CUT_ENTRANCE] = &SNAP_ENTRANCE,
    [T5_CUT_ROUND] = &SNAP_ROUND,
    [T5_CUT_MATCH_END] = &SNAP_MATCH_END,
};

void t5_scene_cut(T5World *w, T5SceneCut cut) { w->blend_snap_left = SNAP_OF_CUT[cut]->ticks; }  // start pose snap by cut kind

void t5_blend_snap_step(T5World *w) {
    if (w->blend_snap_left > 0) w->blend_snap_left--;  // count the snap down one frame
}

static void take_run(T5MoveBlend *blend, BlendRun run) {
    blend->from = run.from;  // keep the two poses and the running length
    blend->to = run.to;
    blend->length = run.length;
    blend->done = run.done;
}

void t5_blend_producer(T5World *w, T5Fighter *f) {
    if (w->blend_snap_left > 0) t5_blend_reset(f);  // scene cut snap: no blending, poses jump
    else update_mode(w, f);  // stop the running blend and start a new one if needed
    T5MoveBlend *blend = &f->blend;
    if (blend->started == 0) {  // no blend started: just keep the running blend going
        t5_blend_clock(f);
        t5_blend_snapshot(f);
        return;
    }
    if (blend->mode == BLEND_IN) {
        take_run(blend, run_in(f));  // the two poses and length of the blend in
        pose_in(w, f);
    } else if (blend->mode == BLEND_TO_PENDING) {
        take_run(blend, run_pending(w, f));  // the two poses and length of the blend to pending
        pose_pair(w, f);
    } else {
        take_run(blend, run_out(w, f));  // the two poses and length of the blend out
        pose_pair(w, f);
    }
}
