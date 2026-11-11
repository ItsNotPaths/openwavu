// The hand pose properties: which hands each one poses and what it sets. The sim stores it in the hands' pose fields,
// the visual part plays it.
#ifndef T6_HAND_POSES_H
#define T6_HAND_POSES_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/properties.h"

enum : uint16_t { T6_HAND_PROPERTY_FIRST = T6_PROPERTY_BASE + 329, T6_HAND_PROPERTY_LAST = T6_PROPERTY_BASE + 336 };

typedef enum : uint8_t { T6_HOLD_HANDS, T6_SET_POSE, T6_SET_IDLE, T6_SET_GESTURE } T6HandPropertyKind;

typedef struct {
    bool right, left; // hands the pose is set on
    T6HandPropertyKind kind;
} T6HandProperty;

// From T6_HAND_PROPERTY_FIRST. A pose value is pose id * 256 + blend frames; a gesture value is the clip, plus 16384
// for the gesture bank.
static const T6HandProperty T6_HAND_PROPERTIES[T6_HAND_PROPERTY_LAST - T6_HAND_PROPERTY_FIRST + 1] = {
    {false, false, T6_HOLD_HANDS}, {true, true, T6_SET_POSE},    // one row per property id, in order
    {false, true, T6_SET_POSE},    {true, false, T6_SET_POSE},
    {true, true, T6_SET_IDLE},     {true, true, T6_SET_GESTURE}, {false, true, T6_SET_GESTURE}, {true, false, T6_SET_GESTURE},
};

#endif
