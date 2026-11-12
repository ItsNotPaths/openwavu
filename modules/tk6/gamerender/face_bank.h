// Face banks: the face clips of a character (clip banks, gamerender/clip_bank.h) and their sampler.
#ifndef T6_VISUAL_FACE_BANK_H
#define T6_VISUAL_FACE_BANK_H

#include <stdint.h>

#include "gamerender/clip_bank.h"

enum {
    FACE_TRACKS_MAX = 96,
    FIRST_FACE_JOINT = 108,  // glb joints 108..147 (BONE records 107..146): brows, eyes, lids, lips, jaw, tongue, cheeks
    FACE_JOINTS = 40,
};

// One key per track of the banks: a rotation as the sim's turn, a translation in mm, a scale.
typedef struct { T6Vec4 track[FACE_TRACKS_MAX]; } T6FacePose;

// The two banks of a character, on the same tracks: the poses (clip 0, frame i = face value i; then the voice faces) and
// the intro and win faces (none for some characters).
typedef struct { T6ClipBank poses, clips; } T6FaceBanks;

// The face poses and clips of the character (owners <character>/face_poses, <its anim bank>/face_clips).
const char *t6_load_faces(T6FaceBanks *banks, sqlite3 *db, const char *character, T6ReadFile read, void *context);
void t6_free_faces(T6FaceBanks *banks);

// Frame floor(time) and the next mixed by the fraction (turns shortest arc, not normalized). A clip past the end reads clip 0.
T6FacePose t6_face_clip_sample(const T6ClipBank *bank, uint16_t clip, float time);
// From `from` toward `to` by weight: turns shortest arc, moves and scales straight.
T6FacePose t6_face_pose_blend(const T6ClipBank *bank, T6FacePose from, T6FacePose to, float weight);

#endif
