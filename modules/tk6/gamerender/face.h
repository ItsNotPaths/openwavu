// The face of a fighter: the face values and clips that moves, properties and voices set, the blinks and
// the low pass toward each new pose. Display only: reads the sim view, the sim never reads this.
// (hole tk6-face-eyes :tags (tk6 fighter-detail) :sev polish) the eyes do not turn toward the opponent: TK6's eye look-at is not traced, and the eyes are face joints the sim does not hold.
// (hole tk6-head-tilt :tags (tk6 fighter-detail) :sev polish) a wide face does not tip the head: TK6 faces have no face-root channel, where its tilt comes from is open.
#ifndef T6_VISUAL_FACE_H
#define T6_VISUAL_FACE_H

#include <stdbool.h>
#include <stdint.h>

#include "gamerender/face_bank.h"
#include "view.h"

// What the face plays: a face value (clip 0, time = the value) or a clip.
typedef struct {
    float time;             // face value, or the clip frame
    uint16_t clip;          // 0: a face value; else clip & FACE_CLIP_INDEX of the poses, or of the clips with FACE_CLIP_BANK
    uint16_t blend_frames;  // the low pass steps 1 / blend_frames of the way to the target
} T6FacePlay;

enum : uint16_t { FACE_CLIP_BANK = 0x4000, FACE_CLIP_INDEX = 0x3fff };
enum : uint16_t { VOICE_FACE_CLIP = 0x4000, VOICE_FACE_NONE = 0xffff };  // a voice row's face: clip flag, or none

typedef struct {
    T6FacePlay play;     // what the face plays now
    T6FacePlay sampled;  // what the last sample played: the same again keeps `pose`
    bool has_sample;     // false until the first sample
    int16_t blink;       // ticks to the next blink, or to the end of a blink or a face
    T6FacePose pose;     // the pose of the last tick, where the next low pass starts
    T6PoseProp seen;     // the face property of the last tick: a new one sets the face
} T6Face;

// The neutral face at once (a reset, a round start).
T6Face t6_face_start(const T6FaceBanks *banks);
// One sim tick, after the sim step: the move start, the face property, the clock, the blinks, the sample.
T6Face t6_face_tick(T6Face face, const T6FaceBanks *banks, const T6ViewFighter *fighter, T6Phase phase);
// The face of a voice row that starts: a face clip of the poses with VOICE_FACE_CLIP, else a face value. The newest
// voice wins.
T6Face t6_face_voice(T6Face face, const T6ViewFighter *fighter, T6Phase phase, uint16_t voice_face);
// The face joints' local matrices (glb joints FIRST_FACE_JOINT on), as the sim keeps a local.
void t6_face_locals(T6Mat4 locals[FACE_JOINTS], const T6Face *face, const T6FaceBanks *banks);

#endif
