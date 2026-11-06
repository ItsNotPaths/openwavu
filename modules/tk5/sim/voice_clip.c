// The per-frame move sounds of 0xa1eb0, after the decide pass (docs/data.md 8.4): the voice clips of a move (move +0x2c), then
// the random voices, the hit sound, the swing sounds and the stage sounds. Cues only: the presenter picks the record; nothing
// here changes the fight.
#include "sim/cue.h"
#include "sim/damage.h"
#include "sim/fighter.h"
#include "sim/limb.h"
#include "sim/properties.h"
#include "sim/rng.h"

// (hole hit-sound-yell :tags (tk5mod audio) :sev polish) the hit sound leaves out the target's voice word (P+0x8a0): a target of character 0x13, or of kind 0x12 in some modes, yells (its record 14, or a random one of 0..4) in place of the hit sound while its voice is free.

enum { SELECTOR_SHIFT = 12, NUMBER_MASK = 0xfff };

enum {
    SELECTOR_HIT_SOUND = 1,
    SELECTOR_VOICE = 2,         // voice kind 5, at the move's first frame
    SELECTOR_VOICE_KIND_6 = 3,  // the same, but counted in kind 6
    SELECTOR_COMMON = 6,        // a common record, on a hit
    SELECTOR_HIT_SOUND_7 = 7,   // as SELECTOR_HIT_SOUND
    SELECTOR_SPECIAL_ON_HIT = 8,
    SELECTOR_STAGE_FALL = 9,    // number 2: the common record 20 and the stage record (0x9117c)
    SELECTOR_STAGE_STEP = 10,   // the stage record of the fighter's side (0x910c8)
    SELECTOR_SPECIAL = 11,
};

enum { GUARD_RECORD = 18, HIT_SOUND_STEPS = 4, SWING_PUNCH_RECORD = 30, SWING_KICK_RECORD = 31, WINDOW_RECORD = 32 };
enum { STAGE_FALL_BOTH = 2 };

// Random voice kinds (0xa1b44), named by when they play.
enum { VOICE_ATTACK, VOICE_HEAVY_ATTACK, VOICE_HURT, VOICE_HEAVY_HURT, VOICE_KNOCKED_OUT };
enum { HEAVY_ATTACK_DAMAGE = 21, HEAVY_HURT_DAMAGE = 19 };

// sound_mask bits: the limbs whose touch of the floor sounds (skeleton A).
enum { SOUND_FEET = 2, SOUND_HIPS = 4 };

// Common records of the hit sound by damage: punches (0x10007360) and kicks (0x10007350).
static const int16_t PUNCH_RECORDS[HIT_SOUND_STEPS] = {6, 7, 11, 12};
static const int16_t PUNCH_STEPS[HIT_SOUND_STEPS - 1] = {7, 14, 24};  // damage above step k: record k + 1
static const int16_t KICK_RECORDS[HIT_SOUND_STEPS] = {15, 16, 16, 17};
static const int16_t KICK_STEPS[HIT_SOUND_STEPS - 1] = {15, 20, 22};

// What the clip list held, sounded or not.
typedef struct {
    bool voice;      // selector 2: no attack voice
    bool hit_sound;  // selector 1, 7 or 8: no hit sound after the clips
} ClipsSeen;

// Hitbox codes of class 1 in the game's table 0x10001fc0 (0x5ba64): the leg bones and their points.
static bool kicks(uint8_t hitbox_code) {
    return (hitbox_code >= 14 && hitbox_code <= 21) || (hitbox_code >= 23 && hitbox_code <= 26) || hitbox_code == 45 ||
           hitbox_code == 46 || hitbox_code == 49 || hitbox_code == 50;
}

// 0xa1adc on a guard, else 0xa1c5c: the common record by the attacker's damage.
static uint16_t hit_sound(const T5Fighter *attacker, const T5Fighter *opponent, bool kick) {
    if (opponent->guarded) return GUARD_RECORD;
    const int16_t *steps = kick ? KICK_STEPS : PUNCH_STEPS;
    int step = 0;
    while (step < HIT_SOUND_STEPS - 1 && attacker->damage > steps[step]) step++;
    return (uint16_t)(kick ? KICK_RECORDS : PUNCH_RECORDS)[step];
}

static uint16_t common(uint16_t record) { return (uint16_t)(SELECTOR_COMMON << SELECTOR_SHIFT | record); }

// The clip as the presenter plays it, or T5_VOICECLIP_END when the game plays nothing this frame.
static uint16_t played_clip(const T5Fighter *f, const T5Fighter *opponent, uint16_t clip, bool kick) {
    bool move_starts = f->frame == 1 && f->frame_changed && f->health > 0;
    switch (clip >> SELECTOR_SHIFT) {
    case SELECTOR_VOICE: case SELECTOR_VOICE_KIND_6: return move_starts ? clip : T5_VOICECLIP_END;
    case SELECTOR_COMMON: case SELECTOR_SPECIAL_ON_HIT: return f->hit_landed ? clip : T5_VOICECLIP_END;
    case SELECTOR_HIT_SOUND: case SELECTOR_HIT_SOUND_7:
        return f->hit_landed ? common(hit_sound(f, opponent, kick)) : T5_VOICECLIP_END;
    case SELECTOR_SPECIAL: return clip;
    default: return T5_VOICECLIP_END;
    }
}

// entry: the clip in T5Motbin.voiceclips, -1 for the sounds after the clips.
static void send(T5World *w, const T5Fighter *f, uint16_t id, uint16_t value, int32_t entry) {
    T5CueKey key = {t5_side_of(w, f), T5_FROM_VOICE_CLIP, f->move, entry};
    t5_cue_add(&w->cues, w->frame, (T5Cue){T5_CUE_VOICE, id, value, key.side, key, {}, {}});
}

// 0xa1b44 with libc rand(); here the roll comes from a copy of the sim RNG, which the fight never sees.
static void random_voice(T5World *w, const T5Fighter *f, T5Rng *voice_rng, uint16_t kind) {
    uint16_t roll = (uint16_t)(t5_rand(voice_rng) & NUMBER_MASK);
    send(w, f, T5_VOICE_RANDOM, (uint16_t)(kind << SELECTOR_SHIFT | roll), -1);
}

static bool coin(T5Rng *voice_rng) { return t5_rand(voice_rng) & 1; }

static ClipsSeen fighter_clips(T5World *w, const T5Fighter *f, const T5Fighter *opponent, const T5Move *move, bool kick) {
    ClipsSeen seen = {};
    const T5Motbin *motbin = t5_set(w, f->move.set);
    if (move->voiceclips < 0 || move->voiceclips >= motbin->voiceclip_count) return seen;
    for (int32_t entry = move->voiceclips; entry < move->voiceclips + T5_VOICECLIPS && entry < motbin->voiceclip_count; entry++) {
        uint16_t clip = motbin->voiceclips[entry];
        if (clip == T5_VOICECLIP_END) break;
        int selector = clip >> SELECTOR_SHIFT;
        seen.voice |= selector == SELECTOR_VOICE;
        seen.hit_sound |= selector == SELECTOR_HIT_SOUND || selector == SELECTOR_HIT_SOUND_7 || selector == SELECTOR_SPECIAL_ON_HIT;
        uint16_t played = played_clip(f, opponent, clip, kick);
        if (played != T5_VOICECLIP_END) send(w, f, T5_VOICE_CLIP, played, entry);
    }
    return seen;
}

// The common record after the clips: a KO hit, the hit sound no clip played, or the swing at the first active frame. The game
// also needs a voice character (P+0x8a0 set); every fighter has one.
static uint16_t strike_record(const T5Fighter *f, const T5Fighter *opponent, const T5Move *move, ClipsSeen seen, bool kick) {
    if (opponent->clean_hit && opponent->health <= 0) return (uint16_t)(kick ? KICK_RECORDS : PUNCH_RECORDS)[HIT_SOUND_STEPS - 1];
    bool reacts = f->reaction_rule == REACT_ALWAYS;
    if (!seen.hit_sound && f->hit_landed && reacts) return hit_sound(f, opponent, kick);
    if (f->frame_changed && f->frame == move->first_active && reacts) return kick ? SWING_KICK_RECORD : SWING_PUNCH_RECORD;
    return T5_VOICECLIP_END;
}

static void fighter_sounds(T5World *w, T5Fighter *f, const T5Fighter *opponent, T5Rng *voice_rng) {
    const T5Move *move = t5_move_at(w, f->move);
    if (move == nullptr) return;
    bool kick = kicks(move->hitbox[0]);
    if (f->ko) random_voice(w, f, voice_rng, VOICE_KNOCKED_OUT);
    ClipsSeen seen = fighter_clips(w, f, opponent, move, kick);

    if (move->first_active != 0 && !t5_in_throw(f->throw.chain) && f->anim_changed && !seen.voice && coin(voice_rng))
        random_voice(w, f, voice_rng, f->damage > HEAVY_ATTACK_DAMAGE ? VOICE_HEAVY_ATTACK : VOICE_ATTACK);
    if (f->clean_hit && f->health != 0 && coin(voice_rng))
        random_voice(w, f, voice_rng, opponent->damage > HEAVY_HURT_DAMAGE ? VOICE_HEAVY_HURT : VOICE_HURT);

    uint16_t record = strike_record(f, opponent, move, seen, kick);
    if (record != T5_VOICECLIP_END) send(w, f, T5_VOICE_CLIP, common(record), -1);

    if (f->frame == move->window_start && f->frame != 1) {
        send(w, f, T5_VOICE_CLIP, common(WINDOW_RECORD), -1);
        return;
    }
    uint32_t landed = f->limbs_a.below[BELOW_ROSE];
    bool feet_land = (f->sound_mask & SOUND_FEET) && (landed & (1u << LIMB_R_FOOT | 1u << LIMB_L_FOOT));
    bool hips_land = (f->sound_mask & SOUND_HIPS) && (landed & 1u << LIMB_HIPS);
    if (f->move_end || feet_land) send(w, f, T5_VOICE_CLIP, SELECTOR_STAGE_STEP << SELECTOR_SHIFT, -1);
    else if (f->touchdown || hips_land) send(w, f, T5_VOICE_CLIP, SELECTOR_STAGE_FALL << SELECTOR_SHIFT | STAGE_FALL_BOTH, -1);
}

void t5_voice_clips_pass(T5World *w) {
    T5Rng voice_rng = w->rng;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        T5Fighter *f = w->fighters[side];
        if (f->force_update) fighter_sounds(w, f, w->fighters[1 - side], &voice_rng);  // the game's sound flag of the side
    }
}
