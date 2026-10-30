// Presentation out of the sim (openwavu ws.md, two tiers): one-shot cues of move properties and the pose properties of a
// move. The presenter plays both; neither feeds back into the sim.
#ifndef T5_CUE_H
#define T5_CUE_H

#include <stdint.h>

#include "sim/motbin.h"
#include "sim/phase.h"

// T5_CUE_NONE: no cue, the sim handles the property.
typedef enum : uint8_t { T5_CUE_NONE, T5_CUE_FX, T5_CUE_SOUND, T5_CUE_VOICE, T5_CUE_CAMERA } T5CueKind;

// The list of a move a property fires from.
typedef enum : uint8_t {
    T5_FROM_CALL,          // a direct call (tests, harnesses)
    T5_FROM_FRAMES,        // the per-frame list
    T5_FROM_START,         // the start list
    T5_FROM_END,           // the end property
    T5_FROM_CANCEL,        // the instant properties of a cancel
    T5_FROM_GROUP_CANCEL,  // the instant properties of a group cancel
} T5PropSource;

// Names one firing: the same state gives the same key, so a resimulated frame repeats it. entry: the place of the property
// in its table of the move set (properties, start properties or requirements).
typedef struct {
    T5Who side;  // the firing fighter; T5_NOBODY for an extra
    T5PropSource source;
    T5Ref move;  // the fighter's move as it fires
    int32_t entry;
} T5CueKey;

// id and value are the property's. An effect's anchor is the low byte of the value: a joint below 108, else a special point.
typedef struct {
    T5CueKind kind;
    uint16_t id, value;
    T5Who owner;  // whose voice bank, body or slot it plays on: the firing fighter, its target, or T5_NOBODY (common bank, screen)
    T5CueKey key;
} T5Cue;

// A null cue sends nothing.
typedef struct {
    void (*cue)(void *context, T5Cue cue);  // called once per cue sent
    void *context;
} T5CueHooks;

// The last pose property of a layer (a hand shape, a face); it lasts until the next one or a round reset. Zero: none.
typedef struct {
    uint16_t id, value;
    uint32_t set_frame;  // world frame of the last set: a repeat of the same pose restarts the layer
} T5PoseProp;

#endif
