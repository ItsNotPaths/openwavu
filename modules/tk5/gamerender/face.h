// The face of a fighter (code-map "Face"): the face values and clips that moves, properties and voices set, the blinks,
// the low pass toward each new pose, the eyes' aim and the head tilt of a wide face. Display only: reads the sim view, the
// sim never reads this.
#ifndef T5_VISUAL_FACE_H
#define T5_VISUAL_FACE_H

#include <stdbool.h>
#include <stdint.h>

#include "gamerender/face_bank.h"
#include "view.h"

// What the face plays: a face value (clip 0, time = the value) or a clip.
typedef struct {
    float time;             // face value, or the clip frame
    uint16_t clip;          // 0: a face value; else clip & FACE_CLIP_INDEX of the poses, or of the clips with FACE_CLIP_BANK
    uint16_t blend_frames;  // the low pass steps 1 / blend_frames of the way to the target
} T5FacePlay;

enum : uint16_t { FACE_CLIP_BANK = 0x4000, FACE_CLIP_INDEX = 0x3fff };
enum : uint16_t { VOICE_FACE_CLIP = 0x4000, VOICE_FACE_NONE = 0xffff };  // a voice row's face: clip flag, or none

typedef struct {
    T5FacePlay play;     // what the face plays now
    T5FacePlay sampled;  // what the last sample played: the same again keeps `pose`
    bool has_sample;     // false until the first sample
    int16_t blink;       // ticks to the next blink, or to the end of a blink or a face
    T5FacePose pose;     // the pose of the last tick, where the next low pass starts
    T5PoseProp seen;     // the face property of the last tick: a new one sets the face
    T5AimState eyes;     // the eyes' turn toward the opponent
    float tilt;          // radians the head tips by a wide face
} T5Face;

// The neutral face at once (a reset, a round start).
T5Face t5_face_start(const T5FaceBanks *banks);
// One sim tick, after the sim step: the move start, the face property, the clock, the blinks, the sample, the eyes, the tilt.
T5Face t5_face_tick(T5Face face, const T5FaceBanks *banks, const T5ViewFighter *fighter, T5Phase phase);
// The face of a voice row that starts (0xa0d5c): a face clip of the poses with VOICE_FACE_CLIP, else a face value. The newest
// voice wins.
T5Face t5_face_voice(T5Face face, const T5ViewFighter *fighter, T5Phase phase, uint16_t voice_face);
// Writes the face bones, the eyes and the head tilt into the rig, and rebuilds the worlds they move.
void t5_face_pose_rig(T5Rig *rig, const T5Face *face, const T5ViewFighter *fighter, const T5FaceBanks *banks);

#endif
