// Clip banks: display-only bone clips (fingers, faces) from a glTF file (src/convert/clips.odin) named by the pack db's
// clip_bank row. Keys point into the caller's file bytes, which must outlive the bank.
#ifndef T6_VISUAL_CLIP_BANK_H
#define T6_VISUAL_CLIP_BANK_H

#include <stdint.h>

#include "load.h"
#include "sim/vec.h"

typedef enum : uint8_t { CLIP_ROTATION, CLIP_TRANSLATION, CLIP_SCALE } T6ClipPath;

typedef struct {
    uint16_t joint;  // the glb joint: node "bone<joint>"
    T6ClipPath path;
} T6ClipTrack;

typedef struct {
    int16_t parent;  // joint, -1: none
    T6Mat4 bind;     // the local bind pose as the sim keeps a local: rotation rows, translation (mm) in row 3
} T6ClipJoint;

typedef struct {
    uint32_t track_count, clip_count;
    T6ClipTrack *tracks;     // the same in every clip
    uint16_t *frame_counts;  // per clip
    const float **keys;      // [clip][track]: one key a frame, 4 floats a rotation, 3 a translation or scale
    uint32_t joint_count;
    T6ClipJoint *joints;     // the file's bone tree, by joint
} T6ClipBank;

// No row: an empty bank, not a failure. Returns NULL on success, else what went wrong.
const char *t6_load_clip_bank(T6ClipBank *bank, sqlite3 *db, const char *owner, T6ReadFile read, void *context);
void t6_free_clip_bank(T6ClipBank *bank);

int32_t t6_clip_track(const T6ClipBank *bank, uint16_t joint, T6ClipPath path);  // -1: no such track
uint16_t t6_clip_frames(const T6ClipBank *bank, uint16_t clip);  // a clip past the end reads clip 0; 0: an empty bank
// A track's key at a frame clamped to the clip: a rotation as the sim's turn, a translation in mm, a scale.
T6Vec4 t6_clip_key(const T6ClipBank *bank, uint16_t clip, uint32_t track, int32_t frame);

#endif
