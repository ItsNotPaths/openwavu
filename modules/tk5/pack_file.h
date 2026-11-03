// Pack files and load arenas for the stock modules' loaders (load.h), read with the host content import.
#ifndef T5_PACK_FILE_H
#define T5_PACK_FILE_H

#include <stddef.h>

#include "load.h"

// A whole pack file. Banks point into it, so it is never freed: a module lives for one match.
T5Bytes t5_read_pack_file(void *context, const char *path);
// A zeroed arena of `bytes`; NULL or the failure.
const char *t5_new_arena(T5Arena *arena, size_t bytes);

#endif
