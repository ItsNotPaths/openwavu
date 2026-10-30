#include "sim/math.h"

#include <math.h>
#include <string.h>

#include "sim/units.h"

enum : uint32_t { MANTISSA_BITS = 23, EXPONENT_BIAS = 127 };
static const uint32_t EXPONENT_MASK = 0x7f800000u;
static const uint32_t MANTISSA_MASK = 0x007fffffu;
static const uint32_t MAGNITUDE_MASK = 0x7fffffffu;

static uint32_t bits(float value) { uint32_t word; memcpy(&word, &value, 4); return word; }  // the raw bits of a float
static float from_bits(uint32_t word) { float value; memcpy(&value, &word, 4); return value; }  // the float of raw bits
static int sign_bit(float value) { return bits(value) >> 31; }  // the code's stfs + lwz + cmpwi test

int32_t t5_fctiwz(float value) {  // float to int like the console: cut toward zero, clamp at the ends
    if (value != value || value <= -2147483648.0f) return INT32_MIN;  // NaN and too small give the lowest int
    if (value >= 2147483648.0f) return INT32_MAX;  // too big gives the highest int
    return (int32_t)value;
}

int64_t t5_fctidz(float value) {  // same as above, 64 bits
    if (value != value || value <= -9223372036854775808.0f) return INT64_MIN;
    if (value >= 9223372036854775808.0f) return INT64_MAX;
    return (int64_t)value;
}

// --- inline sin/cos: octant reduction by 4/pi, two short polynomials

static const float FOUR_OVER_PI = 1.27323949f;
// highest power first; in the octant fraction, so the sine ends in pi/4 and the cosine in 1
static const float SINE_POLY[4] = {-3.59504375e-05f, 0.00249000103f, -0.0807454363f, 0.785398185f};
static const float COSINE_POLY[4] = {-0.000318727834f, 0.0158496834f, -0.308424175f, 0.99999994f};

static float sine_poly(float fraction) {  // sine of an octant fraction, as a polynomial in odd powers
    float sum = fraction * SINE_POLY[0];
    sum = fmaf(fraction, sum, SINE_POLY[1]);
    sum = fraction * sum;
    sum = fmaf(fraction, sum, SINE_POLY[2]);
    sum = fraction * sum;
    sum = fmaf(fraction, sum, SINE_POLY[3]);
    return fraction * sum;
}

static float cosine_poly(float fraction) {  // cosine of an octant fraction, as a polynomial in even powers
    float sum = fraction * COSINE_POLY[0];
    sum = fmaf(fraction, sum, COSINE_POLY[1]);
    sum = fraction * sum;
    sum = fmaf(fraction, sum, COSINE_POLY[2]);
    sum = fraction * sum;
    return fmaf(fraction, sum, COSINE_POLY[3]);
}

// reduced angle in [0, 1] of the octant
static float octant(float angle, int32_t *index) {  // split angle into whole octant (eighth turn) and fraction in it
    float scaled = angle * FOUR_OVER_PI;
    *index = t5_fctiwz(scaled);  // the whole octant
    float fraction = scaled - (float)*index;  // what is left past the octant
    return *index & 1 ? 1.0f - fraction : fraction;  // odd octants run backward, so mirror the fraction
}

static int sin_poly_first(int32_t index) { return ((index + 1) & 2) == 0; }  // whether the octant uses sine poly first

float t5_sin(float angle) {  // sine for any angle, used where the game has its own inline copy
    if (sign_bit(angle)) return -t5_sin(-angle);  // sine is odd: flip the sign of a negative angle
    int32_t octant_index;
    float fraction = octant(angle, &octant_index);
    float result = sin_poly_first(octant_index) ? sine_poly(fraction) : cosine_poly(fraction);  // polynomial for this octant
    return (octant_index & 7) > 3 ? -result : result;  // the second half turn is negative
}

float t5_cos(float angle) {  // cosine for any angle, used where the game has its own inline copy
    if (sign_bit(angle)) angle = -angle;  // cosine is even: drop the sign
    int32_t octant_index;
    float fraction = octant(angle, &octant_index);
    float result = sin_poly_first(octant_index) ? cosine_poly(fraction) : sine_poly(fraction);  // cosine: opposite of sine
    return ((octant_index + 2) & 7) > 3 ? -result : result;  // cosine is negative in the middle half of the turn
}

// --- Dinkumware libm

static const float EPSILON = 0.000244140625f;  // 2^-12

int32_t t5_fpclass(float value) {  // classify a float: 2 NaN, 1 infinity, 0 zero, -1 any other number
    uint32_t word = bits(value);
    if ((word & EXPONENT_MASK) == EXPONENT_MASK) return word & MANTISSA_MASK ? 2 : 1;  // all exponent bits: inf, or NaN
    return word & MAGNITUDE_MASK ? -1 : 0;  // no bits besides the sign means zero
}

// the angle each octant flag set adds: multiples of pi/6
static const float ATAN_TABLE[8] = {
    0.0f, 0.52359879f, T5_HALF_PI, 1.04719758f,
    T5_HALF_PI, 2.09439516f, T5_PI, 2.61799383f,
};
static const float TAN_15_DEGREES = 0.267949194f;
static const float SQRT_3 = 1.73205078f;
static const float ATAN_NUMERATOR = 0.51497519f;
static const float ATAN_DENOMINATOR[2] = {0.0828021392f, 0.848308086f};

float t5_fatan(float value, int32_t octant_flags) {  // arctangent of value plus octant flags (see table below)
    if (value > TAN_15_DEGREES) {  // above tan 15 degrees: shift the value down with a pi/6 identity
        value = fmaf(value, SQRT_3, -1.0f) / (value + SQRT_3);
        octant_flags |= 1;  // remember the pi/6 shift for the table
    }
    if (value < -EPSILON || value > EPSILON) {  // a tiny value is its own arctangent, skip the fraction
        float value_squared = value * value;
        float numerator = fmaf(value * value_squared, ATAN_NUMERATOR, value);
        float denominator = fmaf(value_squared, fmaf(value_squared, ATAN_DENOMINATOR[0], ATAN_DENOMINATOR[1]), 1.0f);
        value = numerator / denominator;  // rational approximation
    }
    if (octant_flags & 2) value = -value;  // flag 2 negates the value
    value += ATAN_TABLE[octant_flags & 7];  // add the angle for these flags
    return octant_flags & 8 ? -value : value;  // flag 8 negates the result
}

float t5_atan2(float y, float x) {  // two-argument arctangent: the angle of (x, y) from the x axis
    int32_t class_x = t5_fpclass(x);
    int32_t class_y = t5_fpclass(y);
    int32_t octant_flags = 0;
    float ratio;
    if (class_x <= 0 && class_y <= 0) {  // normal case: both are finite or zero
        if (sign_bit(y)) { y = -y; octant_flags = 8; }  // negative y: use its size and set the negate flag
        if (sign_bit(x)) { x = -x; octant_flags ^= 6; }  // negative x: use its size and flip to the other side of pi/2
        if (x >= y) ratio = class_x < 0 ? y / x : 0.0f;  // x is the larger side: ratio y / x, or 0 when x is zero
        else { octant_flags ^= 2; ratio = x / y; }  // y is larger: swap the roles
        return t5_fatan(ratio, octant_flags);
    }
    if (class_y == 2) return y;  // a NaN passes through
    if (class_x == 2) return x;
    ratio = class_x == class_y ? 1.0f : 0.0f;  // both inf: atan(1)
    if (sign_bit(y)) octant_flags = 8;  // negative y: set the negate flag
    if (sign_bit(x)) octant_flags ^= 6;  // negative x: flip to the other side of pi/2
    if (class_y == 1) octant_flags ^= 2;  // infinite y: the answer is near pi/2
    return t5_fatan(ratio, octant_flags);
}

float t5_fmod(float dividend, float divisor) {  // float remainder; non-numbers follow the old C library rules
    int32_t class_dividend = t5_fpclass(dividend);
    int32_t class_divisor = t5_fpclass(divisor);
    if (class_dividend < 0 && class_divisor < 0) return fmodf(dividend, divisor);  // the subtract loop is exact, like fmodf
    if (class_dividend == 2) return dividend;
    if (class_divisor == 2) return divisor;
    if (class_dividend == 1 || class_divisor == 0) return NAN;  // also sets errno (EDOM) in the game
    return dividend;  // finite dividend and infinite divisor: the dividend is left whole
}

static const float TWO_OVER_PI = 0.636619747f;
// pi/2 in two parts, so the reduction keeps the bits a single float would lose
static const float HALF_PI_HIGH = 1.57079625f;
static const float HALF_PI_LOW = 7.54979013e-08f;
// highest power first, in angle squared
static const float COSINE_TAIL[3] = {-0.00136022491f, 0.0416566953f, -0.499999017f};
static const float SINE_TAIL[3] = {-0.000195072702f, 0.00833207555f, -0.166666523f};

float t5_fsin(float angle, int32_t cosine_flag) {  // sine, or cosine if cosine_flag is 1; via t5_angle_sin and t5_angle_cos
    int32_t kind = t5_fpclass(angle);
    if (kind == 1) return NAN;  // infinity has no sine
    if (kind == 2) return angle;  // NaN passes through
    if (kind == 0) return cosine_flag ? 1.0f : angle;  // zero: sine is the angle, cosine is 1
    if ((double)angle < -40.7 || (double)angle > 40.7) angle = t5_fmod(angle, T5_TWO_PI);  // wrap a large angle by 2pi
    float turns = angle * TWO_OVER_PI;  // angle in quarter turns
    int32_t quarter = t5_fctiwz(turns > 0.0f ? turns + 0.5f : turns - 0.5f);  // round to the nearest quarter turn
    int32_t quadrant = (quarter & 3) + cosine_flag;  // quarter turns left after whole turns, shifted by 1 for cosine
    float quarter_float = (float)quarter;
    angle = fmaf(quarter_float, -HALF_PI_HIGH, angle);  // subtract the quarter turns from the angle, in two parts for accuracy
    angle = fmaf(quarter_float, -HALF_PI_LOW, angle);
    float result;
    if (angle > -EPSILON && angle < EPSILON) {  // tiny angle: sine is the angle, cosine is 1
        result = quadrant & 1 ? 1.0f : angle;
    } else {
        float angle_squared = angle * angle;
        if (quadrant & 1)  // odd quadrant: use the cosine series
            result = fmaf(angle_squared, fmaf(angle_squared, fmaf(angle_squared, COSINE_TAIL[0], COSINE_TAIL[1]), COSINE_TAIL[2]), 1.0f);
        else
            result = fmaf(angle * angle_squared, fmaf(angle_squared, fmaf(angle_squared, SINE_TAIL[0], SINE_TAIL[1]), SINE_TAIL[2]), angle);
    }
    return quadrant & 2 ? -result : result;  // quadrants 2 and 3 are negative
}

float t5_modf(float value, float *whole_part) {  // split a number into whole part (written out) and fraction (returned)
    *whole_part = value;
    int32_t kind = t5_fpclass(value);
    if (kind == 2) return value;  // NaN passes through
    if (kind == 1) return sign_bit(value) ? -0.0f : 0.0f;  // infinity has no fraction: zero with its sign
    *whole_part = truncf(value);
    if (*whole_part == value) return sign_bit(value) ? -0.0f : 0.0f;  // already whole: zero with its sign
    return value - *whole_part;
}

// --- angles

float t5_angle_to_rad(int16_t angle) { return (float)angle * T5_ANGLE_TO_RAD; }  // binary angle to radians

int32_t t5_divw(int32_t dividend, int32_t divisor) {  // signed integer divide like the console: never traps
    if (divisor == 0 || (dividend == INT32_MIN && divisor == -1)) return dividend;  // zero divisor and INT_MIN / -1: dividend
    return dividend / divisor;
}

float t5_wrap_pi(float angle) {  // bring an angle that is at most one turn out into [-pi, pi]
    if (angle > T5_PI) return angle - T5_TWO_PI;
    if (angle < -T5_PI) return angle + T5_TWO_PI;
    return angle;
}

// truncation by exponent masking, as the code does it: |value| < 1 gives +0
static float trunc_mask(float value) {  // cut off the fraction of a float by clearing mantissa bits below the exponent
    uint32_t word = bits(value);
    int32_t exponent = (int32_t)((word & EXPONENT_MASK) >> MANTISSA_BITS) - EXPONENT_BIAS;  // exponent without the bias
    if (exponent < 0) word = 0;  // smaller than 1: nothing whole is left
    else if (exponent < (int32_t)MANTISSA_BITS) word &= ~(MANTISSA_MASK >> exponent);  // clear fraction bits; big exponent: whole
    return from_bits(word);
}

float t5_wrap_full(float angle) {  // wrap any number of turns into [-pi, pi]
    float turns = angle / T5_TWO_PI;  // angle in whole and part turns
    return t5_wrap_pi((turns - trunc_mask(turns)) * T5_TWO_PI);  // keep only the part turn, back to radians, then wrap
}

int16_t t5_rad_to_angle(float radians) { return (int16_t)t5_fctiwz(radians * T5_RAD_TO_ANGLE); }

static constexpr float STOCK_STEPS_PER_TURN_FLOAT = 65535.0f;  // some paths scale by 65535, not 65536

int16_t t5_rad_to_angle65535(float radians) { return (int16_t)t5_fctiwz(radians * STOCK_STEPS_PER_TURN_FLOAT / T5_TWO_PI); }

float t5_angle65535_to_rad(int16_t angle) {  // binary angle (65535 steps per turn) to radians, wrapped
    float steps = (float)angle;
    return t5_wrap_pi((steps + steps) * T5_PI / STOCK_STEPS_PER_TURN_FLOAT);
}

float t5_asin(float value) {  // arcsine, built on the arctangent
    int32_t octant_flags = 0;
    if (value < 0.0f) {  // negative: work on the size and set the negate flag
        value = -value;
        octant_flags = 8;
    }
    if (value <= 0.707106769f)  // up to sin 45 degrees: tan = value / sqrt(1 - value squared)
        return t5_fatan(value / sqrtf((1.0f - value) * (value + 1.0f)), octant_flags);
    if (value <= 1.0f) {  // above that, up to 1: the same ratio rewritten so it stays accurate near 1
        float rest = 1.0f - value;
        return t5_fatan(sqrtf(fmaf(value, rest, rest)) / value, octant_flags ^ 2);
    }
    return NAN;  // outside [-1, 1] there is no arcsine
}

enum { FAST_TABLE_STEPS = 1024 };

// entry `step` of the table built at boot: atan2 at step/1024 of the way from +x to +y
static float atan_step(int32_t step) {
    float fraction = (float)step * (1.0f / FAST_TABLE_STEPS);
    return t5_atan2(fraction, 1.0f - fraction);
}

float t5_fast_atan2(float y, float x) {  // angle of (x, y) from a table, used by the look and limb code for yaw
    float fraction, base;  // fraction in [0, 1] inside the quadrant
    if (y >= 0.0f && x >= 0.0f) {  // first quadrant: x and y both positive
        float sum = y + x;  // fraction of the way from the x axis to the y axis
        fraction = sum == 0.0f ? sum : y / sum;  // both zero: no direction, keep zero
        base = 0.0f;
    } else if (y >= 0.0f) {  // second quadrant
        fraction = x / (x - y);
        base = T5_HALF_PI;
    } else if (x < 0.0f) {  // third quadrant
        fraction = y / (y + x);
        base = -T5_PI;
    } else {  // fourth quadrant
        fraction = x / (x - y);
        base = -T5_HALF_PI;
    }
    float scaled = fraction * (float)FAST_TABLE_STEPS;  // position in table steps
    int32_t step = t5_fctiwz(scaled);  // the whole table step
    float step_angle = atan_step(step);  // the table angle at this step
    return fmaf(scaled - (float)step, atan_step(step + 1) - step_angle, base + step_angle);  // blend this step to the next
}

// entry `step` of the sin/cos table built at boot: step * 2pi/1024 (sin of entry 0 is the constant 0)
static float sin_step(int32_t step) { return step == 0 ? 0.0f : t5_sin((float)step * (T5_TWO_PI / FAST_TABLE_STEPS)); }
static float cos_step(int32_t step) { return t5_cos((float)step * (T5_TWO_PI / FAST_TABLE_STEPS)); }

void t5_fast_sincos(int32_t angle, float sine_cosine[2]) {  // sine and cosine of a binary angle (65536 per turn), for limb code
    int32_t step = angle >> 6 & (FAST_TABLE_STEPS - 1);  // table step: the top bits of the angle, wrapped at 1024 steps
    float fraction = (float)(angle & 63);  // the low 6 bits are the blend between two steps
    float sine = sin_step(step);
    float cosine = cos_step(step);
    sine_cosine[0] = fmaf(fraction, (sin_step(step + 1) - sine) * 0.015625f, sine);  // blend to next step (1/64 per low step)
    sine_cosine[1] = fmaf(fraction, (cos_step(step + 1) - cosine) * 0.015625f, cosine);  // same for cosine
}

int32_t t5_rad_to_angle_round(float radians) {  // radians to binary angle, rounded away from zero
    return t5_fctiwz((radians < 0.0f ? -0.5f : 0.5f) + radians * 65536.0f / T5_TWO_PI);
}

float t5_angle_sin(int32_t angle) {  // sine of a binary angle
    return t5_fsin((float)angle * T5_TWO_PI * (1.0f / STEPS_PER_TURN), 0);
}

float t5_angle_cos(int32_t angle) {  // cosine of a binary angle
    return t5_fsin((float)angle * T5_TWO_PI * (1.0f / STEPS_PER_TURN), 1);
}

// --- integer turn helpers (32-bit wrapping like the PPC code)

int16_t t5_clamp_s16(int32_t value, int32_t limit) {  // clamp a value into [-limit, limit] as 16 bits
    int32_t negative_limit = -limit;
    if (value >= 0) return (int16_t)(value > limit ? limit : value);  // positive: only the top limit counts
    return (int16_t)(value < negative_limit ? negative_limit : value);  // negative: only the bottom limit counts
}

static int32_t abs32(int32_t value) { return value < 0 ? -value : value; }

int32_t t5_turn_cap(int32_t step, int32_t total, int32_t cap) {  // 0 if step fits the cap, else the rest of the cap, step-signed
    int32_t total_size = abs32(total);  // size of the turn so far
    int16_t rest = (int16_t)(cap - total_size);  // what is left of the cap
    if (abs32(step) + total_size <= cap) return 0;  // the step fits: no change needed
    return step < 0 ? -(int32_t)rest : rest;  // too big: give back the rest of the cap in the step's direction
}

int16_t t5_turn_approach(int32_t target, int32_t current, int32_t divisor) {  // shorter way to target, 1/divisor of the gap
    int32_t difference = target % STEPS_PER_TURN - current % STEPS_PER_TURN;  // gap between the two angles, each within one turn
    int32_t forward = difference < 0 ? difference + STEPS_PER_TURN : difference;  // the gap going forward (increasing angle)
    int32_t back = -difference < 0 ? STEPS_PER_TURN - difference : -difference;  // the gap going backward
    int32_t delta = forward < back ? forward : -back;  // pick the shorter way; backward is negative
    return (int16_t)(t5_divw(delta, divisor) + current);  // move 1 / divisor of the way
}

// --- inline lengths

float t5_length3(float x, float y, float z) { return sqrtf(fmaf(z, z, fmaf(x, x, y * y))); }  // length of a 3D vector

float t5_length_xz(float x, float z) { return sqrtf(fmaf(x, x, z * z)); }  // ground plane length, for distance and ring-out
