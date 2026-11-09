// The visual part: display-only fighter animation on a copy of each fighter's skeleton. Outside rollback: it reads the
// sim view once per displayed frame, keeps its own state (never rewound) and never writes the sim.
#ifndef T5_VISUAL_H
#define T5_VISUAL_H

#include <stdbool.h>
#include <stdint.h>

#include "gamerender/face.h"
#include "gamerender/hands.h"

enum {
    FIRST_FINGER_BONE = 51,  // A bones 51..65 the right fingers, 66..80 the left, each in hand bank joint order
    FINGER_BONES = 2 * FINGER_JOINTS,  // both hands: right, then left
};

typedef struct { T5Vec4 turn[FINGER_BONES]; } T5FingerBones;  // one rotation per finger bone

typedef struct {  // one fighter's visual state
    T5HandBanks banks;       // caller-owned; no banks (zero): the fingers keep the sim's pose
    T5Hands hands;
    T5FaceBanks faces;       // caller-owned; no banks (zero): the face keeps the sim's pose
    T5Face face;
    T5FingerBones from, shown;  // the display blend: from the pose shown at the newest tick to the tick's pose
    T5Rig rig;               // the sim's skeleton with the fingers and face posed: what the renderer draws
} T5VisualFighter;

typedef struct {  // all fighters' visual state
    T5VisualFighter fighter[T5_FIGHTER_COUNT];  // one per fighter slot
    bool started;            // a zeroed visual starts fresh from the next view
    uint32_t frame;          // world frame of the newest tick
    float since_tick;        // display seconds since the newest tick
} T5Visual;

// A replay seek: start fresh from the next view. The banks stay.
void t5_visual_reset(T5Visual *visual);
// One displayed frame, `seconds` after the last: one tick per new sim frame of the view, then the display blend.
void t5_visual_step(T5Visual *visual, const T5View *view, float seconds);
// A voice of `side` started with this voice row face (VOICE_FACE_NONE: none): it sets the face.
void t5_visual_voice_face(T5Visual *visual, const T5View *view, int side, uint16_t voice_face);

#endif
