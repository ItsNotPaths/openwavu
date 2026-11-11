// A select grid: entries in rows, an extra slot (Random) after the last, and one cursor per side. Also the menus' buttons.
#ifndef T6_GRID_H
#define T6_GRID_H

#include <stdbool.h>
#include <stdint.h>
#include "openwavu.h"

// Every menu picks with button 3 and goes back with button 4 or a gamepad's Back.
enum { MENU_PICK = OW_PAD_BUTTON_3, MENU_BACK = OW_PAD_BUTTON_4 | OW_PAD_BACK, MENU_COSTUME_BUTTONS = 3 };

typedef struct {
    int slot;         // an entry, or the entry count for Random
    bool locked;
    uint32_t button;  // the game button that locked it, 1..MENU_COSTUME_BUTTONS
} T6Cursor;

// Tiles on the canvas, the first at (x, y).
typedef struct {
    float x, y, width, height, gap;
    int columns;
} T6Grid;

// Directions move over count entries plus Random, columns per row; a game button short of back locks.
void cursor_step(T6Cursor *cursor, int count, int columns, uint32_t pressed);
// The locked entry, Random rolled with rand().
int cursor_entry(const T6Cursor *cursor, int count);
// The slot's tile corner.
void grid_tile(const T6Grid *grid, int slot, float *x, float *y);

#endif
