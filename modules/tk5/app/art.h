// The pack's 2D art (db image rows) as textures, drawn on a 1920x1080 canvas fitted into the window.
#ifndef T5_ART_H
#define T5_ART_H

#include <SDL3/SDL.h>

typedef struct sqlite3 sqlite3;

enum { CANVAS_WIDTH = 1920, CANVAS_HEIGHT = 1080 };

// The db stays open for the visit: art loads on first use.
void art_init(sqlite3 *db, SDL_Renderer *renderer);
// The image row's texture, kept for the visit; NULL if the pack has none.
SDL_Texture *art(const char *id);
// The art named <kind>/<id>, like face/paul; kept as art() keeps it.
SDL_Texture *art_of(const char *kind, const char *id);
// Not kept: the caller destroys it. For big art shown one at a time.
SDL_Texture *art_load(const char *id);

// Fits the canvas into the output and clears it black.
void canvas_begin(void);
SDL_FRect canvas_rect(float x, float y, float width, float height);
// Output px per canvas px.
float canvas_scale(void);
// A width or height of 0 follows the texture's aspect. Nothing is drawn for a NULL texture.
void art_draw(SDL_Texture *texture, float x, float y, float width, float height);
void art_draw_flipped(SDL_Texture *texture, float x, float y, float width, float height);
void canvas_fill(float x, float y, float width, float height, SDL_Color color);

#endif
