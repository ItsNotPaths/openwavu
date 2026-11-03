#include "grid.h"
#include <SDL3/SDL.h>
#include <stdlib.h>
#include "openwavu.h"

enum { GRID_X = 24, CELL_WIDTH = GRID_CELL_CHARACTERS * 8 };

static const SDL_Color SIDE_COLORS[2] = {{150, 30, 30, 255}, {30, 60, 160, 255}};

void cursor_step(T5Cursor *cursor, int count, int columns, uint32_t pressed) {
    if (cursor->locked) return;
    int slots = count + 1;
    if (pressed & OW_PAD_LEFT) cursor->slot = (cursor->slot + slots - 1) % slots;
    if (pressed & OW_PAD_RIGHT) cursor->slot = (cursor->slot + 1) % slots;
    if (pressed & OW_PAD_UP && cursor->slot >= columns) cursor->slot -= columns;
    if (pressed & OW_PAD_DOWN && cursor->slot + columns < slots) cursor->slot += columns;
    for (uint32_t button = 1; button <= 4; button++) {
        if (!(pressed & 1u << (OW_PAD_BUTTON_SHIFT + button - 1))) continue;
        cursor->locked = true;
        cursor->button = button;
        return;
    }
}

int cursor_entry(const T5Cursor *cursor, int count) {
    return cursor->slot < count ? cursor->slot : rand() % count;
}

int grid_columns(SDL_Renderer *renderer) {
    int width, height;
    SDL_GetRenderOutputSize(renderer, &width, &height);
    int columns = (width / GRID_SCALE - GRID_X) / CELL_WIDTH;
    return columns > 0 ? columns : 1;
}

void grid_draw(SDL_Renderer *renderer, const T5Entry *entries, int count, const char *extra, int columns, float y,
    const T5Cursor *cursors[2]) {
    for (int slot = 0; slot < count + (extra != NULL); slot++) {
        float x = GRID_X + (float)(slot % columns) * CELL_WIDTH, row = y + (float)(slot / columns) * GRID_LINE;
        for (int side = 0; side < 2; side++) {
            const T5Cursor *cursor = cursors[side];
            if (!cursor || cursor->slot != slot) continue;
            SDL_Color color = SIDE_COLORS[side];
            float bright = cursor->locked ? 1.0f : 0.6f;
            SDL_SetRenderDrawColorFloat(renderer, color.r / 255.0f * bright, color.g / 255.0f * bright, color.b / 255.0f * bright, 1);
            float half = cursors[0] && cursors[1] && cursors[0]->slot == cursors[1]->slot ? CELL_WIDTH / 2.0f : 0;
            SDL_RenderFillRect(renderer, &(SDL_FRect){x - 4 + side * half, row - 2, CELL_WIDTH - 8 - half, GRID_LINE});
        }
        SDL_SetRenderDrawColor(renderer, 235, 235, 235, 255);
        SDL_RenderDebugText(renderer, x, row, slot < count ? entries[slot].name : extra);
    }
}
