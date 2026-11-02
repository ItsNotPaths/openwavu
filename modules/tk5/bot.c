// Stock TK5 bot: a pad source, like a player pressing buttons. Its state is outside the snapshot.
#include "openwavu.h"

// (hole cpu-bot :tags tk5mod) no bot: port tk5decomp demo/cpu.c (one-press attacks from the idle cancel list, blocks seen attacks; sees distance, side, opponent attacking, health, round live).
OW_EXPORT(ow_bot_pad) uint32_t ow_bot_pad(uint32_t side) { return 0; }
