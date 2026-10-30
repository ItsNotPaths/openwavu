// The hand pose properties: which hands each one poses and what it sets. The sim stores it in the hands' pose fields,
// the visual part plays it.
#ifndef T5_HAND_POSES_H
#define T5_HAND_POSES_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/properties.h"

enum : uint16_t { T5_HAND_PROPERTY_FIRST = T5_PROPERTY_BASE + 329, T5_HAND_PROPERTY_LAST = T5_PROPERTY_BASE + 336 };

typedef enum : uint8_t { T5_HOLD_HANDS, T5_SET_POSE, T5_SET_IDLE, T5_SET_GESTURE } T5HandPropertyKind;

typedef struct {
    bool right, left; // hands the pose is set on
    T5HandPropertyKind kind;
} T5HandProperty;

// From T5_HAND_PROPERTY_FIRST. A pose value is pose id * 256 + blend frames; a gesture value is the clip, plus 16384
// for the gesture bank.
static const T5HandProperty T5_HAND_PROPERTIES[T5_HAND_PROPERTY_LAST - T5_HAND_PROPERTY_FIRST + 1] = {
    {false, false, T5_HOLD_HANDS}, {true, true, T5_SET_POSE},    // one row per property id, in order
    {false, true, T5_SET_POSE},    {true, false, T5_SET_POSE},
    {true, true, T5_SET_IDLE},     {true, true, T5_SET_GESTURE}, {false, true, T5_SET_GESTURE}, {true, false, T5_SET_GESTURE},
};

#endif
