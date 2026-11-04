// Body animation: anims from .anim files and the samplers (data.md §6.2).
#ifndef T5_ANIM_H
#define T5_ANIM_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/memory.h"
#include "sim/vec.h"

#define T5_CHANNELS 23

// The channels of a fighter pose. Three are positions (the root, the hip and a point of the trunk frame), the others rotations
// (quaternions after the sampler); channels 3.. turn the bones (CHANNEL_SLOT in skel.c). The samplers test the index, not the
// bone types.
enum T5Channel { CHANNEL_ROOT, CHANNEL_HIP, CHANNEL_ROOT_YAW, CHANNEL_HIPS, CHANNEL_SPINE, CHANNEL_PELVIS, CHANNEL_TRUNK_POINT };
static inline bool t5_channel_is_rotation(int32_t channel) { return channel != CHANNEL_ROOT && channel != CHANNEL_HIP && channel != CHANNEL_TRUNK_POINT; }

// Per frame, per channel: position, or rotation as (axis pitch, axis yaw, angle) in radians.
typedef float T5AnimKeys[T5_CHANNELS][3];

// One anim: the keys of a .anim file, caller-owned. Two anims are one record when they share their keys: the game compares
// pointers.
typedef struct {
    uint16_t frame_count;
    const T5AnimKeys *keys;  // NULL: no anim, every frame is zeros
} T5Anim;

typedef struct {
    uint32_t anim_count;
    T5Anim *anims;  // anim_count + 1 entries; the last one stays zero
} T5AnimBank;

bool t5_anim_same(const T5Anim *first, const T5Anim *second);

int t5_anim_parse(T5Anim *anim, T5Bytes file);  // checks the tk5 layout; the anim points into `file`; 0 on success
// The kind of a .anim channel (src/convert/anim.odin).
typedef enum : uint8_t { T5_KEY_POSITION = 1, T5_KEY_AXIS_ANGLE = 3, T5_KEY_VALUES = 4 } T5KeyKind;
static inline T5KeyKind t5_channel_kind(int32_t channel) { return t5_channel_is_rotation(channel) ? T5_KEY_AXIS_ANGLE : T5_KEY_POSITION; }

// A .anim file of this layout (at most 8 chars) and channel count, 3 components per key, each channel of kind_of's kind.
// Returns the frame count, *keys pointing into `file`; 0 when the file is not such an anim or has no frames.
uint16_t t5_anim_file(T5Bytes file, const char *layout, int32_t channels, T5KeyKind (*kind_of)(int32_t), const float **keys);
// A key (axis pitch, axis yaw, angle) as a turn: axis = row 2 of RotY(yaw) then RotX(pitch) on the matrix stack.
void t5_anim_key_turn(T5Vec4 *turn, const T5Vec4 *key);
// out[channel] = (x, y, z) keys of channels 0..count-1 at `frame`, clamped to the anim. No anim: zeros. w is not written.
void t5_anim_keys(const T5Anim *anim, T5Vec4 *out, int32_t frame, int32_t count);

// Fighter samplers (object kind 0). Rotations come out as quaternions,
// positions blend linearly between frames, and z of channels 0 and 1 is negated.
void t5_anim_sample(const T5Anim *anim, float frame, T5Vec4 pose[T5_CHANNELS],
                    bool keep_hips);  // keep_hips false: the hips are leveled
// Root yaw key (channel 2) of a fighter. Reads channels 0..2 only.
void t5_anim_sample_yaw(const T5Anim *anim, float frame, T5Vec4 *turn);
// Root and hip positions only (channels 0, 1), blended linearly between frames.
void t5_anim_sample_root(const T5Anim *anim, float frame, T5Vec4 root[2]);

// Hips keep only the root yaw (about -y); spine and pelvis take the rest. Only when the hips are within 45 deg of upright.
void t5_pose_level_hips(T5Vec4 pose[T5_CHANNELS]);

// root[0], root[1]: x, z *= scale_xz + scale_xz_add, y *= scale_y
void t5_pose_scale_root(T5Vec4 root[2], float scale_xz, float scale_xz_add, float scale_y);

#endif
