// Plays a TK6 match natively from a script file: the stock gameplay module's init and step with the host imports
// done here (pack files, params, loadouts). Usage: tk6_scenario pack_dir character_1 character_2 stage script
// Script lines:
//   fight             step with no input until the fight phase
//   step N PAD1 PAD2  N frames with these OW_PAD_* words (hex); prints one state line a frame
//   save, load        keep the match state, go back to it
//   mark TEXT         echoes "mark TEXT"
// State line: "state FRAME" then per side "MOVE MOVE_FRAME BOUNDS AIR_WINDOW HEALTH X".
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gameplay/match.h"
#include "openwavu.h"
#include "ow_db.h"
#include "sim/fighter.h"
#include "sqlite3.h"

int32_t ow_sim_init(void);
uint8_t __global_base[1], __data_end[1];  // the wasm linker's state range; unused here

static const char *pack_dir, *stage, *characters[2];

static void pack_path(char *out, size_t size, const char *path, uint32_t length) {
    snprintf(out, size, "%s/%.*s", pack_dir, (int)length, path);
}

double ow_param_raw(const char *name, uint32_t name_length, double fallback) {
    if (name_length == 10 && memcmp(name, "round_time", 10) == 0) return 0;  // no clock: a scenario ends by its script
    return fallback;
}

int32_t ow_param_text_raw(const char *name, uint32_t name_length, char *buffer, uint32_t capacity) {
    if (name_length != 5 || memcmp(name, "stage", 5) != 0) return -1;
    uint32_t length = (uint32_t)strlen(stage);
    memcpy(buffer, stage, length < capacity ? length : capacity);
    return (int32_t)length;
}

int32_t ow_content_size_raw(const char *path, uint32_t length) {
    char full[1024];
    pack_path(full, sizeof full, path, length);
    FILE *file = fopen(full, "rb");
    if (!file) return -1;
    fseek(file, 0, SEEK_END);
    int32_t size = (int32_t)ftell(file);
    fclose(file);
    return size;
}

int32_t ow_content_read_raw(const char *path, uint32_t length, uint32_t offset, void *buffer, uint32_t capacity) {
    char full[1024];
    pack_path(full, sizeof full, path, length);
    FILE *file = fopen(full, "rb");
    if (!file) return -1;
    fseek(file, (long)offset, SEEK_SET);
    int32_t read = (int32_t)fread(buffer, 1, capacity, file);
    fclose(file);
    return read;
}

void ow_log_raw(const char *message, uint32_t length) { fprintf(stderr, "%.*s\n", (int)length, message); }
uint64_t ow_match_seed(void) { return 7; }
void ow_event(uint32_t kind, int32_t a, int32_t b) {}

int32_t ow_loadout(uint32_t side, void *buffer, uint32_t capacity) {
    T6Loadout loadout = {.costume = 1};
    snprintf(loadout.character, sizeof loadout.character, "%s", characters[side]);
    if (capacity < sizeof loadout) return -1;
    memcpy(buffer, &loadout, sizeof loadout);
    return sizeof loadout;
}

sqlite3 *ow_db_open(const char *path, uint32_t length) {
    char full[1024];
    pack_path(full, sizeof full, path, length);
    sqlite3 *db;
    if (sqlite3_open_v2(full, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return NULL;
    return db;
}

static void print_state(void) {
    printf("state %u", t6_match.world.frame);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6Fighter *f = &t6_match.fighters[side];
        printf(" %d %d %d %d %d %.0f", f->move.index, f->frame, f->bounds_used, f->in_air_window != 0, f->health >> 16, f->base_position.x);
    }
    printf("\n");
}

int main(int count, char **arguments) {
    if (count != 6) return 2;
    pack_dir = arguments[1], characters[0] = arguments[2], characters[1] = arguments[3], stage = arguments[4];
    FILE *script = fopen(arguments[5], "r");
    if (!script || ow_sim_init() != 0) return 3;
    static T6MatchState kept;
    static T6SideData kept_sides[T6_FIGHTER_COUNT];
    char line[256];
    while (fgets(line, sizeof line, script)) {
        unsigned frames, pads[2];
        if (strncmp(line, "fight", 5) == 0) {
            while (t6_match.world.round.phase != T6_PHASE_FIGHT) ow_sim_step(0, 0);
        } else if (sscanf(line, "step %u %x %x", &frames, &pads[0], &pads[1]) == 3) {
            for (unsigned frame = 0; frame < frames; frame++) {
                ow_sim_step(pads[0], pads[1]);
                print_state();
            }
        } else if (strncmp(line, "save", 4) == 0) {
            kept = t6_match;
            memcpy(kept_sides, t6_match_data.sides, sizeof kept_sides);
        } else if (strncmp(line, "load", 4) == 0) {
            t6_match = kept;
            memcpy(t6_match_data.sides, kept_sides, sizeof kept_sides);
        } else if (strncmp(line, "mark ", 5) == 0) {
            printf("%s", line);
        }
    }
    return 0;
}
