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
    char alternate[T5_NAME_BYTES];  // a character picked by the buttons past costumes, as its costumes; "" if none
} T5Entry;

typedef struct {
    T5Entry characters[CATALOG_ENTRIES_MAX];
    T5Entry stages[CATALOG_ENTRIES_MAX];
    int character_count, stage_count;
} T5Catalog;

typedef struct sqlite3 sqlite3;

// NULL, or why the db gives nothing to pick.
const char *catalog_load(sqlite3 *db, T5Catalog *catalog);

#endif
