// An entry module (tests/presentation_test.odin): each frame fills its clip rect, a 2x2 square at (0, 0), in red.
// Its second frame traps.
#include <SDL3/SDL.h>
#include "openwavu.h"

static int frames;

OW_EXPORT(ow_init) int32_t init(void) { return 0; }

OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {
    if (++frames == 2) __builtin_trap();
    SDL_Renderer *r = ow_renderer();
    SDL_SetRenderDrawColor(r, 255, 0, 0, 255);
    SDL_SetRenderClipRect(r, &(SDL_Rect){0, 0, 2, 2});
    SDL_RenderFillRect(r, NULL);
}
