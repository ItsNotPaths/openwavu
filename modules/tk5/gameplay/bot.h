// Stock TK5 bot (bot.c): ow_bot_pad gives one side's pad word, once per real tick.
#ifndef T5_BOT_H
#define T5_BOT_H

#include <stdint.h>

// Picks each side's attacks from its loaded moves; after the fighters are loaded.
void t5_bots_begin(uint64_t seed);

#endif
