// Face banks: the face clips from .anim files (layout tk5face), loaded from the pack db, and their sampler.
// Views of caller-owned bytes.
#ifndef T6_VISUAL_FACE_BANK_H
#define T6_VISUAL_FACE_BANK_H

#include <stdbool.h>
#include <stdint.h>

#include "load.h"
#include "sim/memory.h"
#include "sim/vec.h"

enum {
    FACE_CHANNELS = 38,
    FIRST_FACE_BONE = 81,  // A bones 81..106: the face root, then the eyes, lids, cheeks, lips and jaw
    FACE_BONES = 26,
};

typedef enum : uint8_t { FACE_TURN, FACE_MOVE, FACE_SCALE } T6FaceChannelKind;

typedef struct {
    uint8_t bone;  // A bone
    T6FaceChannelKind kind;
} T6FaceChannel;

// Channel i poses its bone: a turn replaces the bind rotation, a move the bind translation, a scale scales the rows of
// the turn. A bone's turn comes before its scale.
extern const T6FaceChannel T6_FACE_CHANNELS[FACE_CHANNELS];

// Per channel: a turn as a quaternion; a move (bon units) or a scale (1.0 = as is) in x, y, z.
typedef struct { T6Vec4 channel[FACE_CHANNELS]; } T6FacePose;

// Per frame, per channel: a turn as (axis pitch, axis yaw, angle) in radians; a move or a scale as decoded.
typedef float T6FaceKeys[FACE_CHANNELS][3];

typedef struct {
    uint16_t frame_count;
    const T6FaceKeys *keys;  // NULL: no clip, every frame is zeros
} T6FaceClip;

typedef struct {
    uint32_t clip_count;
    T6FaceClip *clips;
} T6FaceBank;

// The two banks of a character: the poses (clip 0, frame i = face value i; then the voice faces) and the intro and win
// faces (none for some characters).
typedef struct { T6FaceBank poses, clips; } T6FaceBanks;

// The face poses and clips of the character (owners <character>/face_poses, <its anim bank>/face_clips).
const char *t6_load_faces_storage(sqlite3 *db, const char *character, size_t *bytes);  // arena bytes t6_load_faces takes
const char *t6_load_faces(T6FaceBanks *banks, sqlite3 *db, const char *character, T6ReadFile read, void *context, T6Arena *arena);

uint16_t t6_face_clip_frames(T6FaceBank bank, uint16_t clip);  // frame count; a clip past the end reads clip 0
// Frame floor(time) and the next mixed by the fraction (turns shortest arc, not normalized). A clip past the end reads clip 0.
T6FacePose t6_face_clip_sample(T6FaceBank bank, uint16_t clip, float time);
// From `from` toward `to` by weight: turns shortest arc, moves and scales straight.
T6FacePose t6_face_pose_blend(T6FacePose from, T6FacePose to, float weight);

#endif
