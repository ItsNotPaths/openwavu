#include "sim/rng.h"

// a 48-bit LCG with the drand48 constants, kept in 32 bits
static const uint32_t RNG_MULTIPLIER = 3740067437u;
static const uint32_t RNG_INCREMENT = 11u;
enum { RAND_LIMIT = 32767 };

int32_t t5_rng_bits(T5Rng *rng, int32_t bits) {
    rng->x = rng->x * RNG_MULTIPLIER + RNG_INCREMENT;  // advance the state
    uint32_t shift = (uint32_t)(48 - bits) & 63;  // srw: shifts of 32..63 give 0
    return (int32_t)(shift < 32 ? rng->x >> shift : 0);  // take the top bits of the state
}

int32_t t5_rand(T5Rng *rng) { return t5_rng_bits(rng, 32) % RAND_LIMIT; }  // random value from 0 to 32766

int32_t t5_rand_n(T5Rng *rng, int32_t range) {
    if (range < 0) range = 0;  // negative range counts as 0
    if (range > RAND_LIMIT - 1) range = RAND_LIMIT;  // range above the limit is capped
    int32_t value = t5_rand(rng);
    return range ? value % range : value;  // divw by 0: value - quotient*0 = value whatever the quotient is
}

