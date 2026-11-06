// Stock TK5 entry module (app.wasm): the menus. Reads the pads and the host view, sends intents.
// Mode, then character select, then stage select, then the match; after it, character select again.
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "catalog.h"
#include "grid.h"
#include "loadout.h"
#include "openwavu.h"

// (hole mod-menus :tags tk5mod :needs menu-layouts :sev gap) the menus are SDL debug text, placed by us: no TK5 look; later lobby lists, customization.
// (hole select-renders :tags (tk5mod game) :sev polish) character select shows names, not the ui/select_renders/<id>_left and _right images; a pack has no PNG decode (SDL_LoadPNG_IO returns a surface, which the SDL glue has no handle kind for).

enum { SCALE = GRID_SCALE, LINE = GRID_LINE, TOP = 24, GRID_TOP = TOP + 3 * LINE };
enum Screen { SCREEN_MODE, SCREEN_CHARACTERS, SCREEN_STAGE, SCREEN_MATCH };
enum Mode { MODE_VERSUS_CPU, MODE_VERSUS, MODE_WATCH, MODES };
enum { BOT_SIDE_1 = 1u << 0, BOT_SIDE_2 = 1u << 1 };  // ow_match_local bot_sides

static const char *const MODE_NAMES[MODES] = {"Versus CPU", "Versus", "CPU vs CPU"};
static const uint32_t MODE_BOT_SIDES[MODES] = {BOT_SIDE_2, 0, BOT_SIDE_1 | BOT_SIDE_2};

static T5Catalog catalog;
static enum Screen screen;
static int mode, columns;
static T5Cursor sides[OW_SIDES], stage;
static uint32_t held[OW_SIDES], frames;
static bool match_ran;
static char notice[64];  // the last match's result, or why it did not start

OW_EXPORT(ow_init) int32_t init(void) {
    const char *failed = catalog_load(&catalog);
    if (failed) ow_log((OwStr){(uint32_t)strlen(failed), failed});
    return failed ? 1 : 0;
}

// Versus: each player picks their own side. Otherwise player 0 picks side 1, then side 2.
static int side_owner(int side) { return mode == MODE_VERSUS ? side : 0; }
static bool side_open(int side) { return !sides[side].locked && (mode == MODE_VERSUS || side == 0 || sides[0].locked); }

// Start goes back: it unlocks the player's last locked side, else player 0 leaves for the mode screen.
static void characters_back(int player) {
    for (int side = OW_SIDES - 1; side >= 0; side--) {
        if (sides[side].locked && side_owner(side) == player) {
            sides[side].locked = false;
            return;
        }
    }
    if (player == 0) screen = SCREEN_MODE;
}

static T5Loadout side_loadout(int side) {
    const T5Entry *character = &catalog.characters[cursor_entry(&sides[side], catalog.character_count)];
    T5Loadout loadout = {.costume = sides[side].button <= character->costumes ? sides[side].button : 1};
    strcpy(loadout.character, character->id);
    return loadout;
}

// Offline the picks start a match here. Online (lobby-intents) the same loadout goes to ow_ready, and the
// stage param to the lobby params when this player hosts.
static void submit(void) {
    srand(frames);
    T5Loadout loadouts[OW_SIDES] = {side_loadout(0), side_loadout(1)};
    char params[16 + T5_NAME_BYTES];
    int length = snprintf(params, sizeof params, "stage=%s", catalog.stages[cursor_entry(&stage, catalog.stage_count)].id);
    static const char versus[] = "versus";
    int32_t asked = ow_match_local(versus, sizeof versus - 1, MODE_BOT_SIDES[mode], &loadouts[0], sizeof loadouts[0],
        &loadouts[1], sizeof loadouts[1], params, (uint32_t)length);
    stage.locked = false;
    if (asked != 0) {
        snprintf(notice, sizeof notice, "the host refused the match");
        return;
    }
    screen = SCREEN_MATCH;
    match_ran = false;
}

static void step(const uint32_t pressed[OW_SIDES]) {
    switch (screen) {
    case SCREEN_MODE:
        if (pressed[0] & OW_PAD_UP) mode = (mode + MODES - 1) % MODES;
        if (pressed[0] & OW_PAD_DOWN) mode = (mode + 1) % MODES;
        if (pressed[0] & OW_PAD_BUTTON_1) {
            sides[0].locked = sides[1].locked = false;
            screen = SCREEN_CHARACTERS;
        }
        break;
    case SCREEN_CHARACTERS:
        for (int player = 0; player < OW_SIDES; player++) {
            if (pressed[player] & OW_PAD_START) {
                characters_back(player);
                return;
            }
        }
        bool open[OW_SIDES] = {side_open(0), side_open(1)};  // before any step: the press that locks side 1 is not side 2's
        for (int side = 0; side < OW_SIDES; side++) {
            if (open[side]) cursor_step(&sides[side], catalog.character_count, columns, pressed[side_owner(side)]);
        }
        if (sides[0].locked && sides[1].locked) screen = SCREEN_STAGE;
        break;
    case SCREEN_STAGE:
        if (pressed[0] & OW_PAD_START) {
            sides[OW_SIDES - 1].locked = false;
            screen = SCREEN_CHARACTERS;
            return;
        }
        cursor_step(&stage, catalog.stage_count, columns, pressed[0]);
        if (stage.locked) submit();
        break;
    case SCREEN_MATCH:
        break;
    }
}

// The host starts an asked match before this module's next frame, so a match that never ran did not start: back to the
// stage, with both fighters still picked.
static void match_over(const OwHostView *view) {
    if (!match_ran) {
        snprintf(notice, sizeof notice, "the match did not start");
        screen = SCREEN_STAGE;
        return;
    }
    if (view->winner < 0) snprintf(notice, sizeof notice, "the match was a draw");
    else snprintf(notice, sizeof notice, "side %d won the match", view->winner + 1);
    sides[0].locked = sides[1].locked = false;
    screen = SCREEN_CHARACTERS;
}

static void text(SDL_Renderer *renderer, float y, const char *line) { SDL_RenderDebugText(renderer, TOP, y, line); }

static void draw(SDL_Renderer *renderer) {
    int width, height;
    SDL_GetRenderOutputSize(renderer, &width, &height);
    SDL_SetRenderScale(renderer, SCALE, SCALE);
    SDL_SetRenderDrawColor(renderer, 20, 20, 28, 255);
    SDL_RenderFillRect(renderer, &(SDL_FRect){0, 0, (float)width / SCALE, (float)height / SCALE});
    SDL_SetRenderDrawColor(renderer, 255, 200, 40, 255);
    text(renderer, TOP, "TEKKEN 5 DARK RESURRECTION");
    SDL_SetRenderDrawColor(renderer, 150, 150, 160, 255);
    float bottom = (float)height / SCALE - 2 * LINE;
    text(renderer, bottom - LINE, notice);
    if (screen == SCREEN_MODE) {
        const T5Cursor cursor = {.slot = mode};
        const T5Cursor *cursors[2] = {&cursor, NULL};
        T5Entry entries[MODES];
        for (int line = 0; line < MODES; line++) snprintf(entries[line].name, sizeof entries[line].name, "%s", MODE_NAMES[line]);
        grid_draw(renderer, entries, MODES, NULL, 1, GRID_TOP, cursors);
        text(renderer, bottom, "arrows: move   U: pick");
    } else if (screen == SCREEN_CHARACTERS) {
        const T5Cursor *cursors[2] = {side_open(0) || sides[0].locked ? &sides[0] : NULL, side_open(1) || sides[1].locked ? &sides[1] : NULL};
        text(renderer, TOP + LINE, mode == MODE_VERSUS_CPU && sides[0].locked ? "Pick the CPU's fighter" : "Pick your fighter");
        grid_draw(renderer, catalog.characters, catalog.character_count, "Random", columns, GRID_TOP, cursors);
        text(renderer, bottom, "arrows: move   U I J K: pick with that costume   Enter: back");
    } else if (screen == SCREEN_STAGE) {
        const T5Cursor *cursors[2] = {&stage, NULL};
        text(renderer, TOP + LINE, "Pick the stage");
        grid_draw(renderer, catalog.stages, catalog.stage_count, "Random", columns, GRID_TOP, cursors);
        text(renderer, bottom, "arrows: move   U: pick   Enter: back");
    }
}

// While a match runs the presenter has the screen: no menu, and the buttons are the fighters'.
OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {
    frames++;
    OwHostView view = {0};
    ow_host_view(&view, sizeof view);
    uint32_t pressed[OW_SIDES];
    for (int player = 0; player < OW_SIDES; player++) {
        uint32_t pad = ow_pad((uint32_t)player);
        pressed[player] = pad & ~held[player];  // a button held at the match end does not pick in the menu
        held[player] = pad;
    }
    if (view.match == OW_MATCH_RUNNING) {
        match_ran = true;
        return;
    }
    if (screen == SCREEN_MATCH) match_over(&view);
    SDL_Renderer *renderer = ow_renderer();
    columns = grid_columns(renderer);
    step(pressed);
    draw(renderer);
}
