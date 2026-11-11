// Stock TK6 presenter (gamerender.wasm): plays the sound, voice, announcer and music cues of the view's cue ring, each
// cue number once. Outside rollback.
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "gamerender/face.h"
#include "gamerender/presenter.h"
#include "ow_sound.h"
#include "sim/constants.h"
#include "sim/properties.h"
#include "sqlite3.h"


enum {
    SOUNDS_MAX = 512,
    PATH_BYTES = 64,
    VOICE_KINDS = 8,
    VOICE_ROWS_MAX = 32,
    SPECIALS_MAX = 18,
    MUSIC_FADE_SECONDS = 3,
    FRAMES_PER_SECOND = 60,
};

typedef enum { BANK_COMMON, BANK_ROUND_CALLS, BANK_STAGE, BANK_VOICES_1, BANK_VOICES_2, BANK_STREAM_1, BANK_STREAM_2 } Bank;

// The announcer's records: round_calls, then common.
enum { ROUND_CALL_FIRST = 9, FINAL_ROUND = 19 };
static const int LINE_RECORD[] = {
    [T6_LINE_FIGHT] = 37, [T6_LINE_KO] = 64, [T6_LINE_TIME_UP] = 45, [T6_LINE_DOUBLE_KO] = 42,
    [T6_LINE_PERFECT] = 39, [T6_LINE_GREAT] = 38, [T6_LINE_DRAW] = 46,
};
enum { WINS_RECORD = 47, SELECTOR_9_RECORD = 20 };

// Voice property ids; their value is a voice word (cue.h).
enum { VOICE_COMMON = T6_PROPERTY_BASE + 0x159, VOICE_SELF = T6_PROPERTY_BASE + 0x15a, VOICE_TARGET = T6_PROPERTY_BASE + 0x15b,
       STREAM_VOICE = T6_PROPERTY_BASE + 0x15e };
enum { MOVE_VOICE_KIND_FIRST = 5 };  // selectors 2..4: voice kinds 5..7

typedef struct {
    Bank bank;
    int record;
    char file[PATH_BYTES];
    OwSoundTone tone;
} Sound;

typedef struct {
    int record;     // in the costume's voices bank
    uint16_t face;  // VOICE_FACE_CLIP + clip, a face value, or VOICE_FACE_NONE
} VoiceRow;

typedef struct {
    int voice;  // voice character; -1: none
    VoiceRow kind_rows[VOICE_KINDS][VOICE_ROWS_MAX];
    int kind_counts[VOICE_KINDS];
    int specials[SPECIALS_MAX];  // record per special sound id; -1: none
    int name, wins_delay;        // the announcer's name of it, in its voices bank; frames to "wins"
} Speaker;

static Sound sounds[SOUNDS_MAX];
static int sound_count;
static Speaker speakers[T6_FIGHTER_COUNT];
static OwSoundChannel voices[T6_FIGHTER_COUNT], effects, announcer;
static OwMusic music;
static char music_file[PATH_BYTES];
static int64_t music_loop_start, music_loop_length;
static float wins_in = -1;  // seconds until "wins"; below 0: none
static const T6View *playing;  // the view whose cues play

static sqlite3_stmt *query(sqlite3 *db, const char *sql) {
    sqlite3_stmt *rows;
    return sqlite3_prepare_v2(db, sql, -1, &rows, NULL) == SQLITE_OK ? rows : NULL;
}

static void copy_text(char *to, const unsigned char *text) { snprintf(to, PATH_BYTES, "%s", text ? (const char *)text : ""); }

// The game's dB, cents and degrees as a tone.
static OwSoundTone tone_of(double decibels, int cents, double degrees) {
    return (OwSoundTone){powf(10, (float)decibels / 20), sinf(RAD_FROM_DEG((float)degrees)), powf(2, (float)cents / 1200)};
}

static void load_bank(sqlite3 *db, Bank bank, const char *name) {
    sqlite3_stmt *rows = query(db, "SELECT idx, file, volume, pitch, pan FROM sound WHERE bank = ?1");
    if (!rows) return;
    sqlite3_bind_text(rows, 1, name, -1, SQLITE_STATIC);
    while (sound_count < SOUNDS_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        Sound *sound = &sounds[sound_count++];
        sound->bank = bank;
        sound->record = sqlite3_column_int(rows, 0);
        copy_text(sound->file, sqlite3_column_text(rows, 1));
        sound->tone = tone_of(sqlite3_column_double(rows, 2), sqlite3_column_int(rows, 3), sqlite3_column_double(rows, 4));
    }
    sqlite3_finalize(rows);
}

// The costume's part, whose name its banks carry.
static bool costume_part(sqlite3 *db, const T6Loadout *loadout, char *part) {
    sqlite3_stmt *rows = query(db, "SELECT part FROM costume_part WHERE character = ?1 AND costume = ?2 AND part NOT GLOB '*_lod'");
    if (!rows) return false;
    char costume[16];
    snprintf(costume, sizeof costume, "%u", loadout->costume);
    sqlite3_bind_text(rows, 1, loadout->character, -1, SQLITE_STATIC);
    sqlite3_bind_text(rows, 2, costume, -1, SQLITE_STATIC);
    bool found = sqlite3_step(rows) == SQLITE_ROW;
    if (found) copy_text(part, sqlite3_column_text(rows, 0));
    sqlite3_finalize(rows);
    return found;
}

static int costume_voice(sqlite3 *db, const T6Loadout *loadout) {
    sqlite3_stmt *rows = query(db, "SELECT voice FROM costume_voice WHERE character = ?1 AND costume = ?2");
    if (!rows) return -1;
    char costume[16];
    snprintf(costume, sizeof costume, "%u", loadout->costume);
    sqlite3_bind_text(rows, 1, loadout->character, -1, SQLITE_STATIC);
    sqlite3_bind_text(rows, 2, costume, -1, SQLITE_STATIC);
    int voice = sqlite3_step(rows) == SQLITE_ROW ? sqlite3_column_int(rows, 0) : -1;
    sqlite3_finalize(rows);
    return voice;
}

// Row n of kind k is the n-th row of the voice character with bit k.
static void load_speaker(sqlite3 *db, Speaker *speaker, int voice) {
    *speaker = (Speaker){.voice = voice, .name = -1};
    memset(speaker->specials, -1, sizeof speaker->specials);
    sqlite3_stmt *rows = query(db, "SELECT record, face, kinds FROM voice WHERE voice = ?1 ORDER BY idx");
    if (rows) {
        sqlite3_bind_int(rows, 1, voice);
        while (sqlite3_step(rows) == SQLITE_ROW) {
            VoiceRow row = {sqlite3_column_int(rows, 0), (uint16_t)sqlite3_column_int(rows, 1)};
            int kinds = sqlite3_column_int(rows, 2);
            for (int kind = 0; kind < VOICE_KINDS; kind++) {
                if ((kinds >> kind & 1) && speaker->kind_counts[kind] < VOICE_ROWS_MAX) speaker->kind_rows[kind][speaker->kind_counts[kind]++] = row;
            }
        }
        sqlite3_finalize(rows);
    }
    if ((rows = query(db, "SELECT id, record FROM special_sound WHERE voice = ?1"))) {
        sqlite3_bind_int(rows, 1, voice);
        while (sqlite3_step(rows) == SQLITE_ROW) {
            int id = sqlite3_column_int(rows, 0);
            if (id >= 0 && id < SPECIALS_MAX) speaker->specials[id] = sqlite3_column_int(rows, 1);
        }
        sqlite3_finalize(rows);
    }
    if ((rows = query(db, "SELECT own_record, wins_delay FROM voice_name WHERE voice = ?1"))) {
        sqlite3_bind_int(rows, 1, voice);
        if (sqlite3_step(rows) == SQLITE_ROW) {
            speaker->name = sqlite3_column_int(rows, 0);
            speaker->wins_delay = sqlite3_column_int(rows, 1);
        }
        sqlite3_finalize(rows);
    }
}

static void load_music(sqlite3 *db, const char *stage) {
    sqlite3_stmt *rows = query(db, "SELECT music.file, music.loop_start, music.loop_length FROM stage JOIN music ON music.id = stage.music WHERE stage.id = ?1");
    if (!rows) return;
    sqlite3_bind_text(rows, 1, stage, -1, SQLITE_STATIC);
    if (sqlite3_step(rows) == SQLITE_ROW) {
        copy_text(music_file, sqlite3_column_text(rows, 0));
        music_loop_start = sqlite3_column_int64(rows, 1);
        music_loop_length = sqlite3_column_int64(rows, 2);
    }
    sqlite3_finalize(rows);
}

void t6_sound_init(sqlite3 *db, const T6View *view) {
    ow_sound_skip_to(0);
    load_bank(db, BANK_COMMON, "common");
    load_bank(db, BANK_ROUND_CALLS, "round_calls");
    load_bank(db, BANK_STAGE, view->stage);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6Loadout *loadout = &view->fighters[side].loadout;
        char part[PATH_BYTES], bank[PATH_BYTES + 16];
        if (costume_part(db, loadout, part)) {
            snprintf(bank, sizeof bank, "%s/voices", part);
            load_bank(db, BANK_VOICES_1 + side, bank);
            snprintf(bank, sizeof bank, "%s/stream_voices", part);
            load_bank(db, BANK_STREAM_1 + side, bank);
        }
        load_speaker(db, &speakers[side], costume_voice(db, loadout));
        ow_sound_channel_open(&voices[side], 1);
    }
    load_music(db, view->stage);
    ow_sound_channel_open(&effects, OW_SOUND_VOICES);
    ow_sound_channel_open(&announcer, 1);
}

static void play(Bank bank, int record, OwSoundChannel *channel) {
    for (int index = 0; index < sound_count; index++) {
        const Sound *sound = &sounds[index];
        if (sound->bank == bank && sound->record == record) {
            ow_sound_play(channel, (OwStr){(uint32_t)strlen(sound->file), sound->file}, sound->tone);
            return;
        }
    }
}

static int side_of(T6Who who) { return who == T6_SIDE_1 ? 0 : who == T6_SIDE_2 ? 1 : -1; }

static void play_voice(int side, int record) {
    if (record >= 0) play(BANK_VOICES_1 + side, record, &voices[side]);
}

// The record of row `row` of `kind`, and the face of that row of `face_kind`. The newest voice's face wins.
static void play_row(int side, int kind, int face_kind, int row) {
    play_voice(side, speakers[side].kind_rows[kind][row].record);
    t6_scene_voice_face(playing, side, speakers[side].kind_rows[face_kind][row].face);
}

static void play_special(int side, int number) {
    if (number < SPECIALS_MAX) play_voice(side, speakers[side].specials[number]);
}

// 0x815a / 0x815b: by selector, a common record, a move voice, a special sound or (9) the common record 20.
static void fighter_voice(int side, uint32_t value) {
    int selector = (int)(value >> T6_VOICE_SELECTOR_SHIFT), number = (int)(value & T6_VOICE_NUMBER_MASK);
    const Speaker *speaker = &speakers[side];
    switch (selector) {
    case 1: case 6: case 7: play(BANK_COMMON, number, &effects); break;
    case 2: case 3: case 4: {
        int kind = MOVE_VOICE_KIND_FIRST + selector - 2, count = speaker->kind_counts[kind];
        if (number <= 998 && count > 0) play_row(side, kind, kind, number % count);
        break;
    }
    case 8: play_special(side, number); break;
    case 9: if (number != 1) play(BANK_COMMON, SELECTOR_9_RECORD, &effects); break;
    default: break;
    }
}

// A move's voice clip (sim/voice_clip.c): 2 and 3 entry n of the move voices, 6 a common record, 8 and 11 a special sound;
// after the clips, 9 and 10 as in a property.
static void clip_voice(int side, uint32_t value) {
    int selector = (int)(value >> T6_VOICE_SELECTOR_SHIFT), number = (int)(value & T6_VOICE_NUMBER_MASK);
    const int *counts = speakers[side].kind_counts;
    switch (selector) {
    case 2: case 3: {
        int counted = MOVE_VOICE_KIND_FIRST + selector - 2;  // 3 counts kind 6 and takes its face, but plays kind 5, as the game does
        if (number < counts[counted] && number < counts[MOVE_VOICE_KIND_FIRST]) play_row(side, MOVE_VOICE_KIND_FIRST, counted, number);
        break;
    }
    case 6: play(BANK_COMMON, number, &effects); break;
    case 8: case 11: play_special(side, number); break;
    case 9: case 10: fighter_voice(side, value); break;
    default: break;
    }
}

// The kind as the selector, the roll as the number: row roll % count of the kind.
static void random_voice(int side, uint32_t value) {
    const Speaker *speaker = &speakers[side];
    int kind = (int)(value >> T6_VOICE_SELECTOR_SHIFT), count = speaker->kind_counts[kind];
    if (count > 0) play_row(side, kind, kind, (int)((value & T6_VOICE_NUMBER_MASK) % (uint32_t)count));
}

// voice character << 8 | record, from the stream bank of the fighter with that voice character.
static void stream_voice(uint32_t value) {
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        if (speakers[side].voice == (int)(value >> 8)) play(BANK_STREAM_1 + side, value & 0xff, &voices[side]);
    }
}

static void sound_cue(const T6Cue *cue) {
    int side = side_of(cue->owner);
    switch (cue->id) {
    case T6_VOICE_CLIP: if (side >= 0) clip_voice(side, cue->value); break;
    case T6_VOICE_RANDOM: if (side >= 0) random_voice(side, cue->value); break;
    case VOICE_COMMON: if (cue->value >> T6_VOICE_SELECTOR_SHIFT != 0) play(BANK_COMMON, (int)(cue->value & T6_VOICE_NUMBER_MASK), &effects); break;
    case VOICE_SELF: case VOICE_TARGET: if (side >= 0) fighter_voice(side, cue->value); break;
    case STREAM_VOICE: stream_voice(cue->value); break;
    default: break;
    }
}

static void announce(const T6Cue *cue) {
    wins_in = -1;  // a newer line, such as the next round's call after a skipped win pose, drops a waiting "wins"
    switch ((T6Line)cue->id) {
    case T6_LINE_ROUND: play(BANK_ROUND_CALLS, ROUND_CALL_FIRST + cue->value, &announcer); break;
    case T6_LINE_FINAL_ROUND: play(BANK_ROUND_CALLS, FINAL_ROUND, &announcer); break;
    case T6_LINE_WINNER: {
        int side = side_of(cue->owner);
        if (side < 0) break;
        play(BANK_VOICES_1 + side, speakers[side].name, &announcer);
        wins_in = (float)speakers[side].wins_delay / FRAMES_PER_SECOND;
        break;
    }
    default: play(BANK_COMMON, LINE_RECORD[cue->id], &announcer); break;
    }
}

static void music_cue(const T6Cue *cue) {
    if (cue->id == T6_MUSIC_START && music_file[0]) {
        ow_music_start(&music, (OwStr){(uint32_t)strlen(music_file), music_file}, (uint64_t)music_loop_start, (uint64_t)music_loop_length);
    }
    if (cue->id == T6_MUSIC_FADE) ow_music_fade(&music, MUSIC_FADE_SECONDS);
}

void t6_sound_play(const T6View *view, float seconds) {
    playing = view;
    for (uint32_t index = 0; index < view->cue_count; index++) {
        const T6CueEntry *entry = &view->cues[index];
        T6CueKind kind = entry->cue.kind;
        bool sounds_cue = kind == T6_CUE_SOUND || kind == T6_CUE_VOICE || kind == T6_CUE_ANNOUNCE || kind == T6_CUE_MUSIC;
        if (!sounds_cue || !ow_sound_take(entry->number)) continue;
        if (kind == T6_CUE_ANNOUNCE) announce(&entry->cue);
        else if (kind == T6_CUE_MUSIC) music_cue(&entry->cue);
        else sound_cue(&entry->cue);
    }
    if (wins_in >= 0 && (wins_in -= seconds) < 0) play(BANK_COMMON, WINS_RECORD, &announcer);
    ow_music_step(&music, seconds);
}
