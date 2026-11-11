// Fighter skeleton: bone records, bind state, the skeleton build of motion step 13.
#ifndef T6_SKEL_H
#define T6_SKEL_H

#include <stdint.h>

#include "sim/anim.h"
#include "sim/vec.h"

#define T6_BONES_A 107  // skeleton A: bones 0..21 by body slot, 22..26 end points, then helpers
#define T6_BONES_B 27   // skeleton B: bones 0..26 of A; the hit code reads it
#define T6_POSE_BONES 22  // bones 0..21 of A: the ones the anim poses

// The port keeps the parent as an index in T6Skeleton (-1 = the root record).
typedef struct T6Bone { T6Mat4 local, world; } T6Bone;  // local: move and turn from parent; world: local * parent world

// Load-time data of one fighter: the bon tables in body slot order.
typedef struct {
    float scale;                     // bon scale
    int8_t parent_a[T6_BONES_A];  // parent slot of each A bone; -1 = the root record
    int8_t parent_b[T6_BONES_B];  // parent slot of each B bone; the spine and pelvis hang on the hips
    float euler[T6_BONES_A][3];      // bind rotation, radians (m = Rx Ry Rz)
    float translation[T6_BONES_A][3];  // bind translation
    float translation_b[T6_BONES_B][3];  // B's own bind translation (the bon values; A has bon 29, 30 at 15, 19)
} T6Skeleton;

// Bone records of one fighter.
typedef struct {
    T6Bone root;            // the parent of A[0] and B[0]; translation = base position
    T6Bone bones_a[T6_BONES_A];
    T6Bone bones_b[T6_BONES_B];
} T6Rig;

// `bon` is the raw section, little endian.
void t6_skeleton_load_a(T6Skeleton *skeleton, const uint8_t *bon);  // (tables, A records, scale)
void t6_skeleton_load_b(T6Skeleton *skeleton, const uint8_t *bon);  // (B records)
int t6_skeleton_parse(T6Skeleton *skeleton, T6Bytes file);  // both, from the bytes of a .t5b file; 0 on success
// The rig of the model load: identity turns, the bind translations, the root at the origin.
void t6_rig_load(T6Rig *rig, const T6Skeleton *skeleton);

// B takes the rotation rows of bones 0..26 of A; its translations stay.
void t6_rig_rotations_to_b(T6Rig *rig);

// Bind pose: A locals from the bind tables, worlds, B rotations from A, B worlds (part of the model init).
void t6_rig_bind(T6Rig *rig, const T6Skeleton *skeleton);

// Locals of bones 0..21 of A (or a copy of them) from the pose buffer: animated bones, the spine and chest
// frames, the fixed toes.
void t6_skel_pose(T6Bone *bones_a, const T6Skeleton *skeleton, const T6Vec4 pose[T6_CHANNELS]);

// world = local * parent world (VMX), in index order; parent -1 is `root`
void t6_skel_world(T6Bone *bones, const int8_t *parent, const T6Mat4 *root, int32_t count);
void t6_skel_world_a(T6Rig *rig, const T6Skeleton *skeleton);  // A worlds of bones 0..21
void t6_skel_bone_world(T6Rig *rig, const int8_t *parent_a, int32_t bone);  // world of one A bone from its parent's
void t6_skel_bone_world_b(T6Rig *rig, const int8_t *parent_b, int32_t bone);  // world of one B bone from its parent's
void t6_skel_world_b(T6Rig *rig, const T6Skeleton *skeleton);  // B worlds
// without the snapshots: root world = root local, A worlds of bones 0..26, then the face and finger
// bones 72, 57, 81, 86, 95, 104 (their parents are computed before them).
void t6_skel_world_a_extra(T6Rig *rig, const T6Skeleton *skeleton);

#endif
