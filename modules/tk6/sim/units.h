// Unit types: each wrap or truncation lives in one helper here.
#ifndef T6_UNITS_H
#define T6_UNITS_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/math.h"

typedef struct { int32_t ticks; } T6Frames;
typedef struct { uint16_t bits; } T6Angle;  // 65536 = one turn
typedef struct { int32_t raw; } T6Health;   // 16.16

static constexpr T6Angle HALF_TURN = {32768};
static constexpr T6Angle QUARTER_TURN = {16384};
static constexpr T6Angle EIGHTH_TURN = {8192};
static constexpr T6Angle THIRD_TURN = {21845};
static constexpr T6Angle SIXTH_TURN = {10922};

// Whole degrees, the unit of the tuning constants. The game scales them by 65535 steps a turn, truncating toward zero.
typedef struct { int32_t degrees; } T6Degrees;

static constexpr int32_t STOCK_STEPS_PER_TURN = 65535;  // the turn size some game paths use (degree angles, wall side angle)
static constexpr int32_t STEPS_PER_TURN = 65536;
static constexpr int32_t DEGREES_PER_TURN = 360;

// Degrees in the source: constants are written in degrees and stored in the unit the code computes with.
// Macros so constexpr constants can use them. The radians form gives the game's float bits.
#define RAD_FROM_DEG(degrees) ((float)(degrees) * (T6_TWO_PI / DEGREES_PER_TURN))
#define ANGLE_FROM_DEG(degrees) ((degrees) * STEPS_PER_TURN / DEGREES_PER_TURN)  // steps, truncated

// A share of a whole number: value * numerator / denominator, truncating toward zero (the game's integer damage
// scales).
typedef struct { int32_t numerator, denominator; } T6Ratio;
[[nodiscard]] static inline int32_t t6_ratio_of(int32_t value, T6Ratio ratio) { return value * ratio.numerator / ratio.denominator; }

// Clock units of a move: the move clock, the speeds and the blend lengths count this many a frame.
static constexpr int32_t CLOCK_PER_FRAME = 4096;
// Move clock a frame at play speed 1.0; a restarted move plays at it. A server param later.
static constexpr int32_t PLAY_SPEED = CLOCK_PER_FRAME;

[[nodiscard]] static inline bool t6_frame_between(int32_t frame, int32_t first, int32_t last) {
    return first <= frame && frame <= last;  // both ends count
}
[[nodiscard]] static inline bool t6_frames_past(int32_t count, T6Frames limit) {
    return count > limit.ticks;  // strictly past the limit
}

[[nodiscard]] static inline T6Angle t6_angle_wrap(int32_t value) { return (T6Angle){(uint16_t)value}; }  // low 16 bits
[[nodiscard]] static inline T6Angle t6_turns(int32_t count, int32_t divisor) {
    return t6_angle_wrap(STEPS_PER_TURN * count / divisor);  // count/divisor of a turn
}
[[nodiscard]] static inline int16_t t6_angle_s16(T6Angle angle) {
    return (int16_t)angle.bits;  // angles past a half turn read as negative
}
[[nodiscard]] static inline T6Angle t6_degrees_angle(T6Degrees degrees) { return t6_angle_wrap(degrees.degrees * STOCK_STEPS_PER_TURN / DEGREES_PER_TURN); }
[[nodiscard]] static inline int16_t t6_angle_offset(int16_t angle, T6Angle by) {
    return t6_angle_s16(t6_angle_wrap(angle + by.bits));  // wraps at a full turn
}

#define HEALTH_FROM_POINTS(count) ((int32_t)((uint32_t)(count) << 16))  // whole points sit in the high 16 bits
[[nodiscard]] static inline T6Health t6_health_points(int32_t count) { return (T6Health){HEALTH_FROM_POINTS(count)}; }
// Health less whole points, wrapping in 32 bits.
[[nodiscard]] static inline T6Health t6_health_less(T6Health health, int32_t points) {
    return (T6Health){(int32_t)((uint32_t)health.raw - (uint32_t)t6_health_points(points).raw)};
}
[[nodiscard]] static inline uint16_t t6_health_percent(T6Health health, T6Health full) {
    return (uint16_t)t6_divw((int32_t)((uint32_t)health.raw * 100u), full.raw);  // percent of full, truncated
}

// The angle of the push code: 4096 steps a turn, counted from the +x axis, not wrapped (sin and cos wrap). A move yaw has
// 65536 steps a turn, so it divides by 16.
typedef struct { int32_t steps; } T6PushAngle;

static constexpr int32_t PUSH_STEPS_PER_TURN = 4096;
static constexpr T6PushAngle PUSH_HALF_TURN = {2048};
static constexpr T6PushAngle PUSH_QUARTER_TURN = {1024};

[[nodiscard]] static inline T6PushAngle t6_push_angle_add(T6PushAngle angle, T6PushAngle by) { return (T6PushAngle){angle.steps + by.steps}; }
[[nodiscard]] static inline T6PushAngle t6_push_angle_of_yaw(int16_t yaw) { return (T6PushAngle){PUSH_QUARTER_TURN.steps - yaw / 16}; }
// The direction of an atan2 result scaled to 65536 steps a turn (the low 16 bits count), turned the same way.
[[nodiscard]] static inline T6PushAngle t6_push_angle_of_heading(int32_t heading) {
    return (T6PushAngle){PUSH_QUARTER_TURN.steps - ((heading & 65535) >> 4)};
}
// Steps between two angles, 0 to a half turn.
[[nodiscard]] static inline int32_t t6_push_angle_between(T6PushAngle first, T6PushAngle second) {
    int32_t wrapped = (first.steps - second.steps) % PUSH_STEPS_PER_TURN;  // wrapped into one turn
    if (wrapped < 0) wrapped += PUSH_STEPS_PER_TURN;
    if (wrapped >= PUSH_HALF_TURN.steps) return PUSH_STEPS_PER_TURN - wrapped;  // past a half turn: go the short way
    return wrapped;
}
[[nodiscard]] static inline float t6_push_sin(T6PushAngle angle) { return t6_sin((float)angle.steps * (T6_TWO_PI / PUSH_STEPS_PER_TURN)); }
[[nodiscard]] static inline float t6_push_cos(T6PushAngle angle) { return t6_cos((float)angle.steps * (T6_TWO_PI / PUSH_STEPS_PER_TURN)); }

#endif
