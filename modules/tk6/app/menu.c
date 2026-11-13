// Stock TK6 entry module (app.wasm): plain text list menus. Reads the pads and the host view, sends intents.
// Offline: mode, a fighter for each side, stage, the match, then the fighters again. Online: the lobby list, a new
// lobby's stage or a lobby to join, then the lobby, where a seated player picks a fighter to ready.
#include <SDL3/SDL.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "loadout.h"
#include "openwavu.h"
#include "ow_db.h"
#include "sqlite3.h"

enum Screen { SCREEN_MODE, SCREEN_FIGHTER, SCREEN_STAGE, SCREEN_MATCH, SCREEN_LOBBIES, SCREEN_PASSWORD, SCREEN_LOBBY, SCREEN_SETTINGS, SCREEN_MEMBERS, SCREENS };
enum Mode { MODE_VERSUS_CPU, MODE_VERSUS, MODE_WATCH, MODE_ONLINE, MODE_EXIT, MODES };
enum Action { ACTION_PICK_FIGHTER, ACTION_QUEUE, ACTION_WATCH, ACTION_SETTINGS, ACTION_PASSWORD, ACTION_KICK, ACTION_BAN, ACTION_LEAVE };
enum { BOT_SIDE_1 = 1u << 0, BOT_SIDE_2 = 1u << 1 };  // ow_match_local bot_sides
enum { MENU_PICK = OW_PAD_BUTTON_3 | OW_PAD_START, MENU_BACK = OW_PAD_BUTTON_4 | OW_PAD_BACK };
enum { ENTRIES_MAX = 64, ROWS_MAX = 80, LINES_MAX = 12, TEXT_MAX = 64, ROWS_SHOWN = 26 };
enum { PASSWORD_DIGITS = 4, DIGIT_VALUES = 10, SETTINGS_MAX = 32, NUMBER_STEPS = 100 };
enum { RANDOM = -1 };  // a row's item for Random

static const char *const MODE_NAMES[MODES] = {"VERSUS CPU", "VERSUS", "CPU VS CPU", "ONLINE", "EXIT"};
static const uint32_t MODE_BOT_SIDES[MODES] = {BOT_SIDE_2, 0, BOT_SIDE_1 | BOT_SIDE_2, 0, 0};
static const char *const CONNECTIONS[] = {"OFFLINE", "CONNECTING...", "ONLINE", "COULD NOT CONNECT"};
static const char VERSUS[] = "versus";  // the pack.toml mode
static const char DB_PATH[] = "tk6.db";
static const char STAGE[] = "stage";    // the pack.toml param
static const float TEXT_SCALE = 3;
static const float LINE = 12;           // debug text line height, before the scale
static const float VALUE_COLUMN = 300;  // before the scale

typedef struct {
    char id[T6_NAME_BYTES], name[T6_NAME_BYTES];
    int costumes;
} Entry;

// What a screen shows: a title, lines of state, and the rows the cursor picks from. item: the fighter, stage, lobby,
// member, setting or action of the row.
typedef struct {
    char label[TEXT_MAX], value[TEXT_MAX];
    int item;
} Row;

static struct {
    char title[TEXT_MAX], lines[LINES_MAX][TEXT_MAX * 2];
    Row rows[ROWS_MAX];
    int line_count, row_count;
    const char *hint;
} list;

static Entry fighters[ENTRIES_MAX], stages[ENTRIES_MAX];
static int fighter_count, stage_count;
static enum Screen screen;
static enum Mode mode;
static int cursors[SCREENS];
static int side, costume = 1;  // the side picking a fighter; the costume of the fighter under the cursor, 1..
static T6Loadout picks[OW_SIDES];
static uint32_t held[OW_SIDES], frames;
static bool match_ran, was_joined, banning;
static char notice[TEXT_MAX];  // the last match's result, or why something was refused
static OwHostView view;        // this frame's
static int password[PASSWORD_DIGITS], password_place;
static uint32_t joining;  // the locked lobby the password opens; 0: the host's own password
static OwParamInfo settings[SETTINGS_MAX];
static int setting_count;
static char values[SETTINGS_MAX][OW_NAME_MAX];

// --- db

static int load_entries(sqlite3 *db, const char *sql, Entry *entries) {
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, sql, -1, &rows, NULL) != SQLITE_OK) return 0;
    int count = 0;
    while (count < ENTRIES_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        Entry *entry = &entries[count++];
        snprintf(entry->id, sizeof entry->id, "%s", (const char *)sqlite3_column_text(rows, 0));
        snprintf(entry->name, sizeof entry->name, "%s", (const char *)sqlite3_column_text(rows, 1));
        entry->costumes = sqlite3_column_int(rows, 2);
    }
    sqlite3_finalize(rows);
    return count;
}

OW_EXPORT(ow_init) int32_t init(void) {
    sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
    if (!db) return 1;
    fighter_count = load_entries(db,
        "SELECT id, name, (SELECT count(*) FROM costume WHERE costume.character = character.id) FROM character ORDER BY rowid", fighters);
    stage_count = load_entries(db, "SELECT id, name, 0 FROM stage ORDER BY rowid", stages);
    sqlite3_close(db);
    return fighter_count > 0 && stage_count > 0 ? 0 : 1;
}

// --- the list

static void list_begin(const char *title, const char *hint) {
    snprintf(list.title, sizeof list.title, "%s", title);
    list.hint = hint;
    list.line_count = list.row_count = 0;
}

static void line_add(const char *text) {
    if (list.line_count < LINES_MAX) snprintf(list.lines[list.line_count++], sizeof list.lines[0], "%s", text);
}

static void row_add(const char *label, const char *value, int item) {
    if (list.row_count == ROWS_MAX) return;
    Row *row = &list.rows[list.row_count++];
    snprintf(row->label, sizeof row->label, "%s", label);
    snprintf(row->value, sizeof row->value, "%s", value ? value : "");
    row->item = item;
}

static const Row *row_picked(void) { return list.row_count > 0 ? &list.rows[cursors[screen]] : NULL; }

static void text_at(float x, float y, const char *text) { SDL_RenderDebugText(ow_renderer(), x, y, text); }

static void list_draw(void) {
    SDL_Renderer *renderer = ow_renderer();
    int width, height;
    SDL_GetRenderOutputSize(renderer, &width, &height);
    SDL_SetRenderScale(renderer, 1, 1);
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderFillRect(renderer, &(SDL_FRect){0, 0, (float)width, (float)height});
    SDL_SetRenderScale(renderer, TEXT_SCALE, TEXT_SCALE);
    float x = 8, y = 8;
    SDL_SetRenderDrawColor(renderer, 255, 220, 80, 255);
    text_at(x, y, list.title);
    y += LINE * 1.5f;
    SDL_SetRenderDrawColor(renderer, 170, 170, 180, 255);
    for (int line = 0; line < list.line_count; line++, y += LINE) text_at(x, y, list.lines[line]);
    if (list.line_count) y += LINE / 2;
    int cursor = cursors[screen], first = SDL_clamp(cursor - ROWS_SHOWN / 2, 0, SDL_max(0, list.row_count - ROWS_SHOWN));
    for (int row = first; row < list.row_count && row < first + ROWS_SHOWN; row++, y += LINE) {
        bool lit = row == cursor;
        SDL_SetRenderDrawColor(renderer, 255, 255, 255, lit ? 255 : 150);
        if (lit) text_at(x, y, ">");
        text_at(x + 16, y, list.rows[row].label);
        text_at(x + VALUE_COLUMN, y, list.rows[row].value);
    }
    SDL_SetRenderDrawColor(renderer, 255, 220, 80, 255);
    text_at(x, y + LINE, notice);
    SDL_SetRenderDrawColor(renderer, 120, 120, 130, 255);
    if (list.hint) text_at(x, y + LINE * 2.5f, list.hint);
}

// --- params

// The value of name in a params line ("stage=stage_00 round_time=60"), into value; false when it is not there.
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

static const Entry *entry_of(const Entry *entries, int count, int item) { return &entries[item == RANDOM ? rand() % count : item]; }

static int stage_params(char *params, size_t size, int item) {
    return snprintf(params, size, "%s=%s", STAGE, entry_of(stages, stage_count, item)->id);
}

// --- offline

// Versus: player 2 picks side 2. Otherwise player 1 picks both.
static int player_of_screen(void) { return screen == SCREEN_FIGHTER && mode == MODE_VERSUS && side == 1 ? 1 : 0; }

static void build_mode(void) {
    list_begin("TEKKEN 6", "3: PICK");
    for (int line = 0; line < MODES; line++) row_add(MODE_NAMES[line], NULL, line);
}

static void step_mode(uint32_t pressed) {
    if (!(pressed & MENU_PICK)) return;
    mode = (enum Mode)row_picked()->item;
    notice[0] = 0;
    srand(frames);  // Random picks
    if (mode == MODE_EXIT) ow_exit();
    else if (mode == MODE_ONLINE) {
        ow_online(1);
        screen = SCREEN_LOBBIES;
    } else {
        side = 0;
        screen = SCREEN_FIGHTER;
    }
}

static void build_fighter(void) {
    static const char *const TITLES[OW_SIDES] = {"SIDE 1 FIGHTER", "SIDE 2 FIGHTER"};
    bool bot = mode != MODE_ONLINE && (MODE_BOT_SIDES[mode] & (1u << side));
    char title[TEXT_MAX];
    snprintf(title, sizeof title, "%s%s", mode == MODE_ONLINE ? "YOUR FIGHTER" : TITLES[side], bot ? " (CPU)" : "");
    list_begin(title, "3: PICK   LEFT/RIGHT: COSTUME   4: BACK");
    for (int fighter = 0; fighter < fighter_count; fighter++) {
        char value[TEXT_MAX] = "";
        if (fighter == cursors[SCREEN_FIGHTER] && fighters[fighter].costumes > 1) snprintf(value, sizeof value, "< COSTUME %d >", costume);
        row_add(fighters[fighter].name, value, fighter);
    }
    row_add("RANDOM", NULL, RANDOM);
}

static void step_fighter(uint32_t pressed) {
    const Row *row = row_picked();
    int costumes = row->item == RANDOM ? 1 : SDL_max(fighters[row->item].costumes, 1);
    if (pressed & (OW_PAD_UP | OW_PAD_DOWN)) costume = 1;
    if (pressed & OW_PAD_LEFT) costume = (costume + costumes - 2) % costumes + 1;
    if (pressed & OW_PAD_RIGHT) costume = costume % costumes + 1;
    if (pressed & MENU_BACK) {
        if (mode == MODE_ONLINE) screen = SCREEN_LOBBY;
        else if (side == 1) side = 0;
        else screen = SCREEN_MODE;
        return;
    }
    if (!(pressed & MENU_PICK)) return;
    T6Loadout *pick = &picks[side];
    const Entry *fighter = entry_of(fighters, fighter_count, row->item);
    snprintf(pick->character, sizeof pick->character, "%s", fighter->id);
    pick->costume = row->item == RANDOM ? 1 : (uint32_t)costume;
    if (mode == MODE_ONLINE) {
        if (ow_ready(pick, sizeof *pick) != 0) snprintf(notice, sizeof notice, "the host refused the fighter");
        screen = SCREEN_LOBBY;
    } else if (side == 0) {
        side = 1;
    } else {
        screen = SCREEN_STAGE;
    }
}

static void build_stage(void) {
    list_begin("STAGE", "3: PICK   4: BACK");
    for (int stage = 0; stage < stage_count; stage++) row_add(stages[stage].name, NULL, stage);
    row_add("RANDOM", NULL, RANDOM);
}

// Offline the stage starts the match; online it hosts a lobby.
static void step_stage(uint32_t pressed) {
    if (pressed & MENU_BACK) screen = mode == MODE_ONLINE ? SCREEN_LOBBIES : SCREEN_FIGHTER;
    if (!(pressed & MENU_PICK)) return;
    char params[16 + T6_NAME_BYTES];
    int length = stage_params(params, sizeof params, row_picked()->item);
    if (mode == MODE_ONLINE) {
        if (ow_lobby_create(VERSUS, sizeof VERSUS - 1, params, (uint32_t)length) != 0) snprintf(notice, sizeof notice, "the host refused the lobby");
        else screen = SCREEN_LOBBY;
        return;
    }
    int32_t asked = ow_match_local(VERSUS, sizeof VERSUS - 1, MODE_BOT_SIDES[mode], &picks[0], sizeof picks[0], &picks[1],
        sizeof picks[1], params, (uint32_t)length);
    if (asked != 0) {
        snprintf(notice, sizeof notice, "the host refused the match");
        return;
    }
    screen = SCREEN_MATCH;
    match_ran = false;
}

// The host starts an asked match before this module's next frame, so a match that never ran did not start.
static void match_over(void) {
    if (!match_ran) snprintf(notice, sizeof notice, "the match did not start");
    else if (view.winner < 0) snprintf(notice, sizeof notice, "the match was a draw");
    else snprintf(notice, sizeof notice, "side %d won the match", view.winner + 1);
    side = 0;
    screen = mode == MODE_ONLINE ? SCREEN_LOBBY : match_ran ? SCREEN_FIGHTER : SCREEN_STAGE;
}

// --- online

static uint32_t password_code(void) {
    uint32_t code = 0;
    for (int digit = 0; digit < PASSWORD_DIGITS; digit++) code = code * DIGIT_VALUES + (uint32_t)password[digit];
    return code;
}

static void password_open(uint32_t lobby, uint32_t code) {
    joining = lobby;
    for (int digit = PASSWORD_DIGITS - 1; digit >= 0; digit--, code /= DIGIT_VALUES) password[digit] = (int)(code % DIGIT_VALUES);
    password_place = 0;
    screen = SCREEN_PASSWORD;
}

static void build_lobbies(void) {
    list_begin("ONLINE", "3: PICK   4: OFFLINE");
    line_add(CONNECTIONS[view.connection < 4 ? view.connection : 0]);
    if (view.refused[0]) line_add(view.refused);
    row_add("HOST A LOBBY", NULL, RANDOM);
    for (uint32_t lobby = 0; lobby < view.lobby_count; lobby++) {
        const OwLobby *shown = &view.lobbies[lobby];
        char stage[OW_NAME_MAX] = "", value[TEXT_MAX];
        param_of(shown->params, STAGE, stage, sizeof stage);
        bool locked = view.locked_lobbies & (1u << lobby);
        snprintf(value, sizeof value, "%s  %u/8%s", stage, shown->players, locked ? "  LOCKED" : "");
        row_add(shown->host, value, (int)lobby);
    }
}

static void step_lobbies(uint32_t pressed) {
    if (pressed & MENU_BACK) {
        ow_online(0);
        screen = SCREEN_MODE;
        return;
    }
    if (!(pressed & MENU_PICK) || view.connection != OW_CONNECTION_ONLINE) return;
    int lobby = row_picked()->item;
    if (lobby == RANDOM) screen = SCREEN_STAGE;
    else if (view.locked_lobbies & (1u << lobby)) password_open(view.lobbies[lobby].id, 0);
    else {
        ow_lobby_join(view.lobbies[lobby].id, 0);
        screen = SCREEN_LOBBY;
    }
}

// A bike lock: up and down turn a digit, left and right pick which. 0000 is none.
static void build_password(void) {
    list_begin(joining ? "THIS LOBBY IS LOCKED" : "LOBBY PASSWORD", "UP/DOWN: TURN   LEFT/RIGHT: DIGIT   3: SET   4: BACK");
    char digits[TEXT_MAX];
    int length = 0;
    for (int digit = 0; digit < PASSWORD_DIGITS; digit++) {
        length += snprintf(digits + length, sizeof digits - (size_t)length, digit == password_place ? "[%d]" : " %d ", password[digit]);
    }
    row_add("PASSWORD", digits, 0);
}

static void step_password(uint32_t pressed) {
    int *digit = &password[password_place];
    if (pressed & OW_PAD_UP) *digit = (*digit + 1) % DIGIT_VALUES;
    if (pressed & OW_PAD_DOWN) *digit = (*digit + DIGIT_VALUES - 1) % DIGIT_VALUES;
    if (pressed & OW_PAD_LEFT) password_place = (password_place + PASSWORD_DIGITS - 1) % PASSWORD_DIGITS;
    if (pressed & OW_PAD_RIGHT) password_place = (password_place + 1) % PASSWORD_DIGITS;
    if (pressed & MENU_BACK) screen = joining ? SCREEN_LOBBIES : SCREEN_LOBBY;
    if (!(pressed & MENU_PICK)) return;
    if (joining) ow_lobby_join(joining, password_code());
    else if (ow_lobby_lock(password_code()) != 0) snprintf(notice, sizeof notice, "the host refused the password");
    screen = SCREEN_LOBBY;
}

static void seat_line(int seat_side) {
    const OwSeat *seat = &view.seats[seat_side];
    char line[TEXT_MAX * 2];
    bool you = !view.watching && (int)view.seat == seat_side;
    snprintf(line, sizeof line, "%dP  %-20s %s%s", seat_side + 1, seat->name[0] ? seat->name : "OPEN SEAT",
        !seat->name[0] ? "" : seat->ready ? "READY" : "PICKING", you ? "  (YOU)" : "");
    line_add(line);
}

static void build_lobby(void) {
    list_begin("LOBBY", "3: PICK   4: LEAVE");
    if (!view.joined) {
        line_add("JOINING...");
        row_add("LEAVE", NULL, ACTION_LEAVE);
        return;
    }
    char line[TEXT_MAX * 2], stage[OW_NAME_MAX] = "";
    param_of(view.lobby.params, STAGE, stage, sizeof stage);
    snprintf(line, sizeof line, "%s  STAGE %s", view.lobby.host, stage);
    line_add(line);
    for (int seat_side = 0; seat_side < OW_SIDES; seat_side++) seat_line(seat_side);
    for (uint32_t watcher = 0; watcher < view.watcher_count; watcher++) {
        snprintf(line, sizeof line, "    %-20s %s", view.watchers[watcher].name, view.watchers[watcher].queued ? "IN LINE" : "WATCHING");
        line_add(line);
    }
    if (!view.watching && !view.seats[view.seat].ready) row_add("PICK YOUR FIGHTER", NULL, ACTION_PICK_FIGHTER);
    if (view.watching && !view.queued) row_add("GET IN LINE", NULL, ACTION_QUEUE);
    if (!view.watching || view.queued) row_add("WATCH", NULL, ACTION_WATCH);
    if (view.hosting && view.match != OW_MATCH_RUNNING) {
        row_add("SETTINGS", NULL, ACTION_SETTINGS);
        row_add("PASSWORD", view.password ? "SET" : "NONE", ACTION_PASSWORD);
        row_add("KICK", NULL, ACTION_KICK);
        row_add("BAN", NULL, ACTION_BAN);
    }
    row_add("LEAVE", NULL, ACTION_LEAVE);
}

static void settings_read(void) {
    setting_count = SDL_min(ow_exposed_params(settings, SETTINGS_MAX), SETTINGS_MAX);
    for (int setting = 0; setting < setting_count; setting++) {
        if (!param_of(view.lobby.params, settings[setting].name, values[setting], sizeof values[setting])) {
            snprintf(values[setting], sizeof values[setting], "%s", settings[setting].fallback);
        }
    }
}

// A player put out of the lobby is back at the list.
static void step_lobby(uint32_t pressed) {
    if (was_joined && !view.joined) {
        screen = SCREEN_LOBBIES;
        return;
    }
    int action = (pressed & MENU_BACK) ? ACTION_LEAVE : (pressed & MENU_PICK) ? row_picked()->item : -1;
    switch (action) {
    case ACTION_PICK_FIGHTER:
        screen = SCREEN_FIGHTER;
        break;
    case ACTION_QUEUE:
        ow_lobby_queue(1);
        break;
    case ACTION_WATCH:
        ow_lobby_queue(0);
        break;
    case ACTION_SETTINGS:
        settings_read();
        screen = SCREEN_SETTINGS;
        break;
    case ACTION_PASSWORD:
        password_open(0, view.password);
        break;
    case ACTION_KICK:
    case ACTION_BAN:
        banning = action == ACTION_BAN;
        screen = SCREEN_MEMBERS;
        break;
    case ACTION_LEAVE:
        ow_lobby_leave();
        screen = SCREEN_LOBBIES;
        break;
    default:
        break;
    }
}

static void build_settings(void) {
    list_begin("LOBBY SETTINGS", "LEFT/RIGHT: CHANGE   3: SEND   4: DROP");
    for (int setting = 0; setting < setting_count; setting++) {
        char value[TEXT_MAX];
        snprintf(value, sizeof value, "< %s >", values[setting]);
        row_add(settings[setting].name, value, setting);
    }
    row_add("SEND", NULL, RANDOM);
}

// A text setting steps through its allowed values, the stage through the stages; numbers by a hundredth of their range.
static void setting_change(int setting, int direction) {
    const OwParamInfo *info = &settings[setting];
    char *value = values[setting];
    if (info->kind == OW_PARAM_NUMBER && info->value_count == 0) {
        double step = SDL_max(1.0, round((info->max - info->min) / NUMBER_STEPS));
        snprintf(value, OW_NAME_MAX, "%g", SDL_clamp(atof(value) + direction * step, info->min, info->max));
        return;
    }
    static char choices[ENTRIES_MAX][OW_NAME_MAX];
    int count = 0;
    if (info->value_count > 0) {
        for (; count < (int)info->value_count && count < ENTRIES_MAX; count++) {
            int length = ow_exposed_param_value((uint32_t)setting, (uint32_t)count, choices[count], OW_NAME_MAX - 1);
            choices[count][SDL_clamp(length, 0, OW_NAME_MAX - 1)] = 0;
        }
    } else if (strcmp(info->name, STAGE) == 0) {
        for (; count < stage_count; count++) snprintf(choices[count], OW_NAME_MAX, "%s", stages[count].id);
    }
    if (count == 0) return;
    int at = 0;
    while (at < count && strcmp(choices[at], value) != 0) at++;
    snprintf(value, OW_NAME_MAX, "%s", choices[((at < count ? at : 0) + count + direction) % count]);
}

static void settings_send(void) {
    char params[OW_PARAMS_MAX];
    int length = 0;
    for (int setting = 0; setting < setting_count && length < (int)sizeof params; setting++) {
        length += snprintf(params + length, sizeof params - (size_t)length, "%s%s=%s", setting ? " " : "", settings[setting].name, values[setting]);
    }
    if (length >= (int)sizeof params || ow_lobby_params(params, (uint32_t)length) != 0) snprintf(notice, sizeof notice, "the host refused the settings");
}

static void step_settings(uint32_t pressed) {
    int setting = row_picked()->item;
    if (setting != RANDOM && (pressed & OW_PAD_LEFT)) setting_change(setting, -1);
    if (setting != RANDOM && (pressed & OW_PAD_RIGHT)) setting_change(setting, 1);
    if (pressed & MENU_BACK) screen = SCREEN_LOBBY;
    if ((pressed & MENU_PICK) && setting == RANDOM) {
        settings_send();
        screen = SCREEN_LOBBY;
    }
}

// Members as ow_lobby_kick numbers them: the seats by side, then OW_SIDES + the watcher's place.
static void build_members(void) {
    list_begin(banning ? "BAN WHO?" : "KICK WHO?", "3: PICK   4: BACK");
    for (int seat_side = 0; seat_side < OW_SIDES; seat_side++) {
        if (view.seats[seat_side].name[0]) row_add(view.seats[seat_side].name, NULL, seat_side);
    }
    for (uint32_t watcher = 0; watcher < view.watcher_count; watcher++) row_add(view.watchers[watcher].name, NULL, OW_SIDES + (int)watcher);
}

static void step_members(uint32_t pressed) {
    if ((pressed & MENU_PICK) && list.row_count > 0) ow_lobby_kick((uint32_t)row_picked()->item, banning);
    if (pressed & (MENU_PICK | MENU_BACK)) screen = SCREEN_LOBBY;
}

// --- frame

static void build(void) {
    switch (screen) {
    case SCREEN_MODE: build_mode(); break;
    case SCREEN_FIGHTER: build_fighter(); break;
    case SCREEN_STAGE: build_stage(); break;
    case SCREEN_LOBBIES: build_lobbies(); break;
    case SCREEN_PASSWORD: build_password(); break;
    case SCREEN_LOBBY: build_lobby(); break;
    case SCREEN_SETTINGS: build_settings(); break;
    case SCREEN_MEMBERS: build_members(); break;
    case SCREEN_MATCH:
    case SCREENS: list_begin("", NULL); break;
    }
    int *cursor = &cursors[screen];
    *cursor = SDL_clamp(*cursor, 0, SDL_max(list.row_count - 1, 0));
}

static void step(uint32_t pressed) {
    int *cursor = &cursors[screen];
    if (list.row_count > 0 && screen != SCREEN_PASSWORD) {
        if (pressed & OW_PAD_UP) *cursor = (*cursor + list.row_count - 1) % list.row_count;
        if (pressed & OW_PAD_DOWN) *cursor = (*cursor + 1) % list.row_count;
    }
    switch (screen) {
    case SCREEN_MODE: step_mode(pressed); break;
    case SCREEN_FIGHTER: step_fighter(pressed); break;
    case SCREEN_STAGE: step_stage(pressed); break;
    case SCREEN_LOBBIES: step_lobbies(pressed); break;
    case SCREEN_PASSWORD: step_password(pressed); break;
    case SCREEN_LOBBY: step_lobby(pressed); break;
    case SCREEN_SETTINGS: step_settings(pressed); break;
    case SCREEN_MEMBERS: step_members(pressed); break;
    case SCREEN_MATCH:
    case SCREENS: break;
    }
}

// While a match runs the presenter has the screen: no menu, and the buttons are the fighters'.
OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {
    (void)dt, (void)cmdbuf;
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
    build();
    step(pressed[player_of_screen()]);
    was_joined = view.joined;
    build();
    list_draw();
}
