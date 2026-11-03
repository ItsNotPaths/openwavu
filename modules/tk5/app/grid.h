// A select grid: entry names in rows, an extra slot (Random) after the last, and one cursor per side.
#ifndef T5_GRID_H
#define T5_GRID_H

#include <SDL3/SDL.h>
#include <stdbool.h>
#include <stdint.h>
#include "catalog.h"

enum { GRID_SCALE = 2, GRID_LINE = 12, GRID_CELL_CHARACTERS = 24 };  // debug text is 8 px, drawn at GRID_SCALE

typedef struct {
    int slot;         // an entry, or the entry count for Random
    bool locked;
    uint32_t button;  // the game button that locked it, 1..4
} T5Cursor;

// Directions move over count entries plus Random, columns per row; a game button locks.
void cursor_step(T5Cursor *cursor, int count, int columns, uint32_t pressed);
// The locked entry, Random rolled with rand().
int cursor_entry(const T5Cursor *cursor, int count);

// Columns that fit the renderer's output width.
int grid_columns(SDL_Renderer *renderer);
// Draws the entries from y (in scaled units), then the extra slot unless it is NULL, with each side's cursor; a NULL
// cursor is not drawn.
void grid_draw(SDL_Renderer *renderer, const T5Entry *entries, int count, const char *extra, int columns, float y,
    const T5Cursor *cursors[2]);

#endif
