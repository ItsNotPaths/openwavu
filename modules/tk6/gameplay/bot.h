// Stock TK6 bot (bot.c): ow_bot_pad gives one side's pad word, once per real tick.
#ifndef T6_BOT_H
#define T6_BOT_H

#include <stdint.h>

// Picks each side's attacks from its loaded moves; after the fighters are loaded.
const char *t6_bots_begin(uint64_t seed);  // NULL or the failure

#endif
