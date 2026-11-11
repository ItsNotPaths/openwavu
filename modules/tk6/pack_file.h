// Pack files and load arenas for the stock modules' loaders (load.h), read with the host content import.
#ifndef T6_PACK_FILE_H
#define T6_PACK_FILE_H

#include <stddef.h>

#include "load.h"

// A whole pack file. Banks point into it, so it is never freed: a module lives for one match.
T6Bytes t6_read_pack_file(void *context, const char *path);
// A zeroed arena of `bytes`; NULL or the failure.
const char *t6_new_arena(T6Arena *arena, size_t bytes);

// Pack files kept until the set is freed: data that is loaded again within a match (Mokujin's move set each round).
typedef struct {
    void **files;
    size_t count, capacity;
} T6FileSet;
T6Bytes t6_read_set_file(void *file_set, const char *path);  // a T6ReadFile; context: the T6FileSet
void t6_file_set_free(T6FileSet *file_set);

#endif
