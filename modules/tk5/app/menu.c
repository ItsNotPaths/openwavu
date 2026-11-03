// Stock TK5 entry module (app.wasm): the menus. Reads the pads and the host view, sends intents.
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "loadout.h"
#include "openwavu.h"
#include "ow_db.h"
#include "sqlite3.h"

// (hole mod-menus :tags tk5mod :needs sdk-ui :sev gap) only a plain menu in SDL debug text: no TK5 look, no character select screen, no stage pick; later server and lobby lists, customization.

enum { CHARACTERS_MAX = 64, SCALE = 3, LINE = 12 };  // LINE: debug text rows are 8 px, at SCALE
enum { ITEM_FIGHTER, ITEM_GHOST, ITEM_CPU, ITEMS };
enum { NO_BOTS = 0, BOT_SIDE_2 = 1u << 1 };  // ow_match_local bot_sides

static const char DB_PATH[] = "tk5.db";
static char characters[CHARACTERS_MAX][T5_NAME_BYTES];
static int character_count;
static int item, fighter;
static uint32_t held, frames;
static const char *refused;  // why the last ask did not start, until the next

// The db's characters, in game order.
OW_EXPORT(ow_init) int32_t init(void) {
    sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
    if (!db) return 1;
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT id FROM character ORDER BY rowid", -1, &rows, NULL) == SQLITE_OK) {
        while (character_count < CHARACTERS_MAX && sqlite3_step(rows) == SQLITE_ROW) {
            const char *id = (const char *)sqlite3_column_text(rows, 0);
            if (id) strncpy(characters[character_count++], id, T5_NAME_BYTES - 1);  // a TEXT key may be NULL
        }
        sqlite3_finalize(rows);
    }
    sqlite3_close(db);
    return character_count > 0 ? 0 : 1;
}

// A versus match of the picked fighter against a random other one (itself when it is the only one).
static void start(uint32_t bot_sides) {
    srand(frames);
    int others = character_count - 1;
    int opponent = others > 0 ? (fighter + 1 + rand() % others) % character_count : fighter;
    T5Loadout sides[2] = {{.costume = 1}, {.costume = 1}};
    strcpy(sides[0].character, characters[fighter]);
    strcpy(sides[1].character, characters[opponent]);
    static const char mode[] = "versus", params[] = "stage=0";
    int32_t asked = ow_match_local(mode, sizeof mode - 1, bot_sides, &sides[0], sizeof sides[0], &sides[1], sizeof sides[1],
        params, sizeof params - 1);
    refused = asked == 0 ? NULL : "the host refused the match";
}

static void step(uint32_t pressed) {
    if (pressed & OW_PAD_UP) item = (item + ITEMS - 1) % ITEMS;
    if (pressed & OW_PAD_DOWN) item = (item + 1) % ITEMS;
    if (item == ITEM_FIGHTER && pressed & OW_PAD_LEFT) fighter = (fighter + character_count - 1) % character_count;
    if (item == ITEM_FIGHTER && pressed & OW_PAD_RIGHT) fighter = (fighter + 1) % character_count;
    if (!(pressed & (OW_PAD_BUTTON_1 | OW_PAD_START))) return;
    if (item == ITEM_GHOST) start(NO_BOTS);
    if (item == ITEM_CPU) start(BOT_SIDE_2);
}

static const char *match_line(void) {
    static char line[64];
    OwHostView view = {0};
    ow_host_view(&view, sizeof view);
    if (view.match == OW_MATCH_RUNNING) return "a match is running";
    if (view.match == OW_MATCH_ENDED) {
        snprintf(line, sizeof line, view.winner < 0 ? "the match was a draw" : "side %d won the match", view.winner + 1);
        return line;
    }
    return refused ? refused : "";
}

OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {
    frames++;
    uint32_t pad = ow_pad(0);
    step(pad & ~held);
    held = pad;

    SDL_Renderer *renderer = ow_renderer();
    int width, height;
    SDL_GetRenderOutputSize(renderer, &width, &height);
    SDL_SetRenderScale(renderer, SCALE, SCALE);
    float x = 24, y = 24;
    SDL_SetRenderDrawColor(renderer, 20, 20, 28, 255);
    SDL_RenderFillRect(renderer, &(SDL_FRect){0, 0, (float)width / SCALE, (float)height / SCALE});
    SDL_SetRenderDrawColor(renderer, 255, 200, 40, 255);
    SDL_RenderDebugText(renderer, x, y, "TEKKEN 5 DARK RESURRECTION");
    char fighter_line[64];
    snprintf(fighter_line, sizeof fighter_line, "Fighter   < %s >", characters[fighter]);
    const char *lines[ITEMS] = {fighter_line, "Ghost match vs random", "Versus CPU vs random"};
    for (int line = 0; line < ITEMS; line++) {
        float row = y + (line + 2) * LINE;
        if (line == item) {
            SDL_SetRenderDrawColor(renderer, 120, 30, 30, 255);
            SDL_RenderFillRect(renderer, &(SDL_FRect){x - 4, row - 2, 200, LINE});
        }
        SDL_SetRenderDrawColor(renderer, 235, 235, 235, 255);
        SDL_RenderDebugText(renderer, x, row, lines[line]);
    }
    SDL_SetRenderDrawColor(renderer, 150, 150, 160, 255);
    SDL_RenderDebugText(renderer, x, y + (ITEMS + 3) * LINE, match_line());
    SDL_RenderDebugText(renderer, x, y + (ITEMS + 5) * LINE, "arrows: move   U or Enter: pick");
}
