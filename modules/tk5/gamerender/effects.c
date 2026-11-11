// Stock TK5 presenter (gamerender.wasm): the effects of the view's cues as scene fx entries, rebuilt every frame from the
// cue ring, so a rollback or a seek needs nothing. Outside rollback. Picks as tk5decomp docs/effects.md section 4.
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "gamerender/presenter.h"
#include "sim/properties.h"
#include "sqlite3.h"

// (hole effect-dust :tags (tk5mod effects)) the ground dust (properties 0x8009, 0x800a: effects/dust by the ground kind under the fighter) is not played. tekken 6 as well modules/tk6/gamerender/effects.c
// (hole effect-light :tags (tk5mod effects) :sev polish) a heavy hit does not light the hit point with record 0's colour (character_effect_row.light). tekken 6 as well modules/tk6/gamerender/effects.c
// (hole effect-past-ring :tags (tk5mod effects) :sev polish) an effect whose cue leaves the ring (60 frames) stops; none of the shared sparks lives that long. tekken 6 as well modules/tk6/gamerender/effects.c
// (hole effect-follow :tags (tk5mod effects) :sev polish) every effect plays at a world point; records 0x1b (joint glued) and kind 15 do not follow their fighter. tekken 6 as well modules/tk6/gamerender/effects.c

enum { SHARED_RECORDS = 41, FIGHTER_RECORDS = 16, FIGHTER_ROWS = 16, HEAVY_DAMAGE = 20 };

static uint32_t shared[SHARED_RECORDS];  // asset ids of effects/common/<n>.fx; 0 = none

static struct {
    uint32_t records[FIGHTER_RECORDS];  // asset ids of the character's own effects; 0 = none
    uint32_t rows[FIGHTER_ROWS];        // bit n: record n plays
} fighter[T5_FIGHTER_COUNT];

static void load_fighter(sqlite3 *db, int side, const char *character) {
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT record, file FROM character_effect WHERE character = ?1", -1, &rows, NULL) == SQLITE_OK) {
        sqlite3_bind_text(rows, 1, character, -1, SQLITE_STATIC);
        while (sqlite3_step(rows) == SQLITE_ROW) {
            int record = sqlite3_column_int(rows, 0);
            if (record < FIGHTER_RECORDS) fighter[side].records[record] = t5_asset_of(sqlite3_column_text(rows, 1));
        }
        sqlite3_finalize(rows);
    }
    if (sqlite3_prepare_v2(db, "SELECT row, records FROM character_effect_row WHERE character = ?1", -1, &rows, NULL) == SQLITE_OK) {
        sqlite3_bind_text(rows, 1, character, -1, SQLITE_STATIC);
        while (sqlite3_step(rows) == SQLITE_ROW) {
            int row = sqlite3_column_int(rows, 0);
            if (row < FIGHTER_ROWS) fighter[side].rows[row] = (uint32_t)sqlite3_column_int64(rows, 1);
        }
        sqlite3_finalize(rows);
    }
}

void t5_effects_init(sqlite3 *db, const T5View *view) {
    for (int record = 0; record < SHARED_RECORDS; record++) {
        char path[32];
        int length = snprintf(path, sizeof path, "effects/common/%d.fx", record);
        shared[record] = ow_asset((OwStr){(uint32_t)length, path});
    }
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) load_fighter(db, side, view->fighters[side].loadout.character);
}

// Turned so +z runs along the hit direction; none keeps the world's turn.
static OwQuat facing(T5Vec3 direction) {
    float across = sqrtf(direction.x * direction.x + direction.z * direction.z);
    if (across == 0 && direction.y == 0) return (OwQuat){0, 0, 0, 1};
    float yaw = atan2f(direction.x, direction.z) / 2, pitch = -atan2f(direction.y, across) / 2;
    return (OwQuat){cosf(yaw) * sinf(pitch), sinf(yaw) * cosf(pitch), -sinf(yaw) * sinf(pitch), cosf(yaw) * cosf(pitch)};
}

typedef struct {
    OwFx *entries;
    uint32_t count, max;
} FxList;

static void play_asset(FxList *list, uint32_t effect, const T5CueEntry *entry, T5Vec3 direction, float age) {
    if (effect == 0 || list->count == list->max) return;
    T5Vec3 at = entry->cue.position;
    list->entries[list->count++] = (OwFx){
        .effect = effect,
        .at = {.position = {at.x * MM, at.y * MM, at.z * MM}, .rotation = facing(direction), .scale = {1, 1, 1}},
        .age = age,
        .seed = entry->number,
    };
}

static void play(FxList *list, int record, const T5CueEntry *entry, T5Vec3 direction, float age) {
    if (record >= 0 && record < SHARED_RECORDS) play_asset(list, shared[record], entry, direction, age);
}

// The records of a row of side's hit table.
static void play_row(FxList *list, T5Who who, int row, const T5CueEntry *entry, T5Vec3 direction, float age) {
    int side = who == T5_SIDE_1 ? 0 : who == T5_SIDE_2 ? 1 : -1;
    if (side < 0 || row < 0 || row >= FIGHTER_ROWS) return;
    for (int record = 0; record < FIGHTER_RECORDS; record++)
        if (fighter[side].rows[row] & 1u << record) play_asset(list, fighter[side].records[record], entry, direction, age);
}

static T5Who other(T5Who who) { return who == T5_SIDE_1 ? T5_SIDE_2 : who == T5_SIDE_2 ? T5_SIDE_1 : T5_NOBODY; }

static void play_pair(FxList *list, int first, int second, const T5CueEntry *entry, T5Vec3 direction, float age) {
    play(list, first, entry, direction, age);
    play(list, second, entry, direction, age);
}

static void hit_effects(FxList *list, const T5CueEntry *entry, float age) {
    T5Vec3 direction = entry->cue.direction;
    switch ((T5Spark)entry->cue.id) {
    case T5_SPARK_CLEAN:
        play_pair(list, 0, 1, entry, direction, age);
        if (entry->cue.value <= HEAVY_DAMAGE) break;
        for (int record = 5; record <= 7; record++) play(list, record, entry, direction, age);
        play_row(list, entry->cue.owner, 0, entry, direction, age);  // the attacker's own
        break;
    case T5_SPARK_GUARD:  // the guard spark faces back along the hit
        play_pair(list, 13, 14, entry, (T5Vec3){-direction.x, -direction.y, -direction.z}, age);
        break;
    case T5_SPARK_TOUCH: play_pair(list, 15, 16, entry, direction, age); break;
    }
}

// (hole reaction-effect-owner :tags (tk5mod effects)) 0x8019/0x801c on a reaction move (jin/He_PopAte2n) play the reacting fighter's row 0, so Kazuya's crumple or launch envelops Jin in Jin's red; by effects.md the game does too (P slot), but it looks wrong: check whether the game's slot is the attacker's, or whether those reactions run in the attacker's set. tekken 6 as well modules/tk6/gamerender/effects.c:property_effects
static void property_effects(FxList *list, const T5CueEntry *entry, float age) {
    T5Vec3 none = {};
    T5Who self = entry->cue.key.side;
    int row = entry->cue.value & 0xff;
    switch (entry->cue.id - T5_PROPERTY_BASE) {
    case 0x19: case 0x1a: case 0x1c: play_row(list, self, 0, entry, none, age); break;
    case 0x1b: play_row(list, self, row, entry, none, age); break;
    case 0x1d: play_row(list, other(self), row, entry, none, age); break;
    case 0x16: case 0x17: play(list, 0x1b, entry, none, age); break;
    case 0x18: play(list, 0x1d, entry, none, age); break;
    case 0x1e: play_pair(list, 0, 1, entry, none, age); break;
    case 0x1f: play_pair(list, 15, 16, entry, none, age); break;
    case 0x20: play(list, 25, entry, none, age); break;
    case 0x21: play_pair(list, 13, 14, entry, none, age); break;
    case 0x2b: case 0x2c: play(list, entry->cue.value & 0xff, entry, none, age); break;
    }
}

uint32_t t5_effects(const T5View *view, OwFx *entries, uint32_t max) {
    FxList list = {entries, 0, max};
    for (uint32_t index = 0; index < view->cue_count; index++) {
        const T5CueEntry *entry = &view->cues[index];
        float age = (float)(view->frame - entry->frame) / 60.0f;
        if (entry->cue.kind == T5_CUE_HIT) hit_effects(&list, entry, age);
        if (entry->cue.kind == T5_CUE_FX) property_effects(&list, entry, age);
    }
    return list.count;
}
