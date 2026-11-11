// Stock TK5 presenter (gamerender.wasm): the HUD. Outside rollback; reads the sim view.
#include <SDL3/SDL.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "gamerender/presenter.h"
#include "sim/constants.h"

// (hole mod-hud-look :tags tk5mod :needs menu-layouts :sev polish) the HUD is plain debug text and bars, placed by us, not the TK5 look. tekken 6 as well modules/tk6/gamerender/hud.c

enum {
    SCALE = 2,             // debug text glyphs are 8 px, drawn at this scale
    GLYPH = 8,
    BAR_WIDTH = 200, BAR_HEIGHT = 10,
    MID_GAP = 40,          // from the screen middle to each bar
    TOP = 8,
    MARK = 8, MARK_GAP = 4,  // round marks
    FRAMES_PER_SECOND = 60,
};

typedef struct { Uint8 r, g, b; } Color;
static const Color WHITE = {235, 235, 235}, GOLD = {255, 200, 40}, ORANGE = {255, 120, 30}, GREY = {120, 120, 130}, DARK = {60, 30, 30};

static SDL_Renderer *renderer;
static float width;  // of the screen, in scaled pixels

static void color(Color c) { SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, 255); }

static void fill(float x, float y, float w, float h, Color c) {
    color(c);
    SDL_RenderFillRect(renderer, &(SDL_FRect){x, y, w, h});
}

static void text(float x, float y, const char *line, Color c) {
    color(c);
    SDL_RenderDebugText(renderer, x, y, line);
}

static void centered(float y, const char *line, Color c) { text((width - (float)strlen(line) * GLYPH) / 2, y, line, c); }

static int seconds_of(int32_t frames) { return frames > 0 ? (frames + FRAMES_PER_SECOND - 1) / FRAMES_PER_SECOND : 0; }

// Side 1's bar drains toward the middle from the left, side 2's from the right.
static void draw_side(const T5View *view, int side) {
    const T5ViewFighter *fighter = &view->fighters[side];
    float x = side == 0 ? width / 2 - MID_GAP - BAR_WIDTH : width / 2 + MID_GAP;
    char name[T5_NAME_BYTES];
    for (int at = 0; at < T5_NAME_BYTES; at++) name[at] = (char)toupper((unsigned char)fighter->loadout.character[at]);
    text(side == 0 ? x : x + BAR_WIDTH - (float)strlen(name) * GLYPH, TOP, name, WHITE);

    float share = fighter->max_health > 0 ? (float)fighter->health / (float)fighter->max_health : 0;
    share = share < 0 ? 0 : share;
    float y = TOP + GLYPH + 4, shown = BAR_WIDTH * share;
    fill(x, y, BAR_WIDTH, BAR_HEIGHT, DARK);
    fill(side == 0 ? x + BAR_WIDTH - shown : x, y, shown, BAR_HEIGHT, share > 0.25f ? GOLD : ORANGE);

    for (uint32_t mark = 0; mark < view->wins_needed; mark++) {
        float step = (float)mark * (MARK + MARK_GAP);
        float mark_x = side == 0 ? x + BAR_WIDTH - MARK - step : x + step;
        fill(mark_x, y + BAR_HEIGHT + 4, MARK, MARK, (int)mark < fighter->wins ? GOLD : GREY);
    }
}

static int match_winner(const T5View *view) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) if ((uint32_t)view->fighters[side].wins >= view->wins_needed) return side;
    return -1;
}

// The demo's banners: the round and countdown, FIGHT, KO, the match winner.
static void draw_banner(const T5View *view, float middle) {
    char line[64];
    int32_t frame = view->phase_frame;
    switch (view->phase) {
    case T5_PHASE_READY:
        snprintf(line, sizeof line, "ROUND %u", view->round);
        centered(middle - 2 * GLYPH, line, WHITE);
        snprintf(line, sizeof line, "%d", seconds_of(READY_FRAMES.ticks - frame));
        centered(middle, line, GOLD);
        break;
    case T5_PHASE_FIGHT:
        if (frame < FRAMES_PER_SECOND) centered(middle, "FIGHT!", GOLD);
        break;
    case T5_PHASE_KO: centered(middle, view->timer <= 0 ? "TIME UP" : "K.O.", GOLD); break;
    case T5_PHASE_MATCH_END:
    case T5_PHASE_OVER: {
        int winner = match_winner(view);
        if (winner < 0) break;
        snprintf(line, sizeof line, "PLAYER %d WINS", winner + 1);
        centered(middle, line, GOLD);
        break;
    }
    default: break;
    }
}

void t5_hud_draw(const T5View *view) {
    renderer = ow_renderer();
    int pixels_wide = 0, pixels_high = 0;
    SDL_GetRenderOutputSize(renderer, &pixels_wide, &pixels_high);
    SDL_SetRenderScale(renderer, SCALE, SCALE);
    width = (float)pixels_wide / SCALE;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) draw_side(view, side);
    char timer[16];
    snprintf(timer, sizeof timer, "%d", seconds_of(view->timer));
    centered(TOP + GLYPH, timer, WHITE);
    draw_banner(view, (float)pixels_high / SCALE / 3);
}
