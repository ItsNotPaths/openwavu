#include "art.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "openwavu.h"
#include "sqlite3.h"

enum { KEPT_MAX = 256, ID_BYTES = 64 };

static sqlite3 *db;
static SDL_Renderer *renderer;
static struct {
    char id[ID_BYTES];
    SDL_Texture *texture;
} kept[KEPT_MAX];
static int kept_count;
static float scale, left, top;

void art_init(sqlite3 *opened, SDL_Renderer *output) {
    db = opened;
    renderer = output;
}

SDL_Texture *art_load(const char *id) {
    sqlite3_stmt *row;
    if (sqlite3_prepare_v2(db, "SELECT file FROM image WHERE id = ?", -1, &row, NULL) != SQLITE_OK) return NULL;
    sqlite3_bind_text(row, 1, id, -1, SQLITE_STATIC);
    SDL_Texture *texture = NULL;
    if (sqlite3_step(row) == SQLITE_ROW) {
        const char *file = (const char *)sqlite3_column_text(row, 0);
        OwStr path = {(uint32_t)strlen(file), file};
        int32_t size = ow_content_size(path);
        void *bytes = size > 0 ? malloc((size_t)size) : NULL;
        if (bytes && ow_content_read(path, 0, bytes, (uint32_t)size) == size) {
            SDL_Surface *surface = SDL_LoadPNG_IO(SDL_IOFromConstMem(bytes, (size_t)size), true);  // the host copies the bytes
            if (surface) texture = SDL_CreateTextureFromSurface(renderer, surface);
            if (surface) SDL_DestroySurface(surface);
        }
        free(bytes);
    }
    sqlite3_finalize(row);
    return texture;
}

SDL_Texture *art(const char *id) {
    for (int k = 0; k < kept_count; k++) {
        if (strcmp(kept[k].id, id) == 0) return kept[k].texture;
    }
    SDL_Texture *texture = art_load(id);
    if (kept_count < KEPT_MAX && strlen(id) < ID_BYTES) {
        strcpy(kept[kept_count].id, id);
        kept[kept_count++].texture = texture;  // a missing image is kept too, so it is looked up once
    }
    return texture;
}

SDL_Texture *art_of(const char *kind, const char *id) {
    char named[ID_BYTES];
    snprintf(named, sizeof named, "%s/%s", kind, id);
    return art(named);
}

void canvas_begin(void) {
    int width, height;
    SDL_GetRenderOutputSize(renderer, &width, &height);
    scale = SDL_min((float)width / CANVAS_WIDTH, (float)height / CANVAS_HEIGHT);
    left = ((float)width - CANVAS_WIDTH * scale) / 2;
    top = ((float)height - CANVAS_HEIGHT * scale) / 2;
    SDL_SetRenderScale(renderer, 1, 1);
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderFillRect(renderer, &(SDL_FRect){0, 0, (float)width, (float)height});
}

SDL_FRect canvas_rect(float x, float y, float width, float height) {
    return (SDL_FRect){left + x * scale, top + y * scale, width * scale, height * scale};
}

float canvas_scale(void) { return scale; }

static SDL_FRect texture_rect(SDL_Texture *texture, float x, float y, float width, float height) {
    float texture_width, texture_height;
    SDL_GetTextureSize(texture, &texture_width, &texture_height);
    if (width == 0) width = height * texture_width / texture_height;
    if (height == 0) height = width * texture_height / texture_width;
    return canvas_rect(x, y, width, height);
}

void art_draw(SDL_Texture *texture, float x, float y, float width, float height) {
    if (!texture) return;
    SDL_FRect rect = texture_rect(texture, x, y, width, height);
    SDL_RenderTexture(renderer, texture, NULL, &rect);
}

void art_draw_flipped(SDL_Texture *texture, float x, float y, float width, float height) {
    if (!texture) return;
    SDL_FRect rect = texture_rect(texture, x, y, width, height);
    SDL_RenderTextureRotated(renderer, texture, NULL, &rect, 0, NULL, SDL_FLIP_HORIZONTAL);
}

void canvas_fill(float x, float y, float width, float height, SDL_Color color) {
    SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    SDL_FRect rect = canvas_rect(x, y, width, height);
    SDL_RenderFillRect(renderer, &rect);
}
