// Clip banks: display-only bone clips (fingers, faces) from a glTF file (src/convert/clips.odin) named by the pack db's
// clip_bank row. Keys point into the caller's file bytes, which must outlive the bank.
#ifndef T5_VISUAL_CLIP_BANK_H
#define T5_VISUAL_CLIP_BANK_H

#include <stdint.h>

#include "load.h"
#include "sim/vec.h"

typedef enum : uint8_t { CLIP_ROTATION, CLIP_TRANSLATION, CLIP_SCALE } T5ClipPath;

typedef struct {
    uint16_t joint;  // the glb joint: node "bone<joint>"
    T5ClipPath path;
} T5ClipTrack;

typedef struct {
    uint32_t track_count, clip_count;
    T5ClipTrack *tracks;     // the same in every clip
    uint16_t *frame_counts;  // per clip
    const float **keys;      // [clip][track]: one key a frame, 4 floats a rotation, 3 a translation or scale
} T5ClipBank;

// No row: an empty bank, not a failure. Returns NULL on success, else what went wrong.
const char *t5_load_clip_bank(T5ClipBank *bank, sqlite3 *db, const char *owner, T5ReadFile read, void *context);
void t5_free_clip_bank(T5ClipBank *bank);

int32_t t5_clip_track(const T5ClipBank *bank, uint16_t joint, T5ClipPath path);  // -1: no such track
uint16_t t5_clip_frames(const T5ClipBank *bank, uint16_t clip);  // a clip past the end reads clip 0; 0: an empty bank
// A track's key at a frame clamped to the clip: a rotation as the sim's turn, a translation in mm, a scale.
T5Vec4 t5_clip_key(const T5ClipBank *bank, uint16_t clip, uint32_t track, int32_t frame);

#endif
