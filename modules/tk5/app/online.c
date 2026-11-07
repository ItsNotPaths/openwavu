#include "online.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "art.h"
#include "font.h"
#include "grid.h"

enum { LIST_X = 360, LIST_WIDTH = 1200, ROW_TOP = 700, ROW_HEIGHT = 40, ROWS_SHOWN = 6 };
static const SDL_Color ROW = {30, 30, 38, 200}, ROW_LIT = {150, 24, 20, 220};
static const SDL_Color SEAT_COLORS[OW_SIDES] = {{120, 20, 20, 170}, {20, 40, 120, 170}};
static const char *const CONNECTIONS[] = {"OFFLINE", "CONNECTING...", "ONLINE", "COULD NOT CONNECT"};

// The host's settings are the pack's exposed params (pack.toml), as the host serves them. A text param with allowed
// values steps through them; the stage param steps through the catalog's stages; numbers step by a hundredth of their range.
enum { SETTINGS_MAX = 32, NUMBER_STEPS = 100 };
static const char STAGE[] = "stage";

static int lobby_cursor;  // the list: 0 hosts a lobby, then view->lobbies
static bool editing;
static OwParamInfo settings[SETTINGS_MAX];
static int setting_count, setting_cursor, setting_top;
static char values[SETTINGS_MAX][OW_NAME_MAX];
static char refused[64];

// The value of name in a params line ("stage=acid_rain start_health=200"), into value; false when it is not there.
static bool param_of(const char *params, const char *name, char *value, size_t size) {
    size_t length = strlen(name);
    for (const char *at = params; (at = strstr(at, name)); at += length) {
        if ((at != params && at[-1] != ' ') || at[length] != '=') continue;
        size_t end = strcspn(at + length + 1, " ");
        snprintf(value, size, "%.*s", (int)end, at + length + 1);
        return true;
    }
    return false;
}

static void settings_read(const OwHostView *view) {
    setting_count = SDL_min(ow_exposed_params(settings, SETTINGS_MAX), SETTINGS_MAX);
    for (int k = 0; k < setting_count; k++) {
        if (!param_of(view->lobby.params, settings[k].name, values[k], sizeof values[k])) snprintf(values[k], sizeof values[k], "%s", settings[k].fallback);
    }
}

static void settings_send(void) {
    char params[OW_PARAMS_MAX];
    int length = 0;
    for (int k = 0; k < setting_count; k++) {
        length += snprintf(params + length, sizeof params - (size_t)length, "%s%s=%s", k ? " " : "", settings[k].name, values[k]);
    }
    if (length >= (int)sizeof params || ow_lobby_params(params, (uint32_t)length) != 0) snprintf(refused, sizeof refused, "the host refused the settings");
}

// The values a text setting steps through: its allowed values, or for the stage the catalog's stages.
static int choices_of(int k, const T5Catalog *catalog, char choices[][OW_NAME_MAX]) {
    const OwParamInfo *setting = &settings[k];
    int count = 0;
    if (setting->value_count > 0) {
        for (; count < (int)setting->value_count && count < CATALOG_ENTRIES_MAX; count++) {
            int length = ow_exposed_param_value((uint32_t)k, (uint32_t)count, choices[count], OW_NAME_MAX - 1);
            choices[count][SDL_clamp(length, 0, OW_NAME_MAX - 1)] = 0;
        }
    } else if (strcmp(setting->name, STAGE) == 0) {
        for (; count < catalog->stage_count; count++) snprintf(choices[count], OW_NAME_MAX, "%s", catalog->stages[count].id);
    }
    return count;
}

static void setting_change(const T5Catalog *catalog, int direction) {
    const OwParamInfo *setting = &settings[setting_cursor];
    char *value = values[setting_cursor];
    if (setting->kind == OW_PARAM_NUMBER && setting->value_count == 0) {
        double step = SDL_max(1.0, round((setting->max - setting->min) / NUMBER_STEPS));
        snprintf(value, OW_NAME_MAX, "%g", SDL_clamp(atof(value) + direction * step, setting->min, setting->max));
        return;
    }
    static char choices[CATALOG_ENTRIES_MAX][OW_NAME_MAX];
    int count = choices_of(setting_cursor, catalog, choices);
    if (count == 0) return;
    int at = 0;
    while (at < count && strcmp(choices[at], value) != 0) at++;
    snprintf(value, OW_NAME_MAX, "%s", choices[((at < count ? at : 0) + count + direction) % count]);
}

// Back goes offline. Pick on the first row hosts a lobby (its stage first), on a lobby joins it.
enum Online_Step lobbies_step(const OwHostView *view, uint32_t pressed) {
    int rows = 1 + (int)view->lobby_count;
    if (pressed & MENU_BACK) {
        ow_online(0);
        return ONLINE_OFFLINE;
    }
    if (pressed & OW_PAD_UP) lobby_cursor = (lobby_cursor + rows - 1) % rows;
    if (pressed & OW_PAD_DOWN) lobby_cursor = (lobby_cursor + 1) % rows;
    if (lobby_cursor >= rows) lobby_cursor = rows - 1;
    if (!(pressed & MENU_PICK) || view->connection != OW_CONNECTION_ONLINE) return ONLINE_STAY;
    if (lobby_cursor == 0) return ONLINE_HOST;
    ow_lobby_join(view->lobbies[lobby_cursor - 1].id);
    editing = false;
    return ONLINE_JOINED;
}

// Back leaves the lobby. Pick: a seated player picks a fighter, a watcher gets in line. Button 1: back to watching.
// Button 2: the host's settings, where pick sends them and back drops them.
enum Online_Step lobby_step(const OwHostView *view, const T5Catalog *catalog, uint32_t pressed) {
    if (editing) {
        if (pressed & MENU_BACK) editing = false;
        if (pressed & MENU_PICK) {
            editing = false;
            settings_send();
        }
        if (setting_count == 0) return ONLINE_STAY;
        if (pressed & OW_PAD_UP) setting_cursor = (setting_cursor + setting_count - 1) % setting_count;
        if (pressed & OW_PAD_DOWN) setting_cursor = (setting_cursor + 1) % setting_count;
        if (pressed & OW_PAD_LEFT) setting_change(catalog, -1);
        if (pressed & OW_PAD_RIGHT) setting_change(catalog, 1);
        setting_top = SDL_clamp(setting_top, setting_cursor - ROWS_SHOWN + 1, setting_cursor);
        return ONLINE_STAY;
    }
    if (pressed & MENU_BACK) {
        ow_lobby_leave();
        return ONLINE_LEFT;
    }
    if (!view->joined) return ONLINE_STAY;
    if ((pressed & OW_PAD_BUTTON_2) && view->hosting && view->match != OW_MATCH_RUNNING) {
        settings_read(view);
        refused[0] = 0;
        editing = true;
    }
    if (pressed & MENU_PICK) {
        if (!view->watching && !view->seats[view->seat].ready) return ONLINE_PICK;
        if (view->watching && !view->queued) ow_lobby_queue(1);
    }
    if ((pressed & OW_PAD_BUTTON_1) && (!view->watching || view->queued)) ow_lobby_queue(0);
    return ONLINE_STAY;
}

static void header_draw(const OwHostView *view) {
    art_draw(art("net/010"), CANVAS_WIDTH / 2.0f - 260, 24, 520, 0);
    if (!view->joined) text_draw(CANVAS_WIDTH / 2.0f, 150, 36, ALIGN_CENTER, GREY, CONNECTIONS[view->connection < 4 ? view->connection : 0]);
}

static void row_draw(int row, bool lit, const char *left, const char *right) {
    float y = ROW_TOP + (float)row * ROW_HEIGHT;
    canvas_fill(LIST_X, y, LIST_WIDTH, ROW_HEIGHT - 4, lit ? ROW_LIT : ROW);
    text_draw(LIST_X + 24, y + 2, 34, ALIGN_LEFT, lit ? WHITE : GREY, left);
    if (right) text_draw(LIST_X + LIST_WIDTH - 24, y + 2, 34, ALIGN_RIGHT, lit ? WHITE : GREY, right);
}

static void stage_draw(const char *id) {
    float width = 560, height = 386, x = (CANVAS_WIDTH - width) / 2, y = 170;
    SDL_Texture *thumbnail = art_of("stage", id);
    if (thumbnail) art_draw(thumbnail, x, y, width, height);
    else canvas_fill(x, y, width, height, ROW);
    text_draw(CANVAS_WIDTH / 2.0f, y + height + 14, 48, ALIGN_CENTER, YELLOW, shown(id));
}

void lobbies_draw(const OwHostView *view) {
    header_draw(view);
    int rows = 1 + (int)view->lobby_count;
    int first = SDL_max(0, SDL_min(lobby_cursor - ROWS_SHOWN / 2, rows - ROWS_SHOWN - 4));
    for (int row = first; row < rows && row < first + ROWS_SHOWN + 4; row++) {
        char host[OW_NAME_MAX + 8] = "HOST A LOBBY", detail[16 + OW_NAME_MAX] = "";
        if (row > 0) {
            const OwLobby *lobby = &view->lobbies[row - 1];
            char stage[OW_NAME_MAX] = "";
            param_of(lobby->params, STAGE, stage, sizeof stage);
            snprintf(host, sizeof host, "%s", lobby->host);
            snprintf(detail, sizeof detail, "%s   %u/8", shown(stage), lobby->players);
        }
        float y = 240 + (float)(row - first) * 64;
        canvas_fill(LIST_X, y, LIST_WIDTH, 56, row == lobby_cursor ? ROW_LIT : ROW);
        text_draw(LIST_X + 24, y + 6, 44, ALIGN_LEFT, row == lobby_cursor ? WHITE : GREY, host);
        text_draw(LIST_X + LIST_WIDTH - 24, y + 6, 44, ALIGN_RIGHT, row == lobby_cursor ? WHITE : GREY, detail);
    }
    text_hint("3: PICK   4: OFFLINE");
}

static void seat_draw(const OwHostView *view, int side) {
    float x = side == 0 ? 60 : CANVAS_WIDTH - 620, y = 230, width = 560;
    const OwSeat *seat = &view->seats[side];
    canvas_fill(x, y, width, 300, SEAT_COLORS[side]);
    text_draw(x + 20, y + 12, 40, ALIGN_LEFT, WHITE, side == 0 ? "1P" : "2P");
    if (!view->watching && (int)view->seat == side) text_draw(x + width - 20, y + 12, 40, ALIGN_RIGHT, YELLOW, "YOU");
    text_draw(x + width / 2, y + 110, 64, ALIGN_CENTER, seat->name[0] ? WHITE : GREY, seat->name[0] ? seat->name : "OPEN SEAT");
    if (seat->name[0]) text_draw(x + width / 2, y + 210, 44, ALIGN_CENTER, seat->ready ? YELLOW : GREY, seat->ready ? "READY" : "PICKING");
}

static void watchers_draw(const OwHostView *view) {
    char title[32];
    snprintf(title, sizeof title, "WATCHING  %u", view->watcher_count);
    text_draw(LIST_X, ROW_TOP - 52, 40, ALIGN_LEFT, WHITE, title);
    for (uint32_t k = 0; k < view->watcher_count && k < ROWS_SHOWN; k++) {
        const OwWatcher *watcher = &view->watchers[k];
        char place[16];
        snprintf(place, sizeof place, "IN LINE %u", k + 1);  // the line comes first
        row_draw((int)k, false, watcher->name, watcher->queued ? place : NULL);
    }
}

static void settings_draw(void) {
    text_draw(LIST_X, ROW_TOP - 52, 40, ALIGN_LEFT, WHITE, "LOBBY SETTINGS");
    for (int k = setting_top; k < setting_count && k < setting_top + ROWS_SHOWN; k++) {
        char label[OW_NAME_MAX], value[OW_NAME_MAX + 8];
        snprintf(label, sizeof label, "%s", shown(settings[k].name));
        snprintf(value, sizeof value, k == setting_cursor ? "<  %s  >" : "%s", shown(values[k]));
        row_draw(k - setting_top, k == setting_cursor, label, value);
    }
}

static const char *lobby_hint(const OwHostView *view) {
    static char line[128];
    if (editing) return "3: SEND   4: DROP";
    int length = 0;
    if (!view->watching && !view->seats[view->seat].ready) length += snprintf(line + length, sizeof line - (size_t)length, "3: PICK YOUR FIGHTER   ");
    if (view->watching && !view->queued) length += snprintf(line + length, sizeof line - (size_t)length, "3: GET IN LINE   ");
    if (!view->watching || view->queued) length += snprintf(line + length, sizeof line - (size_t)length, "1: WATCH   ");
    if (view->hosting) length += snprintf(line + length, sizeof line - (size_t)length, "2: SETTINGS   ");
    snprintf(line + length, sizeof line - (size_t)length, "4: LEAVE");
    return line;
}

void lobby_draw(const OwHostView *view, const T5Catalog *catalog) {
    header_draw(view);
    if (!view->joined) {
        text_draw(CANVAS_WIDTH / 2.0f, 480, 60, ALIGN_CENTER, WHITE, "JOINING...");
        text_hint("4: LEAVE");
        return;
    }
    char stage[OW_NAME_MAX] = "";
    param_of(view->lobby.params, STAGE, stage, sizeof stage);
    for (int k = 0; editing && k < setting_count; k++) {
        if (strcmp(settings[k].name, STAGE) == 0) snprintf(stage, sizeof stage, "%s", values[k]);
    }
    stage_draw(stage);
    for (int side = 0; side < OW_SIDES; side++) seat_draw(view, side);
    if (editing) settings_draw();
    else watchers_draw(view);
    if (refused[0]) text_draw(LIST_X + LIST_WIDTH, ROW_TOP - 52, 36, ALIGN_RIGHT, YELLOW, refused);
    text_hint(lobby_hint(view));
}
