// Text in the pack's bold font (font and glyph rows): ASCII only, white glyphs tinted. Menu labels in openwavu's
// Michroma (fonts/michroma.ttf), styled red.
#ifndef T6_FONT_H
#define T6_FONT_H

#include <SDL3/SDL.h>

typedef struct sqlite3 sqlite3;

enum Align { ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT };
extern const SDL_Color WHITE, GREY, YELLOW;

void font_load(sqlite3 *db);
// size: the font's line height on the canvas; y: the line top.
void text_draw(float x, float y, float size, enum Align align, SDL_Color color, const char *text);
// The controls line at the screen's bottom.
void text_hint(const char *line);
// A db id or name for the screen: "dragons_nest" as "DRAGONS NEST". The next call reuses the text.
const char *shown(const char *name);
// A menu label: bold, slanted, red underline, outlined dark; the lit one bright with a red glow.
void display_draw(float x, float y, float size, enum Align align, bool lit, const char *text);

#endif
