// Scalar math of the game: single precision, fma exactly where the PPC code fuses.
#ifndef T5_MATH_H
#define T5_MATH_H

#include <stdint.h>

#define T5_PI 3.14159274f
#define T5_TWO_PI 6.28318548f
#define T5_HALF_PI 1.57079637f
#define T5_ANGLE_TO_RAD 9.58738019e-05f  // 2pi/65536
#define T5_RAD_TO_ANGLE 10430.3779f      // 32768/pi

// fctiwz: truncate toward zero, saturate, NaN -> INT32_MIN
int32_t t5_fctiwz(float value);
int64_t t5_fctidz(float value);  // the same to 64 bits

float t5_sin(float angle);              // (inline copies identical)
float t5_cos(float angle);
float t5_atan2(float y, float x);       // Dinkumware atan2f
float t5_fast_atan2(float y, float x);  // a 1024-step table, linear between 1/1024 steps; NaN in reads past it
void t5_fast_sincos(int32_t angle, float sine_cosine[2]);  // sin, cos of a binary angle from a 1024-step table
float t5_fsin(float angle, int32_t cosine_flag);  // Dinkumware _FSin, cosine_flag 0 sin, 1 cos
float t5_fmod(float dividend, float divisor);  // remainder like fmodf for finite numbers
float t5_asin(float value);             // Dinkumware asinf
float t5_modf(float value, float *whole_part);  // fraction returned; whole part written to whole_part

// Dinkumware internals, exported for the diff harness
int32_t t5_fpclass(float value);        // 0 zero, -1 finite, 1 inf, 2 NaN
float t5_fatan(float value, int32_t octant_flags);  // arctangent; octant_flags add a fixed angle and set signs

// binary angles (65536 = one turn)
float t5_angle_to_rad(int16_t angle);   // (float)angle * 2pi/65536
int32_t t5_divw(int32_t dividend, int32_t divisor);  // PPC divw; zero divisor and INT_MIN / -1 give the dividend (QEMU)
float t5_wrap_pi(float angle);          // one wrap into [-pi, pi]
float t5_wrap_full(float angle);        // any angle into [-pi, pi]: remove whole turns by exponent masking, then wrap_pi
int16_t t5_rad_to_angle(float radians);  // (s16)(int)(radians * 32768/pi)
int16_t t5_rad_to_angle65535(float radians);  // (s16)(int)(radians * 65535 / 2pi)
float t5_angle65535_to_rad(int16_t angle);  // (angle + angle) * pi / 65535, wrapped once into [-pi, pi]
int32_t t5_rad_to_angle_round(float radians); // (int)(radians * 65536 / 2pi +- 0.5), half away from zero; anim euler paths
float t5_angle_sin(int32_t angle);      // _FSin(angle * 2pi / 65536)
float t5_angle_cos(int32_t angle);  // cosine version of t5_angle_sin

// integer turn helpers
int16_t t5_clamp_s16(int32_t value, int32_t limit);  // clamp to [-limit, limit], then cast to 16 bits
int32_t t5_turn_cap(int32_t step, int32_t total, int32_t cap);  // 0 if the step fits the cap, else the rest of the cap
int16_t t5_turn_approach(int32_t target, int32_t current, int32_t divisor);  // 1/divisor of the gap, the short way

// inline vector lengths (fma order of the code)
float t5_length3(float x, float y, float z);   // sqrtf(fma(z,z, fma(x,x, y*y)))
float t5_length_xz(float x, float z);          // sqrtf(fma(x,x, z*z))

#endif
