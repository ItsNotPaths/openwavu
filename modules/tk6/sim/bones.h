// Skeleton A slots, the same for every character.
#ifndef T6_BONES_H
#define T6_BONES_H

#include <stdint.h>

enum T6BoneSlot : uint8_t {
    BONE_HIPS = 0,
    BONE_SPINE = 1,
    BONE_CHEST = 2,
    BONE_NECK = 3,
    BONE_HEAD = 4,
    BONE_R_UPPER_ARM = 6,
    BONE_R_FOREARM = 7,
    BONE_R_HAND = 8,
    BONE_L_UPPER_ARM = 10,
    BONE_L_FOREARM = 11,
    BONE_L_HAND = 12,
    BONE_PELVIS = 13,
    BONE_R_THIGH = 14,
    BONE_R_SHIN = 15,
    BONE_R_FOOT = 16,
    BONE_R_TOE = 17,
    BONE_L_THIGH = 18,
    BONE_L_SHIN = 19,
    BONE_L_FOOT = 20,
    BONE_L_TOE = 21,
    BONE_HEAD_END = 22,  // end-point bones start here, after the body bones
};

#endif
