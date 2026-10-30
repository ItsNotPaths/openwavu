// Body animation: banks, the key decoder and the samplers (data.md §5, §6.2).
#ifndef T5_ANIM_H
#define T5_ANIM_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/memory.h"
#include "sim/vec.h"

#define T5_CHANNELS 23
#define T5_KEY_HOLD 99  // T5KeyMode.bits of the hold code

// The channels of a fighter pose. Three are positions (the root, the hip and a point of the trunk frame), the others rotations
// (quaternions after the sampler); channels 3.. turn the bones (CHANNEL_SLOT in skel.c). The decoder tests the index, not the
// bone types.
enum T5Channel { CHANNEL_ROOT, CHANNEL_HIP, CHANNEL_ROOT_YAW, CHANNEL_HIPS, CHANNEL_SPINE, CHANNEL_PELVIS, CHANNEL_TRUNK_POINT };
static inline bool t5_channel_is_rotation(int32_t channel) { return channel != CHANNEL_ROOT && channel != CHANNEL_HIP && channel != CHANNEL_TRUNK_POINT; }

// One anim as the decoder reads it, from the file bytes (little endian, not swapped).
typedef struct {
    bool ready;               // bit 7, set by the bank swap; else the decoder writes zeros
    uint16_t frame_count;
    uint8_t rotation_shift;   // low 7 bits
    int8_t position_shift;    // bit shift of the decoded position keys, applied before position_scale
    float position_scale[3];  // the position channels in order
    union { int16_t rotation[3]; float position[3]; } base[T5_CHANNELS];  // frame 0
    const uint8_t *blocks;    // u32 offsets of the 16-frame blocks, from this table
} T5Anim;

typedef struct {
    const uint8_t *data;      // the raw bank, caller-owned: the anims point into it
    uint16_t anim_count;
    T5Anim *anims;  // anim_count + 1 entries; the last one stays zero
} T5AnimBank;

// Two anims are one record when the bank gives two ids the same offset: the game compares pointers.
bool t5_anim_same(const T5Anim *first, const T5Anim *second);

// Bank bytes of tools/anim2bin.py. The anims go into the arena; `in` must outlive the bank.
int32_t t5_anim_bank_count(T5Bytes file);  // -1 if the bank is bad
static inline size_t t5_anim_bank_bytes(uint32_t anim_count) { return (anim_count + 1) * sizeof(T5Anim); }  // arena bytes: the anims and a zero one
int t5_anim_bank_parse(T5AnimBank *bank, T5Bytes file, T5Arena *arena);  // 0 on success

// Delta mode of the key stream. It carries over between fields and between decoder calls
typedef struct { int32_t bits, offset; } T5KeyMode;  // bits read per delta, plus offset

// out[ch] = (x, y, z) for ch < count <= T5_CHANNELS: position, or rotation as (axis pitch, axis yaw,
// angle) in radians. w is not written. Real banks never read the incoming mode (no field starts with a run).
void t5_anim_decode(T5KeyMode *mode, const T5Anim *anim, T5Vec4 *out, int32_t frame, int32_t count);

// Fighter samplers (object kind 0). Rotations come out as quaternions,
// positions blend linearly between frames, and z of channels 0 and 1 is negated.
void t5_anim_sample(T5KeyMode *mode, const T5Anim *anim, float frame, T5Vec4 pose[T5_CHANNELS],
                    bool keep_hips);  // keep_hips false: the hips are leveled
// Root yaw key (channel 2) of a fighter. Decodes channels 0..2 only.
void t5_anim_sample_yaw(T5KeyMode *mode, const T5Anim *anim, float frame, T5Vec4 *turn);
// Root and hip positions only (channels 0, 1), blended linearly between frames.
void t5_anim_sample_root(T5KeyMode *mode, const T5Anim *anim, float frame, T5Vec4 root[2]);

// Hips keep only the root yaw (about -y); spine and pelvis take the rest. Only when the hips are within 45 deg of upright.
void t5_pose_level_hips(T5Vec4 pose[T5_CHANNELS]);

// root[0], root[1]: x, z *= scale_xz + scale_xz_add, y *= scale_y
void t5_pose_scale_root(T5Vec4 root[2], float scale_xz, float scale_xz_add, float scale_y);

#endif
