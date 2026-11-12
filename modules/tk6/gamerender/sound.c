// Stock TK6 presenter (gamerender.wasm): plays the sound, voice, announcer and music cues of the view's cue ring, each
// cue number once. Outside rollback. Moves and voices name a sound by its sound number, the announcer by its record name
// (sound_name).
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "gamerender/presenter.h"
#include "ow_sound.h"
#include "sim/constants.h"
#include "sim/properties.h"
#include "sqlite3.h"


enum {
    SOUNDS_MAX = 2048,
    NAME_BYTES = 48,
    PATH_BYTES = 64,
    VOICE_KINDS = 10,
    VOICE_ROWS_MAX = 32,
    MUSIC_FADE_SECONDS = 3,
    FRAMES_PER_SECOND = 60,
};
enum { NUMBER_MASK = 0xfff };  // the game reads a voice word's sound number from its low 12 bits
enum { ANY_ROW_KIND = 8, ANY_ROW_KIND_TOO = 9 };
enum { SHARED = -1 };  // the owner of the shared and the stage's sounds
enum { BODY_FALL_SOUND = 27 };
enum { WINS_DELAY = 64 };  // frames from the winner's name to "wins" [guess: TK5's average]

static const char *const LINE_NAME[] = {
    [T6_LINE_FINAL_ROUND] = "syvo_fnl_round", [T6_LINE_FIGHT] = "syvo_fight", [T6_LINE_KO] = "syvo_ko",
    [T6_LINE_TIME_UP] = "syvo_timeup", [T6_LINE_DOUBLE_KO] = "syvo_wko", [T6_LINE_PERFECT] = "syvo_prfct",
    [T6_LINE_GREAT] = "syvo_great", [T6_LINE_DRAW] = "syvo_draw",
};

// Voice property ids; their value is a voice word (cue.h), the stream voice's a sound number.
enum { VOICE_COMMON = T6_PROPERTY_BASE + 0x159, VOICE_SELF = T6_PROPERTY_BASE + 0x15a, VOICE_TARGET = T6_PROPERTY_BASE + 0x15b,
       STREAM_VOICE = T6_PROPERTY_BASE + 0x15e };
enum { MOVE_VOICE_KIND_FIRST = 5 };  // selectors 2..4: voice kinds 5..7

typedef struct {
    int number;  // 0: none
    int owner;   // the side whose banks hold it, or SHARED
    char name[NAME_BYTES];
    char file[PATH_BYTES];
    OwSoundTone tone;
} Sound;

typedef struct {
    int number;
    uint16_t face;  // VOICE_FACE_CLIP + clip, a face value, or VOICE_FACE_NONE
} VoiceRow;

typedef struct {
    VoiceRow kind_rows[VOICE_KINDS][VOICE_ROWS_MAX];
    int kind_counts[VOICE_KINDS];
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

static void copy_text(char *to, size_t size, const unsigned char *text) { snprintf(to, size, "%s", text ? (const char *)text : ""); }

// The game's dB, cents and degrees as a tone.
static OwSoundTone tone_of(double decibels, int cents, double degrees) {
    return (OwSoundTone){powf(10, (float)decibels / 20), sinf(RAD_FROM_DEG((float)degrees)), powf(2, (float)cents / 1200)};
}

// The sounds of the banks under folder (shared, a character, a stage).
static void load_banks(sqlite3 *db, const char *folder, int owner) {
    sqlite3_stmt *rows = query(db, "SELECT sound_name.number, sound_name.name, sound.file, sound.volume, sound.pitch, sound.pan "
                                   "FROM sound JOIN sound_name USING (bank, idx) WHERE bank GLOB ?1");
    if (!rows) return;
    char pattern[PATH_BYTES];
    snprintf(pattern, sizeof pattern, "%s/*", folder);
    sqlite3_bind_text(rows, 1, pattern, -1, SQLITE_TRANSIENT);
    while (sound_count < SOUNDS_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        Sound *sound = &sounds[sound_count++];
        sound->number = sqlite3_column_int(rows, 0);
        sound->owner = owner;
        copy_text(sound->name, sizeof sound->name, sqlite3_column_text(rows, 1));
        copy_text(sound->file, sizeof sound->file, sqlite3_column_text(rows, 2));
        sound->tone = tone_of(sqlite3_column_double(rows, 3), sqlite3_column_int(rows, 4), sqlite3_column_double(rows, 5));
    }
    sqlite3_finalize(rows);
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

static void add_row(Speaker *speaker, int kind, VoiceRow row) {
    if (speaker->kind_counts[kind] < VOICE_ROWS_MAX) speaker->kind_rows[kind][speaker->kind_counts[kind]++] = row;
}

// Row n of kind k is the n-th row of the voice character with bit k; kind 8 is every row.
static void load_speaker(sqlite3 *db, Speaker *speaker, int voice) {
    *speaker = (Speaker){};
    sqlite3_stmt *rows = query(db, "SELECT number, face, kinds FROM voice WHERE voice = ?1 ORDER BY idx");
    if (!rows) return;
    sqlite3_bind_int(rows, 1, voice);
    while (sqlite3_step(rows) == SQLITE_ROW) {
        VoiceRow row = {sqlite3_column_int(rows, 0), (uint16_t)sqlite3_column_int(rows, 1)};
        int kinds = sqlite3_column_int(rows, 2);
        for (int kind = 0; kind < ANY_ROW_KIND; kind++) {
            if (kinds >> kind & 1) add_row(speaker, kind, row);
        }
        add_row(speaker, ANY_ROW_KIND, row);
    }
    sqlite3_finalize(rows);
}

static void load_music(sqlite3 *db, const char *stage) {
    sqlite3_stmt *rows = query(db, "SELECT music.file, music.loop_start, music.loop_length FROM stage JOIN music ON music.id = stage.music WHERE stage.id = ?1");
    if (!rows) return;
    sqlite3_bind_text(rows, 1, stage, -1, SQLITE_STATIC);
    if (sqlite3_step(rows) == SQLITE_ROW) {
        copy_text(music_file, sizeof music_file, sqlite3_column_text(rows, 0));
        music_loop_start = sqlite3_column_int64(rows, 1);
        music_loop_length = sqlite3_column_int64(rows, 2);
    }
    sqlite3_finalize(rows);
}

void t6_sound_init(sqlite3 *db, const T6View *view) {
    ow_sound_skip_to(0);
    sound_count = 0;
    load_banks(db, "shared", SHARED);
    load_banks(db, view->stage, SHARED);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6Loadout *loadout = &view->fighters[side].loadout;
        load_banks(db, loadout->character, side);
        load_speaker(db, &speakers[side], costume_voice(db, loadout));
        ow_sound_channel_open(&voices[side], 1);
    }
    load_music(db, view->stage);
    ow_sound_channel_open(&effects, OW_SOUND_VOICES);
    ow_sound_channel_open(&announcer, 1);
}

static void play_sound(const Sound *sound, OwSoundChannel *channel) {
    if (sound) ow_sound_play(channel, (OwStr){(uint32_t)strlen(sound->file), sound->file}, sound->tone);
}

static const Sound *numbered(int number) {
    for (int index = 0; index < sound_count; index++) {
        if (number > 0 && sounds[index].number == number) return &sounds[index];
    }
    return NULL;
}

// The first sound of owner with the name, or whose name starts with it when prefix.
static const Sound *named(const char *name, int owner, bool prefix) {
    for (int index = 0; index < sound_count; index++) {
        const Sound *sound = &sounds[index];
        bool fits = prefix ? strncmp(sound->name, name, strlen(name)) == 0 : strcmp(sound->name, name) == 0;
        if (sound->owner == owner && fits) return sound;
    }
    return NULL;
}

static int side_of(T6Who who) { return who == T6_SIDE_1 ? 0 : who == T6_SIDE_2 ? 1 : -1; }

// Row `row` of `kind`, with its face.
static void play_row(int side, int kind, int row) {
    VoiceRow voice = speakers[side].kind_rows[kind][row];
    play_sound(numbered(voice.number), &voices[side]);
    t6_scene_voice_face(playing, side, voice.face);
}

// The kind as the selector, the roll as the number: row roll % count of the kind.
static void random_voice(int side, uint32_t value) {
    int kind = (int)(value >> T6_VOICE_SELECTOR_SHIFT);
    if (kind == ANY_ROW_KIND_TOO) kind = ANY_ROW_KIND;
    if (kind >= VOICE_KINDS) return;
    int count = speakers[side].kind_counts[kind];
    if (count > 0) play_row(side, kind, (int)((value & NUMBER_MASK) % (uint32_t)count));
}

// A body falling to the floor, and the stage's own impact (water, snow) where it has one.
static void stage_fall(void) {
    play_sound(numbered(BODY_FALL_SOUND), &effects);
    for (int index = 0; index < sound_count; index++) {
        if (sounds[index].owner == SHARED && strstr(sounds[index].name, "_impact_")) {
            play_sound(&sounds[index], &effects);
            return;
        }
    }
}

// A voice word of a move clip or of 0x815a / 0x815b, by selector: a sound number, a row of a move voice kind, or the
// stage's fall.
// (hole tk6-voice-selectors :tags (tk6 audio) :sev gap) selectors 8 (special sounds, table 0x909f9c), 10 (the step, played at the foot by floor kind), 12 (an event) and 9's numbers 1 and 2 are not played.
static void fighter_voice(int side, uint32_t value) {
    int selector = (int)(value >> T6_VOICE_SELECTOR_SHIFT), number = (int)(value & NUMBER_MASK);
    switch (selector) {
    case 1: case 6: case 7: case 11: play_sound(numbered(number), &effects); break;
    case 2: case 3: case 4: {
        int kind = MOVE_VOICE_KIND_FIRST + selector - 2, count = speakers[side].kind_counts[kind];
        if (count > 0) play_row(side, kind, number % count);
        break;
    }
    case 9: stage_fall(); break;
    default: break;
    }
}

static void sound_cue(const T6Cue *cue) {
    int side = side_of(cue->owner);
    switch (cue->id) {
    case T6_VOICE_CLIP: if (side >= 0) fighter_voice(side, cue->value); break;
    case T6_VOICE_RANDOM: if (side >= 0) random_voice(side, cue->value); break;
    case VOICE_COMMON: if (cue->value >> T6_VOICE_SELECTOR_SHIFT != 0) play_sound(numbered((int)(cue->value & NUMBER_MASK)), &effects); break;
    case VOICE_SELF: case VOICE_TARGET: if (side >= 0) fighter_voice(side, cue->value); break;
    case STREAM_VOICE: if (side >= 0) play_sound(numbered((int)cue->value), &voices[side]); break;
    default: break;
    }
}

static void announce(const T6Cue *cue) {
    wins_in = -1;  // a newer line, such as the next round's call after a skipped win pose, drops a waiting "wins"
    switch ((T6Line)cue->id) {
    case T6_LINE_ROUND: {
        char name[NAME_BYTES];
        snprintf(name, sizeof name, "syvo_round%02u", (unsigned)cue->value);
        play_sound(named(name, SHARED, false), &announcer);
        break;
    }
    case T6_LINE_WINNER: {
        int side = side_of(cue->owner);
        if (side < 0) break;
        play_sound(named("syvo_name_", side, true), &announcer);
        wins_in = (float)WINS_DELAY / FRAMES_PER_SECOND;
        break;
    }
    default:
        if (cue->id < sizeof LINE_NAME / sizeof LINE_NAME[0] && LINE_NAME[cue->id]) play_sound(named(LINE_NAME[cue->id], SHARED, false), &announcer);
        break;
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
    if (wins_in >= 0 && (wins_in -= seconds) < 0) play_sound(named("syvo_wins", SHARED, false), &announcer);
    ow_music_step(&music, seconds);
}
