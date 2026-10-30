// The simulation RNG.
#ifndef T5_RNG_H
#define T5_RNG_H

#include <stdint.h>

typedef struct { uint32_t x; } T5Rng;

int32_t t5_rng_bits(T5Rng *rng, int32_t bits);  // step, top `bits` of a 48-bit view
int32_t t5_rand(T5Rng *rng);                  // 0..32766
int32_t t5_rand_n(T5Rng *rng, int32_t range);  // rand % range, range clamped to 0..32767, range 0 gives rand

#endif
