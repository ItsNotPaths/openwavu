// What the stock menus pick from: the pack db's characters and stages, in sheet order.
#ifndef T5_CATALOG_H
#define T5_CATALOG_H

#include <stdint.h>
#include "loadout.h"

enum { CATALOG_ENTRIES_MAX = 128 };

typedef struct {
    char id[T5_NAME_BYTES];    // the row's key
    char name[T5_NAME_BYTES];  // what the menus show
    uint32_t costumes;         // characters only
} T5Entry;

typedef struct {
    T5Entry characters[CATALOG_ENTRIES_MAX];
    T5Entry stages[CATALOG_ENTRIES_MAX];
    int character_count, stage_count;
} T5Catalog;

// NULL, or why the db gives nothing to pick.
const char *catalog_load(T5Catalog *catalog);

#endif
