// Face banks: the face clips of a character (clip banks, gamerender/clip_bank.h, data.md 6.5) and their sampler.
#ifndef T5_VISUAL_FACE_BANK_H
#define T5_VISUAL_FACE_BANK_H

#include <stdint.h>

#include "gamerender/clip_bank.h"

enum {
    FACE_TRACKS_MAX = 64,
    FIRST_FACE_BONE = 81,  // A bones 81..106: the face root, then the eyes, lids, cheeks, lips and jaw
    FACE_BONES = 26,
    FACE_ROOT_JOINT = 85,  // glb joint = A bone + JOINT_OFFSET
    JOINT_OFFSET = 4,
};

// One key per track of the banks: a rotation as the sim's turn, a translation in mm, a scale.
typedef struct { T5Vec4 track[FACE_TRACKS_MAX]; } T5FacePose;

// The two banks of a character, on the same tracks: the poses (clip 0, frame i = face value i; then the voice faces) and
// the intro and win faces (none for some characters).
typedef struct { T5ClipBank poses, clips; } T5FaceBanks;

// The face poses and clips of the character (owners <character>/face_poses, <its anim bank>/face_clips).
const char *t5_load_faces(T5FaceBanks *banks, sqlite3 *db, const char *character, T5ReadFile read, void *context);
void t5_free_faces(T5FaceBanks *banks);

// Frame floor(time) and the next mixed by the fraction (turns shortest arc, not normalized). A clip past the end reads clip 0.
T5FacePose t5_face_clip_sample(const T5ClipBank *bank, uint16_t clip, float time);
// From `from` toward `to` by weight: turns shortest arc, moves and scales straight.
T5FacePose t5_face_pose_blend(const T5ClipBank *bank, T5FacePose from, T5FacePose to, float weight);

#endif
