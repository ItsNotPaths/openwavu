#include "grid.h"
#include <stdlib.h>
#include "openwavu.h"

void cursor_step(T6Cursor *cursor, int count, int columns, uint32_t pressed) {
    if (cursor->locked) return;
    int slots = count + 1;
    if (pressed & OW_PAD_LEFT) cursor->slot = (cursor->slot + slots - 1) % slots;
    if (pressed & OW_PAD_RIGHT) cursor->slot = (cursor->slot + 1) % slots;
    if (pressed & OW_PAD_UP && cursor->slot >= columns) cursor->slot -= columns;
    if (pressed & OW_PAD_DOWN && cursor->slot + columns < slots) cursor->slot += columns;
    for (uint32_t button = 1; button <= MENU_COSTUME_BUTTONS; button++) {
        if (!(pressed & 1u << (OW_PAD_BUTTON_SHIFT + button - 1))) continue;
        cursor->locked = true;
        cursor->button = button;
        return;
    }
}

int cursor_entry(const T6Cursor *cursor, int count) {
    return cursor->slot < count ? cursor->slot : rand() % count;
}

void grid_tile(const T6Grid *grid, int slot, float *x, float *y) {
    *x = grid->x + (float)(slot % grid->columns) * (grid->width + grid->gap);
    *y = grid->y + (float)(slot / grid->columns) * (grid->height + grid->gap);
}
