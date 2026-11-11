// The simulation RNG.
#ifndef T6_RNG_H
#define T6_RNG_H

#include <stdint.h>

typedef struct { uint32_t x; } T6Rng;

int32_t t6_rng_bits(T6Rng *rng, int32_t bits);  // step, top `bits` of a 48-bit view
int32_t t6_rand(T6Rng *rng);                  // 0..32766
int32_t t6_rand_n(T6Rng *rng, int32_t range);  // rand % range, range clamped to 0..32767, range 0 gives rand

#endif
