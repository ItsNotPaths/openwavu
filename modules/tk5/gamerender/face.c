#include "gamerender/face.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "sim/bones.h"
#include "sim/constants.h"
#include "sim/math.h"
#include "sim/properties.h"
#include "sim/quat.h"
#include "sim/units.h"

// Face values: the frames of the poses' clip 0. 0, 5, 7 and 9 are only set by move data or voices.
enum { NEUTRAL_FACE = 1, BLINK_FACE = 2, DOWN_FACE = 3, HURT_FACE = 4, EFFORT_FACE = 6, SHOUT_FACE = 8 };

enum {
    BLINK_GAP_MAX = 200,    // ticks between blinks: rand() % this
    BLINK_SHUT = 3,         // the lids close over 3 ticks and stay shut 4
    EFFORT_LEAD = 3,        // the effort face comes this many frames before the first active one
    EFFORT_HOLD = 13,       // ticks the effort face stays
    SHOUT_HOLD = 5,         // ticks a voice's shout face stays; other voice values stay EFFORT_HOLD
    MOVE_BLEND = 4,         // a move start sets its face over this many ticks
    CLIP_END_BLEND = 3,     // the face after a clip
    EFFORT_BLEND = 5,
    RELAX_BLEND = 12,       // back to neutral after an effort or voice face
    PROPERTY_CLIP_BLEND = 2,
    VOICE_CLIP_BLEND = 4,
    VOICE_VALUE_BLEND = 5,
};

// 0x8157: face value * VALUE_UNIT + blend frames. 0x8158: the clip, FACE_CLIP_BANK for the clips bank.
enum : uint16_t { FACE_VALUE_PROPERTY = T5_PROPERTY_BASE + 0x157, FACE_CLIP_PROPERTY = T5_PROPERTY_BASE + 0x158, VALUE_UNIT = 256 };

enum { KUMA = 11, PANDA = 32 };  // their voices start face clips in any phase

static const float SAME_TIME = 1e-5f;  // times closer than this count as equal
static const float PLAY_RATE = (float)PLAY_SPEED / CLOCK_PER_FRAME;  // clip frames a tick
static const float MOVE_SCALE = 0.2f;   // a move channel's bon units per step
static const float SIZE_SCALE = 0.01f;  // a scale channel: 100 = as is

// --- what the face plays

static T5FacePlay value_play(float value, uint16_t blend_frames) { return (T5FacePlay){value, 0, blend_frames}; }

static bool plays_clip(T5FacePlay play) { return play.clip != 0; }

static T5FaceBank bank_of(T5FaceBanks banks, T5FacePlay play) { return (play.clip & FACE_CLIP_BANK) ? banks.clips : banks.poses; }

static float clip_length(T5FaceBanks banks, T5FacePlay play) {
    return (float)t5_face_clip_frames(bank_of(banks, play), play.clip & FACE_CLIP_INDEX);
}

// After the match a clip stops on its last frame: the win pose keeps its face.
static bool holds_clip(T5Phase phase) { return phase == T5_PHASE_NONE || phase == T5_PHASE_MATCH_END || phase == T5_PHASE_OVER; }

static int16_t blink_gap(void) { return (int16_t)(rand() % BLINK_GAP_MAX); }

static T5Face relax(T5Face face, uint16_t blend_frames) {
    face.play = value_play(NEUTRAL_FACE, blend_frames);
    face.blink = blink_gap();
    return face;
}

// (hole face-effect :tags (tk5mod effects fighter-detail) :sev polish) the face effect 0xb1f84 (shared record 0x1d at the head, on the down face of a move start and the effort face) is not played: its game checks (0x84a9c, 0x70e50, mask 0x40 << slot) are open.
// 0x2fd5c: the face a new move sets, unless a clip plays.
static T5Face move_face(T5Face face, const T5ViewFace *fighter) {
    float value = face.play.time;
    if (plays_clip(face.play)) return face;
    if (fighter->state_4) {
        if (value != DOWN_FACE) face.play = value_play(DOWN_FACE, MOVE_BLEND);
    } else if (fighter->hurt_unlooking) {
        if (value != HURT_FACE) face.play = value_play(HURT_FACE, MOVE_BLEND);
    } else if (value != NEUTRAL_FACE && value != BLINK_FACE) {
        face = relax(face, MOVE_BLEND);
    }
    return face;
}

// A new face property sets the face: a repeat of the same one is new by its set frame.
static T5Face take_property(T5Face face, T5PoseProp property) {
    bool fresh = property.id != face.seen.id || property.value != face.seen.value || property.set_frame != face.seen.set_frame;
    face.seen = property;
    if (!fresh) return face;
    if (property.id == FACE_VALUE_PROPERTY) face.play = value_play((float)(property.value / VALUE_UNIT), property.value % VALUE_UNIT);
    if (property.id == FACE_CLIP_PROPERTY) face.play = (T5FacePlay){0.0f, property.value, PROPERTY_CLIP_BLEND};
    return face;
}

// 0x2ff10: the clip clock, then, while no clip plays and no property posed the face, the effort face and the blinks.
static T5Face step(T5Face face, T5FaceBanks banks, const T5ViewFace *fighter, T5Phase phase) {
    float length = clip_length(banks, face.play);
    if (plays_clip(face.play) && (!holds_clip(phase) || face.play.time < length)) face.play.time += PLAY_RATE;
    if (face.play.time > length) face = relax(face, CLIP_END_BLEND);  // the clip is over, or a face value past the poses
    if (face.play.blend_frames > 0) face.play.blend_frames--;
    if (plays_clip(face.play) || fighter->posed) return face;
    if (fighter->frames_to_active == EFFORT_LEAD) {
        face.play = value_play(EFFORT_FACE, EFFORT_BLEND);
        face.blink = EFFORT_HOLD;
        return face;
    }
    float value = face.play.time;
    bool counts = value == NEUTRAL_FACE || value == BLINK_FACE || value >= EFFORT_FACE;  // faces 3, 4, 5 stay until the next move
    if (!counts || --face.blink >= 0) return face;
    if (value == NEUTRAL_FACE) {
        face.play = value_play(BLINK_FACE, BLINK_SHUT);
        face.blink = BLINK_SHUT;
        return face;
    }
    return relax(face, value >= EFFORT_FACE ? RELAX_BLEND : 0);  // a blink opens at once, a face relaxes slowly
}

// --- the pose

static bool same_play(T5FacePlay first, T5FacePlay second) {
    return fabsf(first.time - second.time) < SAME_TIME && first.clip == second.clip && first.blend_frames == second.blend_frames;
}

// 0xbe0a8, 0xc2358: the target a 1 / blend_frames step from the last pose. The game samples only when the play changed.
static T5Face sample(T5Face face, T5FaceBanks banks) {
    if (face.has_sample && same_play(face.sampled, face.play)) return face;
    T5FacePose target = t5_face_clip_sample(bank_of(banks, face.play), face.play.clip & FACE_CLIP_INDEX, face.play.time);
    if (face.has_sample && face.play.blend_frames > 0) target = t5_face_pose_blend(face.pose, target, 1.0f / face.play.blend_frames);
    face.pose = target;
    face.sampled = face.play;
    face.has_sample = true;
    return face;
}

// --- eyes (0xe8ed8, 0xe8c5c): two face bones that turn toward the opponent's head over the face pose

enum { RIGHT_EYE_BONE = 96, LEFT_EYE_BONE = 105 };

static const float EYE_YAW_LIMIT = 0.453785598f;  // 26 degrees
static const float EYE_PITCH_DOWN = -0.0349065848f;
static const float EYE_PITCH_UP = 0.261799395f;
static const float EYE_PITCH_UP_LOW = 0.104719758f;  // the models whose eyes look up less
static const int16_t LOW_EYE_MODELS[] = {5, 7, 8, 21, 24};

static T5AimJoint eye_joint(int16_t model_id) {
    T5AimJoint eyes = {
        .limits = {-EYE_YAW_LIMIT, EYE_YAW_LIMIT, EYE_PITCH_DOWN, EYE_PITCH_UP, AIM_PITCH_HOLD},
        .rate = AIM_RATE, .fast_rate = AIM_RATE_SNAP,
        .pitches = true, .stops_behind = true, .chest_speeds_up = true, .leads_hips = true,
    };
    for (size_t model = 0; model < sizeof LOW_EYE_MODELS / sizeof *LOW_EYE_MODELS; model++)
        if (LOW_EYE_MODELS[model] == model_id) eyes.limits.pitch_up = EYE_PITCH_UP_LOW;
    return eyes;
}

// In the head frame x looks ahead: the yaw turns toward -y, the pitch toward -z.
static T5AimState eye_seen(const T5ViewFighter *fighter) {
    const T5LookAim *aim = &fighter->look.aim;
    T5Vec4 direction = t5_look_seen_from(&fighter->rig.bones_a[BONE_HEAD].world, aim->eyes, aim->target);
    float yaw = -t5_fast_atan2(direction.y, direction.x);
    float pitch = -t5_fast_atan2(direction.z, sqrtf(fmaf(direction.x, direction.x, direction.y * direction.y)));
    return (T5AimState){yaw, pitch, t5_aim_zone(yaw)};
}

static T5AimState aim_eyes(T5AimState last, const T5ViewFighter *fighter) {
    const T5ViewLook *look = &fighter->look;
    T5AimState seen = eye_seen(fighter);
    if (look->weight <= 0) {  // not looking: follow the target unsmoothed, the bones keep the face pose
        seen.zone = t5_aim_zone_kept(last.zone, seen.zone);
        return seen;
    }
    T5AimFrame aim_frame = {.lock = look->aim.lock, .look_on = look->aim.look_on, .hips = look->hips,
                            .chest_yaw_change = look->chest_yaw_change, .chest_pitch_change = look->chest_pitch_change};
    return t5_aim_step(eye_joint(fighter->face.model_id), last, seen, aim_frame).aim;
}

static T5Mat4 then_turn(T5Mat4 matrix, void (*rotate)(T5Mat4 *, int32_t), int32_t steps) {
    T5Mat4 turned;
    t5_mat_identity(&turned);
    rotate(&turned, steps);
    t5_mat_multiply(&turned, &matrix);
    return turned;
}

// Rz(-90), the pitch about y, the yaw about x, Ry(+90); mixed over the face pose by weight / LOOK_WEIGHT_FULL.
static T5Mat4 eye_turn(T5Mat4 pose, T5AimState eyes, int32_t weight) {
    T5Mat4 aim;
    t5_mat_identity(&aim);
    aim = then_turn(aim, t5_mat_rotate_z, -QUARTER_TURN.bits);
    aim = then_turn(aim, t5_mat_rotate_y, t5_rad_to_angle_round(eyes.pitch));
    aim = then_turn(aim, t5_mat_rotate_x, t5_rad_to_angle_round(eyes.yaw));
    aim = then_turn(aim, t5_mat_rotate_y, QUARTER_TURN.bits);
    T5Vec4 aim_turn, pose_turn;
    t5_mat_to_quat(&aim_turn, &aim);
    t5_mat_to_quat(&pose_turn, &pose);
    t5_quat_blend(&aim_turn, (float)weight * (1.0f / (float)LOOK_WEIGHT_FULL), &pose_turn, &aim_turn);
    t5_quat_to_mat(&pose, &aim_turn);
    return pose;
}

// --- head tilt (0x1e3ce0): a face whose root turns sideways tips the head about its z

static const float TILT_LEAN_MIN = 0.1f;   // a root lean below this lets the tilt go
static const float TILT_LEAN_MAX = 0.4f;   // the lean that gives the most tilt
static const float TILT_RISE = 0.01f;      // radians a tick
static const float TILT_FALL = 0.005f;

static float tilt_step(float tilt, T5Vec4 root_turn) {
    T5Mat4 root;
    t5_mat_identity(&root);
    t5_quat_to_mat(&root, &root_turn);
    float lean = root.m[1][0];
    if (lean > TILT_LEAN_MAX) lean = TILT_LEAN_MAX;
    if (!(lean > TILT_LEAN_MIN)) return tilt - TILT_FALL < 0.0f ? 0.0f : tilt - TILT_FALL;
    float goal = lean - TILT_LEAN_MIN;
    if (goal >= tilt) return tilt + TILT_RISE > goal ? goal : tilt + TILT_RISE;
    return tilt - TILT_FALL < goal ? goal : tilt - TILT_FALL;
}

// --- the face of a fighter

T5Face t5_face_start(T5FaceBanks banks) {
    T5Face face = relax((T5Face){}, 0);
    return sample(face, banks);
}

T5Face t5_face_tick(T5Face face, T5FaceBanks banks, const T5ViewFighter *fighter, T5Phase phase) {
    if (fighter->face.move_started) face = move_face(face, &fighter->face);
    face = take_property(face, fighter->face.pose);
    face = step(face, banks, &fighter->face, phase);
    face = sample(face, banks);
    face.eyes = aim_eyes(face.eyes, fighter);
    face.tilt = tilt_step(face.tilt, face.pose.channel[0]);  // channel 0: the face root's turn
    return face;
}

T5Face t5_face_voice(T5Face face, const T5ViewFighter *fighter, T5Phase phase, uint16_t voice_face) {
    if (voice_face == VOICE_FACE_NONE) return face;
    if ((voice_face & VOICE_FACE_CLIP) == 0) {
        face.play = value_play((float)voice_face, VOICE_VALUE_BLEND);
        face.blink = voice_face == SHOUT_FACE ? SHOUT_HOLD : EFFORT_HOLD;
        return face;
    }
    int16_t character = fighter->face.character_id;
    if (holds_clip(phase) && character != KUMA && character != PANDA) return face;
    face.play = (T5FacePlay){0.0f, (uint16_t)((voice_face & FACE_CLIP_INDEX) + 1), VOICE_CLIP_BLEND};  // poses clip 0 is the values
    return face;
}

// (hole face-jaw-costumes :tags (tk5mod fighter-detail) :sev polish) costumes 0x53 and 0x54 reset the jaw bones A86, A87 to the model's bind after the face; which costumes these are is open, so every costume moves its jaw.
// Turns replace the bind rotation, moves the bind translation, scales scale the turned rows.
static void pose_face_bones(T5Rig *rig, const T5FacePose *pose) {
    for (int channel = 0; channel < FACE_CHANNELS; channel++) {
        T5Mat4 *local = &rig->bones_a[T5_FACE_CHANNELS[channel].bone].local;
        const T5Vec4 *value = &pose->channel[channel];
        switch (T5_FACE_CHANNELS[channel].kind) {
        case FACE_TURN: t5_quat_to_mat(local, value); break;
        case FACE_MOVE:
            for (int axis = 0; axis < 3; axis++) local->m[3][axis] = value->v[axis] * MOVE_SCALE;
            local->m[3][3] = 1.0f;
            break;
        case FACE_SCALE:
            for (int row = 0; row < 3; row++)
                for (int column = 0; column < 3; column++) local->m[row][column] *= value->v[row] * SIZE_SCALE;
            break;
        }
    }
}

// The head turns about its own z; B's head takes the turn rows.
static void tilt_head(T5Rig *rig, const T5ViewFighter *fighter, float tilt) {
    T5Mat4 turn;
    t5_mat_z_turn(&turn, -tilt);
    t5_mat_rotation_product(&rig->bones_a[BONE_HEAD].local, &rig->bones_a[BONE_HEAD].local, &turn);
    memcpy(rig->bones_b[BONE_HEAD].local.m, rig->bones_a[BONE_HEAD].local.m, sizeof rig->bones_a[BONE_HEAD].local.m[0] * 3);
    t5_skel_bone_world(rig, fighter->parent_a, BONE_HEAD);
    t5_skel_bone_world_b(rig, fighter->parent_b, BONE_HEAD);
}

void t5_face_pose_rig(T5Rig *rig, const T5Face *face, const T5ViewFighter *fighter) {
    pose_face_bones(rig, &face->pose);
    int32_t weight = fighter->look.weight;
    if (weight > 0) {
        rig->bones_a[RIGHT_EYE_BONE].local = eye_turn(rig->bones_a[RIGHT_EYE_BONE].local, face->eyes, weight);
        rig->bones_a[LEFT_EYE_BONE].local = eye_turn(rig->bones_a[LEFT_EYE_BONE].local, face->eyes, weight);
    }
    tilt_head(rig, fighter, face->tilt);
    for (int bone = FIRST_FACE_BONE; bone < FIRST_FACE_BONE + FACE_BONES; bone++)  // parents come first
        t5_skel_bone_world(rig, fighter->parent_a, bone);
}
