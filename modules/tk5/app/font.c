#include "font.h"
#include "art.h"
#include "openwavu.h"
#include <SDL3_ttf/SDL_ttf.h>
#include <math.h>
#include <stdlib.h>
#include <ctype.h>
#include "sqlite3.h"

enum { CODES = 128, HINT_Y = 1030 };
const SDL_Color WHITE = {235, 235, 235, 255}, GREY = {150, 150, 160, 255}, YELLOW = {255, 200, 40, 255};
static const char FONT[] = "bold";

static struct {
    SDL_FRect source;
    float x_offset, y_offset, advance;
} glyphs[CODES];
static SDL_Texture *page;
static float line_height = 1;
static const char DISPLAY_FILE[] = "fonts/michroma.ttf";
static TTF_Font *display;
static TTF_Text *label;
static float display_size;

static void display_load(void) {
    OwStr path = {sizeof DISPLAY_FILE - 1, DISPLAY_FILE};
    int32_t size = ow_content_size(path);
    void *bytes = size > 0 ? malloc((size_t)size) : NULL;
    if (bytes && ow_content_read(path, 0, bytes, (uint32_t)size) == size) {
        display = TTF_OpenFontIO(SDL_IOFromConstMem(bytes, (size_t)size), true, 12);  // the host copies the bytes
    }
    free(bytes);
    if (!display) return;
    TTF_SetFontStyle(display, TTF_STYLE_BOLD | TTF_STYLE_ITALIC);  // Michroma has no italic: SDL_ttf slants it
    label = TTF_CreateText(TTF_CreateRendererTextEngine(ow_renderer()), display, "", 0);
}

void font_load(sqlite3 *db) {
    display_load();
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT line_height FROM font WHERE id = ?", -1, &rows, NULL) == SQLITE_OK) {
        sqlite3_bind_text(rows, 1, FONT, -1, SQLITE_STATIC);
        if (sqlite3_step(rows) == SQLITE_ROW) line_height = (float)sqlite3_column_int(rows, 0);
        sqlite3_finalize(rows);
    }
    if (sqlite3_prepare_v2(db, "SELECT code, image, x, y, width, height, x_offset, y_offset, advance FROM glyph WHERE font = ? AND code < ?",
            -1, &rows, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(rows, 1, FONT, -1, SQLITE_STATIC);
    sqlite3_bind_int(rows, 2, CODES);
    while (sqlite3_step(rows) == SQLITE_ROW) {
        int code = sqlite3_column_int(rows, 0);
        if (!page) page = art((const char *)sqlite3_column_text(rows, 1));  // the ASCII glyphs share one page
        glyphs[code].source = (SDL_FRect){(float)sqlite3_column_int(rows, 2), (float)sqlite3_column_int(rows, 3),
            (float)sqlite3_column_int(rows, 4), (float)sqlite3_column_int(rows, 5)};
        glyphs[code].x_offset = (float)sqlite3_column_double(rows, 6);
        glyphs[code].y_offset = (float)sqlite3_column_double(rows, 7);
        glyphs[code].advance = (float)sqlite3_column_double(rows, 8);
    }
    sqlite3_finalize(rows);
}

static float text_width(float size, const char *text) {
    float width = 0;
    for (const unsigned char *code = (const unsigned char *)text; *code; code++) {
        if (*code < CODES) width += glyphs[*code].advance;
    }
    return width * size / line_height;
}

void text_draw(float x, float y, float size, enum Align align, SDL_Color color, const char *text) {
    if (!page) return;
    float zoom = size / line_height;
    if (align == ALIGN_CENTER) x -= text_width(size, text) / 2;
    if (align == ALIGN_RIGHT) x -= text_width(size, text);
    SDL_SetTextureColorMod(page, color.r, color.g, color.b);
    SDL_SetTextureAlphaMod(page, color.a);
    SDL_Renderer *renderer = ow_renderer();
    for (const unsigned char *code = (const unsigned char *)text; *code; code++) {
        if (*code >= CODES) continue;
        SDL_FRect target = canvas_rect(x + glyphs[*code].x_offset * zoom, y + glyphs[*code].y_offset * zoom,
            glyphs[*code].source.w * zoom, glyphs[*code].source.h * zoom);
        SDL_RenderTexture(renderer, page, &glyphs[*code].source, &target);
        x += glyphs[*code].advance * zoom;
    }
}

// The text drawn around (left, top) on a ring of radius px, steps times.
static void ring_draw(float left, float top, float radius, int steps, SDL_Color color) {
    TTF_SetTextColor(label, color.r, color.g, color.b, color.a);
    for (int step = 0; step < steps; step++) {
        float angle = (float)step * 6.2831853f / (float)steps;
        TTF_DrawRendererText(label, left + radius * cosf(angle), top + radius * sinf(angle));
    }
}

void display_draw(float x, float y, float size, enum Align align, bool lit, const char *text) {
    if (!label) return;
    float scale = canvas_scale();
    if (size * scale != display_size) {
        display_size = size * scale;
        TTF_SetFontSize(display, display_size);
    }
    TTF_SetTextString(label, text, 0);
    int width, height;
    TTF_GetTextSize(label, &width, &height);
    SDL_FRect at = canvas_rect(x, y, 0, 0);
    float left = at.x - (align == ALIGN_CENTER ? (float)width / 2 : align == ALIGN_RIGHT ? (float)width : 0);
    if (lit) {
        ring_draw(left, at.y, 12 * scale, 24, (SDL_Color){255, 40, 20, 18});
        ring_draw(left, at.y, 6 * scale, 16, (SDL_Color){255, 60, 30, 40});
    }
    SDL_Color fill = lit ? (SDL_Color){255, 70, 45, 255} : (SDL_Color){140, 22, 18, 255};
    float line_top = at.y + (float)TTF_GetFontAscent(display) + 3 * scale, thickness = 5 * scale, outline = 6 * scale;
    SDL_Renderer *renderer = ow_renderer();
    SDL_SetRenderDrawColor(renderer, 30, 0, 0, 255);
    SDL_RenderFillRect(renderer, &(SDL_FRect){left - outline, line_top - outline, (float)width + 2 * outline, thickness + 2 * outline});
    ring_draw(left, at.y, outline, 20, (SDL_Color){30, 0, 0, 255});
    ring_draw(left, at.y, 0, 1, fill);
    SDL_SetRenderDrawColor(renderer, fill.r, fill.g, fill.b, fill.a);
    SDL_RenderFillRect(renderer, &(SDL_FRect){left, line_top, (float)width, thickness});
}

void text_hint(const char *line) { text_draw(CANVAS_WIDTH / 2.0f, HINT_Y, 36, ALIGN_CENTER, GREY, line); }

const char *shown(const char *name) {
    static char buffer[64];
    int k = 0;
    for (; name[k] && k < (int)sizeof buffer - 1; k++) buffer[k] = name[k] == '_' ? ' ' : (char)toupper(name[k]);
    buffer[k] = 0;
    return buffer;
}
