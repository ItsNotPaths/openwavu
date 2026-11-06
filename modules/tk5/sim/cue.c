#include "sim/cue.h"

#include <string.h>

void t5_cue_add(T5CueRing *ring, uint32_t frame, T5Cue cue) {
    ring->entries[ring->sent % T5_CUE_RING] = (T5CueEntry){frame, ring->sent, cue};
    ring->sent++;
}

void t5_cue_clear(T5CueRing *ring) {
    memset(ring->entries, 0, sizeof ring->entries);
}
