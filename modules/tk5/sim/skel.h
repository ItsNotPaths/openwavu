// Fighter skeleton: bone records, bind state, the skeleton build of motion step 13 (data.md §6.1).
#ifndef T5_SKEL_H
#define T5_SKEL_H

#include <stdint.h>

#include "sim/anim.h"
#include "sim/vec.h"

#define T5_BONES_A 107  // skeleton A: bones 0..21 by body slot, 22..26 end points, then helpers
#define T5_BONES_B 27   // skeleton B: bones 0..26 of A; the hit code reads it
#define T5_POSE_BONES 22  // bones 0..21 of A: the ones the anim poses

// The port keeps the parent as an index in T5Skeleton (-1 = the root record).
typedef struct T5Bone { T5Mat4 local, world; } T5Bone;  // local: move and turn from parent; world: local * parent world

// Load-time data of one fighter: the bon tables in body slot order.
typedef struct {
    float scale;                     // bon scale
    int8_t parent_a[T5_BONES_A];  // parent slot of each A bone; -1 = the root record
    int8_t parent_b[T5_BONES_B];  // parent slot of each B bone; the spine and pelvis hang on the hips
    float euler[T5_BONES_A][3];      // bind rotation, radians (m = Rx Ry Rz)
    float translation[T5_BONES_A][3];  // bind translation
    float translation_b[T5_BONES_B][3];  // B's own bind translation (the bon values; A has bon 29, 30 at 15, 19)
} T5Skeleton;

// Bone records of one fighter.
typedef struct {
    T5Bone root;            // the parent of A[0] and B[0]; translation = base position
    T5Bone bones_a[T5_BONES_A];
    T5Bone bones_b[T5_BONES_B];
} T5Rig;

// `bon` is the raw section (tools/bon2bin.py), little endian.
void t5_skeleton_load_a(T5Skeleton *skeleton, const uint8_t *bon);  // (tables, A records, scale)
void t5_skeleton_load_b(T5Skeleton *skeleton, const uint8_t *bon);  // (B records)
int t5_skeleton_parse(T5Skeleton *skeleton, T5Bytes file);  // both, from the bytes of a .t5b file; 0 on success
// The rig of the model load: identity turns, the bind translations, the root at the origin.
void t5_rig_load(T5Rig *rig, const T5Skeleton *skeleton);

// B takes the rotation rows of bones 0..26 of A; its translations stay.
void t5_rig_rotations_to_b(T5Rig *rig);

// Bind pose: A locals from the bind tables, worlds, B rotations from A, B worlds (part of the model init).
void t5_rig_bind(T5Rig *rig, const T5Skeleton *skeleton);

// Locals of bones 0..21 of A (or a copy of them) from the pose buffer: animated bones, the spine and chest
// frames, the fixed toes.
void t5_skel_pose(T5Bone *bones_a, const T5Skeleton *skeleton, const T5Vec4 pose[T5_CHANNELS]);

// world = local * parent world (VMX), in index order; parent -1 is `root`
void t5_skel_world(T5Bone *bones, const int8_t *parent, const T5Mat4 *root, int32_t count);
void t5_skel_world_a(T5Rig *rig, const T5Skeleton *skeleton);  // A worlds of bones 0..21
void t5_skel_bone_world(T5Rig *rig, const int8_t *parent_a, int32_t bone);  // world of one A bone from its parent's
void t5_skel_bone_world_b(T5Rig *rig, const int8_t *parent_b, int32_t bone);  // world of one B bone from its parent's
void t5_skel_world_b(T5Rig *rig, const T5Skeleton *skeleton);  // B worlds
// without the snapshots: root world = root local, A worlds of bones 0..26, then the face and finger
// bones 72, 57, 81, 86, 95, 104 (their parents are computed before them).
void t5_skel_world_a_extra(T5Rig *rig, const T5Skeleton *skeleton);

#endif
