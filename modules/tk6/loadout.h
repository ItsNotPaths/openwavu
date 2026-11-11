// The stock TK6 loadout: one side's pick, in the pack's own format. app.wasm makes it, the sim reads it at init
// (ow_loadout) and checks it against the db.
#ifndef T6_LOADOUT_H
#define T6_LOADOUT_H

#include <stdint.h>

enum { T6_NAME_BYTES = 32 };

typedef struct {
    char character[T6_NAME_BYTES];  // a db character id, NUL-terminated
    uint32_t costume;               // 1 = the first; looks only, the sim keeps it for the view
} T6Loadout;

#endif
