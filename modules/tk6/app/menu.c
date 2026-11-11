// Stock TK6 entry module (app.wasm): the menus. Reads the pads and the host view, sends intents.
// Title, then mode, then character select, then stage select, then the match; after it, character select again. Online: the lobby
// list, a new lobby's stage or a lobby to join, then the lobby: pick a fighter to ready, the host starts the match, and
// after it the lobby again for the rematch.
#include <SDL3/SDL.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "art.h"
#include "catalog.h"
#include "font.h"
#include "grid.h"
#include "loadout.h"
#include "online.h"
#include "openwavu.h"
#include "ow_db.h"


enum Screen { SCREEN_TITLE, SCREEN_MODE, SCREEN_CHARACTERS, SCREEN_STAGE, SCREEN_MATCH, SCREEN_LOBBIES, SCREEN_LOBBY };
enum Mode { MODE_VERSUS_CPU, MODE_VERSUS, MODE_WATCH, MODE_ONLINE, MODE_EXIT, MODES };
enum { BOT_SIDE_1 = 1u << 0, BOT_SIDE_2 = 1u << 1 };  // ow_match_local bot_sides

static const char *const MODE_NAMES[MODES] = {"VERSUS CPU", "VERSUS", "CPU VS CPU", "ONLINE", "EXIT"};
static const uint32_t MODE_BOT_SIDES[MODES] = {BOT_SIDE_2, 0, BOT_SIDE_1 | BOT_SIDE_2, 0, 0};
static const char VERSUS[] = "versus";  // the pack.toml mode
static const char DB_PATH[] = "tk6.db";
static const T6Grid FACES = {.x = 413, .y = 556, .width = 104, .height = 104, .gap = 6, .columns = 10};
static const T6Grid STAGES = {.x = 165, .y = 170, .width = 200, .height = 138, .gap = 10, .columns = 8};

static T6Catalog catalog;
static enum Screen screen;
static int mode;
static T6Cursor sides[OW_SIDES], stage;
static uint32_t held[OW_SIDES], frames;
static bool match_ran;
static char notice[64];  // the last match's result, or why it did not start
static OwHostView view;   // this frame's

OW_EXPORT(ow_init) int32_t init(void) {
    sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
    const char *failed = db ? catalog_load(db, &catalog) : "the pack has no tk6.db";
    if (db) art_init(db, ow_renderer());
    if (db) font_load(db);
    if (failed) ow_log((OwStr){(uint32_t)strlen(failed), failed});
    return failed ? 1 : 0;
}

// Versus: each player picks their own side. Online: player 0 picks only their own. Otherwise player 0 picks side 1,
// then side 2.
static int side_owner(int side) { return mode == MODE_VERSUS ? side : 0; }
static bool side_open(int side) {
    if (sides[side].locked) return false;
    if (mode == MODE_ONLINE) return side == 0;
    return mode == MODE_VERSUS || side == 0 || sides[0].locked;
}

// Back unlocks the player's last locked side, else player 0 leaves for the mode screen.
static void characters_back(int player) {
    for (int side = OW_SIDES - 1; side >= 0; side--) {
        if (sides[side].locked && side_owner(side) == player) {
            sides[side].locked = false;
            return;
        }
    }
    if (player == 0) screen = mode == MODE_ONLINE ? SCREEN_LOBBY : SCREEN_MODE;
}

static T6Loadout side_loadout(int side) {
    const T6Entry *character = &catalog.characters[cursor_entry(&sides[side], catalog.character_count)];
    uint32_t button = sides[side].button;
    T6Loadout loadout = {.costume = button <= character->costumes ? button : 1};
    strcpy(loadout.character, character->id);
    if (button > character->costumes && character->alternate[0]) {
        loadout.costume = button - character->costumes;
        strcpy(loadout.character, character->alternate);
    }
    return loadout;
}

// The picked stage as params: "stage=<id>".
static int stage_params(char *params, size_t size) {
    return snprintf(params, size, "stage=%s", catalog.stages[cursor_entry(&stage, catalog.stage_count)].id);
}

// Offline the picks start a match here. Online the stage hosts a lobby (submit_lobby).
static void submit(void) {
    srand(frames);
    T6Loadout loadouts[OW_SIDES] = {side_loadout(0), side_loadout(1)};
    char params[16 + T6_NAME_BYTES];
    int length = stage_params(params, sizeof params);
    int32_t asked = ow_match_local(VERSUS, sizeof VERSUS - 1, MODE_BOT_SIDES[mode], &loadouts[0], sizeof loadouts[0],
        &loadouts[1], sizeof loadouts[1], params, (uint32_t)length);
    stage.locked = false;
    if (asked != 0) {
        snprintf(notice, sizeof notice, "the host refused the match");
        return;
    }
    screen = SCREEN_MATCH;
    match_ran = false;
}

static void submit_lobby(void) {
    srand(frames);
    char params[16 + T6_NAME_BYTES];
    int length = stage_params(params, sizeof params);
    stage.locked = false;
    if (ow_lobby_create(VERSUS, sizeof VERSUS - 1, params, (uint32_t)length) != 0) {
        snprintf(notice, sizeof notice, "the host refused the lobby");
        return;
    }
    screen = SCREEN_LOBBY;
}

static void submit_ready(void) {
    srand(frames);
    T6Loadout loadout = side_loadout(0);
    if (ow_ready(&loadout, sizeof loadout) != 0) snprintf(notice, sizeof notice, "the host refused the loadout");
    screen = SCREEN_LOBBY;
}

static void online_step(enum Online_Step next) {
    if (next == ONLINE_OFFLINE) screen = SCREEN_MODE;
    if (next == ONLINE_HOST) {
        stage.locked = false;
        screen = SCREEN_STAGE;
    }
    if (next == ONLINE_JOINED) screen = SCREEN_LOBBY;
    if (next == ONLINE_PICK) {
        sides[0].locked = false;
        screen = SCREEN_CHARACTERS;
    }
    if (next == ONLINE_LEFT) screen = SCREEN_LOBBIES;
}

static void step(const uint32_t pressed[OW_SIDES]) {
    switch (screen) {
    case SCREEN_TITLE:
        if (pressed[0]) screen = SCREEN_MODE;
        break;
    case SCREEN_MODE:
        if (pressed[0] & MENU_BACK) screen = SCREEN_TITLE;
        if (pressed[0] & OW_PAD_UP) mode = (mode + MODES - 1) % MODES;
        if (pressed[0] & OW_PAD_DOWN) mode = (mode + 1) % MODES;
        if ((pressed[0] & MENU_PICK) && mode == MODE_EXIT) ow_exit();
        else if ((pressed[0] & MENU_PICK) && mode == MODE_ONLINE) {
            ow_online(1);
            screen = SCREEN_LOBBIES;
        } else if (pressed[0] & MENU_PICK) {
            sides[0].locked = sides[1].locked = false;
            screen = SCREEN_CHARACTERS;
        }
        break;
    case SCREEN_CHARACTERS:
        for (int player = 0; player < OW_SIDES; player++) {
            if (pressed[player] & MENU_BACK) {
                characters_back(player);
                return;
            }
        }
        bool open[OW_SIDES] = {side_open(0), side_open(1)};  // before any step: the press that locks side 1 is not side 2's
        for (int side = 0; side < OW_SIDES; side++) {
            if (open[side]) cursor_step(&sides[side], catalog.character_count, FACES.columns, pressed[side_owner(side)]);
        }
        if (mode == MODE_ONLINE && sides[0].locked) submit_ready();
        else if (sides[0].locked && sides[1].locked) screen = SCREEN_STAGE;
        break;
    case SCREEN_STAGE:
        if (pressed[0] & MENU_BACK) {
            sides[OW_SIDES - 1].locked = false;
            screen = mode == MODE_ONLINE ? SCREEN_LOBBIES : SCREEN_CHARACTERS;
            return;
        }
        cursor_step(&stage, catalog.stage_count, STAGES.columns, pressed[0]);
        if (stage.locked && mode == MODE_ONLINE) submit_lobby();
        else if (stage.locked) submit();
        break;
    case SCREEN_LOBBIES:
        online_step(lobbies_step(&view, pressed[0]));
        break;
    case SCREEN_LOBBY:
        online_step(lobby_step(&view, &catalog, pressed[0]));
        break;
    case SCREEN_MATCH:
        break;
    }
}

// The host starts an asked match before this module's next frame, so a match that never ran did not start: back to the
// stage, with both fighters still picked.
// Online the host starts lobby matches itself and the lobby follows: back to it for the rematch.
static void match_over(void) {
    if (!match_ran) {
        snprintf(notice, sizeof notice, "the match did not start");
        screen = mode == MODE_ONLINE ? SCREEN_LOBBY : SCREEN_STAGE;
        return;
    }
    if (view.winner < 0) snprintf(notice, sizeof notice, "the match was a draw");
    else snprintf(notice, sizeof notice, "side %d won the match", view.winner + 1);
    sides[0].locked = sides[1].locked = false;
    screen = mode == MODE_ONLINE ? SCREEN_LOBBY : SCREEN_CHARACTERS;
}

static const SDL_Color SHADE = {0, 0, 0, 150};
enum { NOTICE_Y = 975 };

// A slot with no art: a dark tile with the name.
static void tile_named(float x, float y, float width, float height, const char *name) {
    canvas_fill(x, y, width, height, (SDL_Color){20, 20, 28, 230});
    text_draw(x + width / 2, y + height / 2 - 14, 28, ALIGN_CENTER, WHITE, shown(name));
}


// Unlocked cursors pulse.
static Uint8 cursor_alpha(const T6Cursor *cursor) {
    return cursor->locked ? 255 : (Uint8)(150 + 100 * sinf((float)frames * 0.15f));
}

static void draw_title(void) {
    art_draw(art("pic1"), 0, 0, CANVAS_WIDTH, CANVAS_HEIGHT);
    art_draw(art("pic2"), CANVAS_WIDTH / 2.0f - 384, 20, 768, 600);
    // White on black: drawn as backdrop * (1 - image), so the text is black and the black is clear.
    SDL_Texture *copyright = art("boot/000");
    if (copyright) SDL_SetTextureBlendMode(copyright, SDL_ComposeCustomBlendMode(SDL_BLENDFACTOR_ZERO, SDL_BLENDFACTOR_ONE_MINUS_SRC_COLOR,
        SDL_BLENDOPERATION_ADD, SDL_BLENDFACTOR_ZERO, SDL_BLENDFACTOR_ONE, SDL_BLENDOPERATION_ADD));
    art_draw(copyright, CANVAS_WIDTH / 2.0f - 150, 1020, 300, 44);
    if (!art("pic1")) text_draw(CANVAS_WIDTH / 2.0f, 300, 120, ALIGN_CENTER, WHITE, "TEKKEN 6");  // no menu art imported yet
    if (screen == SCREEN_TITLE) {
        SDL_Texture *press_start = art("boot/011");
        if (frames / 30 % 2 == 0 && press_start) art_draw(press_start, CANVAS_WIDTH / 2.0f - 362, 820, 724, 80);
        else if (frames / 30 % 2 == 0) text_draw(CANVAS_WIDTH / 2.0f, 840, 56, ALIGN_CENTER, WHITE, "PRESS START");
        return;
    }
    for (int line = 0; line < MODES; line++) {
        float y = 660 + (float)line * 60;
        display_draw(CANVAS_WIDTH / 2.0f, y, 38, ALIGN_CENTER, line == mode, MODE_NAMES[line]);
    }
}

// Each side keeps the big render of its fighter, facing the middle; another fighter's replaces it.
static struct {
    int slot;
    SDL_Texture *texture;
    bool flipped;
} renders[OW_SIDES] = {{-1}, {-1}};

static void render_draw(int side) {
    const T6Cursor *cursor = &sides[side];
    if (renders[side].slot != cursor->slot) {
        if (renders[side].texture) SDL_DestroyTexture(renders[side].texture);
        renders[side] = (typeof(renders[0])){.slot = cursor->slot};
        if (cursor->slot < catalog.character_count) {
            const char *id = catalog.characters[cursor->slot].id;
            char facing[16 + T6_NAME_BYTES], away[16 + T6_NAME_BYTES];
            snprintf(facing, sizeof facing, "select_renders/%s_%s", id, side == 0 ? "right" : "left");
            snprintf(away, sizeof away, "select_renders/%s_%s", id, side == 0 ? "left" : "right");
            renders[side].texture = art_load(facing);
            if (!renders[side].texture) renders[side] = (typeof(renders[0])){cursor->slot, art_load(away), true};
        }
    }
    float x = side == 0 ? -100 : CANVAS_WIDTH - 908;  // full height: the render's cut edges stay off screen
    if (renders[side].flipped) art_draw_flipped(renders[side].texture, x, 0, 0, CANVAS_HEIGHT);
    else art_draw(renders[side].texture, x, 0, 0, CANVAS_HEIGHT);
    if (cursor->slot >= catalog.character_count) return;
    const T6Entry *character = &catalog.characters[cursor->slot];
    float banner_x = side == 0 ? 40 : CANVAS_WIDTH - 632;
    SDL_Texture *banner = art_of("name", character->id);
    if (banner) art_draw(banner, banner_x, 470, 592, 64);
    else text_draw(banner_x + (side == 0 ? 0 : 592), 476, 56, side == 0 ? ALIGN_LEFT : ALIGN_RIGHT, WHITE, shown(character->name));
}

// The cursor without frame art: a plain box in the side's colour.
static void outline_draw(float x, float y, float width, float height, int side, Uint8 alpha) {
    enum { THICKNESS = 6 };
    SDL_Color color = side == 0 ? (SDL_Color){230, 40, 40, alpha} : (SDL_Color){40, 110, 230, alpha};
    canvas_fill(x, y, width, THICKNESS, color);
    canvas_fill(x, y + height - THICKNESS, width, THICKNESS, color);
    canvas_fill(x, y, THICKNESS, height, color);
    canvas_fill(x + width - THICKNESS, y, THICKNESS, height, color);
}

// Red frames for side 1, blue for side 2, with the side's tag on top.
static void cursors_draw(const T6Grid *grid, const T6Cursor *cursors[OW_SIDES], const char *frames_art[OW_SIDES]) {
    static const char *const TAGS[OW_SIDES] = {"select/005", "select/004"};
    for (int side = 0; side < OW_SIDES; side++) {
        if (!cursors[side]) continue;
        float x, y, grow = grid->width * 0.12f;
        grid_tile(grid, cursors[side]->slot, &x, &y);
        SDL_Texture *frame = art(frames_art[side]);
        if (frame) SDL_SetTextureAlphaMod(frame, cursor_alpha(cursors[side]));
        else outline_draw(x, y, grid->width, grid->height, side, cursor_alpha(cursors[side]));
        art_draw(frame, x - grow, y - grow * grid->height / grid->width, grid->width + 2 * grow, grid->height + 2 * grow * grid->height / grid->width);
        art_draw(art(TAGS[side]), x + (side == 0 ? -grow : grid->width - 40 + grow), y - grow - 28, 0, 28);
    }
}

static void draw_characters(void) {
    art_draw(art("select/058"), 0, 0, CANVAS_WIDTH, CANVAS_HEIGHT);
    const T6Cursor *cursors[OW_SIDES] = {side_open(0) || sides[0].locked ? &sides[0] : NULL, side_open(1) || sides[1].locked ? &sides[1] : NULL};
    for (int side = 0; side < OW_SIDES; side++) {
        if (cursors[side]) render_draw(side);
    }
    art_draw(art("select/151"), CANVAS_WIDTH / 2.0f - 264, 40, 528, 72);
    if (mode == MODE_VERSUS_CPU && sides[0].locked) text_draw(CANVAS_WIDTH / 2.0f, 130, 44, ALIGN_CENTER, YELLOW, "PICK THE CPU'S FIGHTER");
    for (int slot = 0; slot <= catalog.character_count; slot++) {
        float x, y;
        grid_tile(&FACES, slot, &x, &y);
        const char *id = slot < catalog.character_count ? catalog.characters[slot].id : "random";
        SDL_Texture *face = art_of("face", id);
        if (face) art_draw(face, x, y, FACES.width, FACES.height);
        else tile_named(x, y, FACES.width, FACES.height, slot < catalog.character_count ? catalog.characters[slot].name : "random");
    }
    cursors_draw(&FACES, cursors, (const char *[OW_SIDES]){"select/001", "select/000"});
    text_hint("1 2 3: PICK WITH THAT COSTUME   4: BACK");
}

static void draw_stages(void) {
    art_draw(art("select/058"), 0, 0, CANVAS_WIDTH, CANVAS_HEIGHT);
    canvas_fill(0, 0, CANVAS_WIDTH, CANVAS_HEIGHT, SHADE);
    text_draw(CANVAS_WIDTH / 2.0f, 60, 80, ALIGN_CENTER, WHITE, "STAGE SELECT");
    for (int slot = 0; slot <= catalog.stage_count; slot++) {
        float x, y;
        grid_tile(&STAGES, slot, &x, &y);
        if (slot == catalog.stage_count) {
            canvas_fill(x, y, STAGES.width, STAGES.height, (SDL_Color){20, 20, 28, 230});
            art_draw(art("select/229"), x + 8, y + STAGES.height / 2 - 10, STAGES.width - 16, 0);
            continue;
        }
        SDL_Texture *thumbnail = art_of("stage", catalog.stages[slot].id);
        if (thumbnail) art_draw(thumbnail, x, y, STAGES.width, STAGES.height);
        else tile_named(x, y, STAGES.width, STAGES.height, catalog.stages[slot].name);
    }
    cursors_draw(&STAGES, (const T6Cursor *[OW_SIDES]){&stage, NULL}, (const char *[OW_SIDES]){"select/003", NULL});
    const char *name = stage.slot < catalog.stage_count ? catalog.stages[stage.slot].name : "random";
    text_draw(CANVAS_WIDTH / 2.0f, 905, 64, ALIGN_CENTER, YELLOW, shown(name));
    text_hint("3: PICK   4: BACK");
}

static void draw(void) {
    canvas_begin();
    if (screen == SCREEN_TITLE || screen == SCREEN_MODE) draw_title();
    else if (screen == SCREEN_CHARACTERS) draw_characters();
    else if (screen == SCREEN_STAGE) draw_stages();
    else if (screen == SCREEN_LOBBIES) lobbies_draw(&view);
    else if (screen == SCREEN_LOBBY) lobby_draw(&view, &catalog);
    bool lobby_screen = screen == SCREEN_LOBBIES || screen == SCREEN_LOBBY;
    if (screen != SCREEN_TITLE && screen != SCREEN_MODE) text_draw(CANVAS_WIDTH / 2.0f, NOTICE_Y, 40, ALIGN_CENTER, YELLOW, lobby_screen && view.refused[0] ? view.refused : notice);
}

// While a match runs the presenter has the screen: no menu, and the buttons are the fighters'.
OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {
    frames++;
    ow_host_view(&view, sizeof view);
    uint32_t pressed[OW_SIDES];
    for (int player = 0; player < OW_SIDES; player++) {
        uint32_t pad = ow_pad((uint32_t)player);
        pressed[player] = pad & ~held[player];  // a button held at the match end does not pick in the menu
        held[player] = pad;
    }
    if (view.match == OW_MATCH_RUNNING) {
        match_ran = true;
        screen = SCREEN_MATCH;
        return;
    }
    if (screen == SCREEN_MATCH) match_over();
    step(pressed);
    draw();
}
