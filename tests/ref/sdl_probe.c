// A presentation module that draws through the host's SDL imports (tests/sdl_test.odin).
#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <stdlib.h>
#include "openwavu.h"

static TTF_Font *font;
static TTF_Text *text;

// A red square at (0, 0) and a green texture at (8, 0), both 4x4.
OW_EXPORT(draw) int draw(void) {
    SDL_Renderer *r = ow_renderer();
    Uint32 green[4] = {0xff00ff00, 0xff00ff00, 0xff00ff00, 0xff00ff00};
    SDL_Texture *t = SDL_CreateTexture(r, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, 2, 2);
    bool ok = t && SDL_UpdateTexture(t, NULL, green, 8);
    ok = ok && SDL_SetRenderDrawColor(r, 255, 0, 0, 255) && SDL_RenderFillRect(r, &(SDL_FRect){0, 0, 4, 4});
    ok = ok && SDL_RenderTexture(r, t, NULL, &(SDL_FRect){8, 0, 4, 4});
    SDL_DestroyTexture(t);
    return ok;
}

// The pack's font.ttf as a stream; NULL if it does not read.
static SDL_IOStream *font_stream(void) {
    int32_t size = ow_content_size(OW_STR("font.ttf"));
    if (size <= 0) return NULL;
    void *bytes = malloc(size);
    SDL_IOStream *stream = ow_content_read(OW_STR("font.ttf"), 0, bytes, size) == size ? SDL_IOFromConstMem(bytes, size) : NULL;
    free(bytes);  // the host copied it
    return stream;
}

// "Hi" in white from the pack's font, at (0, 8).
OW_EXPORT(text) int draw_text(void) {
    font = TTF_OpenFontIO(font_stream(), true, 12);
    TTF_TextEngine *engine = TTF_CreateRendererTextEngine(ow_renderer());
    text = TTF_CreateText(engine, font, "Hi", 0);
    return text && TTF_SetTextColor(text, 255, 255, 255, 255) && TTF_DrawRendererText(text, 0, 8);
}

OW_EXPORT(bad_rect) void bad_rect(void) {
    SDL_RenderFillRect(ow_renderer(), (const SDL_FRect *)0xfffffff8);
}

OW_EXPORT(bad_handle) void bad_handle(void) {
    SDL_RenderTexture(ow_renderer(), (SDL_Texture *)0x7777, NULL, NULL);
}

// A 2x2 texture's 16 bytes of pixels, starting 8 bytes before the end of memory.
OW_EXPORT(pixels_past_memory) void pixels_past_memory(void) {
    SDL_Texture *t = SDL_CreateTexture(ow_renderer(), SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, 2, 2);
    SDL_UpdateTexture(t, NULL, (void *)(__builtin_wasm_memory_size(0) * 65536 - 8), 8);
}

// The first font reads the stream; a second that would close it with itself must not get it.
OW_EXPORT(closeio_on_shared_stream) void closeio_on_shared_stream(void) {
    SDL_IOStream *stream = font_stream();
    TTF_OpenFontIO(stream, false, 12);
    TTF_OpenFontIO(stream, true, 12);
}

OW_EXPORT(font_as_texture) void font_as_texture(void) {
    SDL_RenderTexture(ow_renderer(), (SDL_Texture *)font, NULL, NULL);
}

// Closing the font also ends its text, so drawing the text must stop the module, not reach SDL.
OW_EXPORT(text_after_font_closed) void text_after_font_closed(void) {
    TTF_CloseFont(font);
    TTF_DrawRendererText(text, 0, 0);
}
