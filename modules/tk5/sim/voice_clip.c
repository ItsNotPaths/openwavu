// The voice clips of a move (move +0x2c), as 0xa1eb0 plays them after the decide pass (docs/data.md 8.4). Cues only: the
// presenter picks the record; nothing here changes the fight.
#include "sim/cue.h"
#include "sim/fighter.h"
#include "sim/properties.h"

// (hole move-sounds-after-clips :tags (tk5mod audio)) after the clips 0xa1eb0 also plays the random voices (kinds 0..4, libc rand), the hit sound of a hit that no clip sounded, the KO and ring out records, and the stage sounds of move_end and touchdown; none are sent.
// (hole hit-sound-yell :tags (tk5mod audio) :sev polish) the hit sound leaves out the target's voice word (P+0x8a0): a target of character 0x13, or of kind 0x12 in some modes, yells (its record 14, or a random one of 0..4) in place of the hit sound while its voice is free.

enum { SELECTOR_SHIFT = 12, NUMBER_MASK = 0xfff };

enum {
    SELECTOR_HIT_SOUND = 1,
    SELECTOR_VOICE = 2,         // voice kind 5, at the move's first frame
    SELECTOR_VOICE_KIND_6 = 3,  // the same, but counted in kind 6
    SELECTOR_COMMON = 6,        // a common record, on a hit
    SELECTOR_HIT_SOUND_7 = 7,   // as SELECTOR_HIT_SOUND
    SELECTOR_SPECIAL_ON_HIT = 8,
    SELECTOR_SPECIAL = 11,
};

enum { GUARD_RECORD = 18, HIT_SOUND_STEPS = 4 };

// Common records of the hit sound by damage: punches (0x10007360) and kicks (0x10007350).
static const int16_t PUNCH_RECORDS[HIT_SOUND_STEPS] = {6, 7, 11, 12};
static const int16_t PUNCH_STEPS[HIT_SOUND_STEPS - 1] = {7, 14, 24};  // damage above step k: record k + 1
static const int16_t KICK_RECORDS[HIT_SOUND_STEPS] = {15, 16, 16, 17};
static const int16_t KICK_STEPS[HIT_SOUND_STEPS - 1] = {15, 20, 22};

// Hitbox codes of class 1 in the game's table 0x10001fc0 (0x5ba64): the leg bones and their points.
static bool kicks(uint8_t hitbox_code) {
    return (hitbox_code >= 14 && hitbox_code <= 21) || (hitbox_code >= 23 && hitbox_code <= 26) || hitbox_code == 45 ||
           hitbox_code == 46 || hitbox_code == 49 || hitbox_code == 50;
}

// 0xa1adc on a guard, else 0xa1c5c: the common record by the attacker's damage.
static uint16_t hit_sound(const T5World *w, const T5Fighter *attacker, const T5Fighter *opponent) {
    if (opponent->guarded) return GUARD_RECORD;
    bool kick = kicks(t5_move_at(w, attacker->move)->hitbox[0]);
    const int16_t *steps = kick ? KICK_STEPS : PUNCH_STEPS;
    int step = 0;
    while (step < HIT_SOUND_STEPS - 1 && attacker->damage > steps[step]) step++;
    return (uint16_t)(kick ? KICK_RECORDS : PUNCH_RECORDS)[step];
}

// The clip as the presenter plays it, or T5_VOICECLIP_END when the game plays nothing this frame.
static uint16_t played_clip(const T5World *w, const T5Fighter *f, const T5Fighter *opponent, uint16_t clip) {
    bool move_starts = f->frame == 1 && f->frame_changed && f->health > 0;
    switch (clip >> SELECTOR_SHIFT) {
    case SELECTOR_VOICE: case SELECTOR_VOICE_KIND_6: return move_starts ? clip : T5_VOICECLIP_END;
    case SELECTOR_COMMON: case SELECTOR_SPECIAL_ON_HIT: return f->hit_landed ? clip : T5_VOICECLIP_END;
    case SELECTOR_HIT_SOUND: case SELECTOR_HIT_SOUND_7:
        return f->hit_landed ? (uint16_t)(SELECTOR_COMMON << SELECTOR_SHIFT | hit_sound(w, f, opponent)) : T5_VOICECLIP_END;
    case SELECTOR_SPECIAL: return clip;
    default: return T5_VOICECLIP_END;
    }
}

static void fighter_clips(T5World *w, T5Fighter *f, const T5Fighter *opponent) {
    const T5Move *move = t5_move_at(w, f->move);
    const T5Motbin *motbin = t5_set(w, f->move.set);
    if (move == nullptr || move->voiceclips < 0 || move->voiceclips >= motbin->voiceclip_count) return;
    for (int32_t entry = move->voiceclips; entry < move->voiceclips + T5_VOICECLIPS && entry < motbin->voiceclip_count; entry++) {
        uint16_t clip = motbin->voiceclips[entry];
        if (clip == T5_VOICECLIP_END) return;
        uint16_t played = played_clip(w, f, opponent, clip);
        if (played == T5_VOICECLIP_END) continue;
        T5CueKey key = {t5_side_of(w, f), T5_FROM_VOICE_CLIP, f->move, entry};
        t5_cue_add(&w->cues, w->frame, (T5Cue){T5_CUE_VOICE, T5_VOICE_CLIP, played, key.side, key, {}, {}});
    }
}

void t5_voice_clips_pass(T5World *w) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        T5Fighter *f = w->fighters[side];
        if (f->force_update) fighter_clips(w, f, w->fighters[1 - side]);  // the game's sound flag of the side
    }
}
