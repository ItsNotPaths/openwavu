#include "sim/cue.h"

#include <string.h>

void t6_cue_add(T6CueRing *ring, uint32_t frame, T6Cue cue) {
    ring->entries[ring->sent % T6_CUE_RING] = (T6CueEntry){frame, ring->sent, cue};
    ring->sent++;
}

void t6_cue_clear(T6CueRing *ring) {
    memset(ring->entries, 0, sizeof ring->entries);
}
