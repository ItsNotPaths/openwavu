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
enum : uint16_t { FACE_VALUE_PROPERTY = T6_PROPERTY_BASE + 0x157, FACE_CLIP_PROPERTY = T6_PROPERTY_BASE + 0x158, VALUE_UNIT = 256 };

enum { KUMA = 11, PANDA = 32 };  // their voices start face clips in any phase

static const float SAME_TIME = 1e-5f;  // times closer than this count as equal
static const float PLAY_RATE = (float)PLAY_SPEED / CLOCK_PER_FRAME;  // clip frames a tick

// --- what the face plays

static T6FacePlay value_play(float value, uint16_t blend_frames) { return (T6FacePlay){value, 0, blend_frames}; }

static bool plays_clip(T6FacePlay play) { return play.clip != 0; }

static const T6ClipBank *bank_of(const T6FaceBanks *banks, T6FacePlay play) {
    return (play.clip & FACE_CLIP_BANK) ? &banks->clips : &banks->poses;
}

static float clip_length(const T6FaceBanks *banks, T6FacePlay play) {
    return (float)t6_clip_frames(bank_of(banks, play), play.clip & FACE_CLIP_INDEX);
}

// After the match a clip stops on its last frame: the win pose keeps its face.
static bool holds_clip(T6Phase phase) { return phase == T6_PHASE_NONE || phase == T6_PHASE_MATCH_END || phase == T6_PHASE_OVER; }

static int16_t blink_gap(void) { return (int16_t)(rand() % BLINK_GAP_MAX); }

static T6Face relax(T6Face face, uint16_t blend_frames) {
    face.play = value_play(NEUTRAL_FACE, blend_frames);
    face.blink = blink_gap();
    return face;
}

// The face a new move sets, unless a clip plays.
static T6Face move_face(T6Face face, const T6ViewFace *fighter) {
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
static T6Face take_property(T6Face face, T6PoseProp property) {
    bool fresh = property.id != face.seen.id || property.value != face.seen.value || property.set_frame != face.seen.set_frame;
    face.seen = property;
    if (!fresh) return face;
    if (property.id == FACE_VALUE_PROPERTY) face.play = value_play((float)(property.value / VALUE_UNIT), property.value % VALUE_UNIT);
    if (property.id == FACE_CLIP_PROPERTY) face.play = (T6FacePlay){0.0f, property.value, PROPERTY_CLIP_BLEND};
    return face;
}

// The clip clock, then, while no clip plays and no property posed the face, the effort face and the blinks.
static T6Face step(T6Face face, const T6FaceBanks *banks, const T6ViewFace *fighter, T6Phase phase) {
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

static bool same_play(T6FacePlay first, T6FacePlay second) {
    return fabsf(first.time - second.time) < SAME_TIME && first.clip == second.clip && first.blend_frames == second.blend_frames;
}

// The target a 1 / blend_frames step from the last pose. The game samples only when the play changed.
static T6Face sample(T6Face face, const T6FaceBanks *banks) {
    if (face.has_sample && same_play(face.sampled, face.play)) return face;
    T6FacePose target = t6_face_clip_sample(bank_of(banks, face.play), face.play.clip & FACE_CLIP_INDEX, face.play.time);
    if (face.has_sample && face.play.blend_frames > 0) target = t6_face_pose_blend(&banks->poses, face.pose, target, 1.0f / face.play.blend_frames);
    face.pose = target;
    face.sampled = face.play;
    face.has_sample = true;
    return face;
}

// --- the face of a fighter

T6Face t6_face_start(const T6FaceBanks *banks) {
    T6Face face = relax((T6Face){}, 0);
    return sample(face, banks);
}

T6Face t6_face_tick(T6Face face, const T6FaceBanks *banks, const T6ViewFighter *fighter, T6Phase phase) {
    if (fighter->face.move_started) face = move_face(face, &fighter->face);
    face = take_property(face, fighter->face.pose);
    face = step(face, banks, &fighter->face, phase);
    return sample(face, banks);
}

T6Face t6_face_voice(T6Face face, const T6ViewFighter *fighter, T6Phase phase, uint16_t voice_face) {
    if (voice_face == VOICE_FACE_NONE) return face;
    if ((voice_face & VOICE_FACE_CLIP) == 0) {
        face.play = value_play((float)voice_face, VOICE_VALUE_BLEND);
        face.blink = voice_face == SHOUT_FACE ? SHOUT_HOLD : EFFORT_HOLD;
        return face;
    }
    int16_t character = fighter->face.character_id;
    if (holds_clip(phase) && character != KUMA && character != PANDA) return face;
    face.play = (T6FacePlay){0.0f, (uint16_t)((voice_face & FACE_CLIP_INDEX) + 1), VOICE_CLIP_BLEND};  // poses clip 0 is the values
    return face;
}

// Rotations replace the bind rotation, translations the bind translation.
void t6_face_locals(T6Mat4 locals[FACE_JOINTS], const T6Face *face, const T6FaceBanks *banks) {
    const T6ClipBank *bank = &banks->poses;
    for (int joint = 0; joint < FACE_JOINTS; joint++) {
        if ((uint32_t)(FIRST_FACE_JOINT + joint) < bank->joint_count) locals[joint] = bank->joints[FIRST_FACE_JOINT + joint].bind;
        else t6_mat_identity(&locals[joint]);
    }
    for (uint32_t track = 0; track < bank->track_count; track++) {
        int joint = bank->tracks[track].joint - FIRST_FACE_JOINT;
        if (joint < 0 || joint >= FACE_JOINTS) continue;
        const T6Vec4 *value = &face->pose.track[track];
        if (bank->tracks[track].path == CLIP_ROTATION) t6_quat_to_mat(&locals[joint], value);
        if (bank->tracks[track].path == CLIP_TRANSLATION)
            for (int axis = 0; axis < 3; axis++) locals[joint].m[3][axis] = value->v[axis];
    }
}
