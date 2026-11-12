// The per-frame move sounds, after the decide pass: the voice clips of a move, then
// the random voices, the hit sound, the swing sounds and the stage sounds. Cues only: the presenter picks the record by
// sound number; nothing here changes the fight.
#include "sim/cue.h"
#include "sim/damage.h"
#include "sim/fighter.h"
#include "sim/limb.h"
#include "sim/properties.h"
#include "sim/rng.h"


enum { ROLL_MASK = 0xfff };  // a random voice's roll

enum {
    SELECTOR_HIT_SOUND = 1,
    SELECTOR_VOICE = 2,         // voice kind 5, at the move's first frame
    SELECTOR_VOICE_KIND_6 = 3,  // the same, but counted in kind 6
    SELECTOR_SOUND = 6,         // a sound number, on a hit
    SELECTOR_HIT_SOUND_7 = 7,   // as SELECTOR_HIT_SOUND
    SELECTOR_SPECIAL_ON_HIT = 8,
    SELECTOR_STAGE_FALL = 9,    // number 2: the body fall and the stage's impact
    SELECTOR_STAGE_STEP = 10,   // the stage record of the fighter's side
    SELECTOR_SPECIAL = 11,
};

enum { GUARD_SOUND = 25, HIT_SOUND_STEPS = 4, SWING_PUNCH_SOUND = 33, SWING_KICK_SOUND = 34, WINDOW_SOUND = 29 };
enum { NO_SOUND = 0xffff };
enum { STAGE_FALL_BOTH = 2 };

// Random voice kinds, named by when they play.
enum { VOICE_ATTACK, VOICE_HEAVY_ATTACK, VOICE_HURT, VOICE_HEAVY_HURT, VOICE_KNOCKED_OUT };
enum { HEAVY_ATTACK_DAMAGE = 21, HEAVY_HURT_DAMAGE = 19 };

// sound_mask bits: the limbs whose touch of the floor sounds (skeleton A).
enum { SOUND_FEET = 2, SOUND_HIPS = 4 };

// Sound numbers of the hit sound by damage: punches and kicks.
static const int16_t PUNCH_SOUNDS[HIT_SOUND_STEPS] = {13, 14, 15, 16};
static const int16_t PUNCH_STEPS[HIT_SOUND_STEPS - 1] = {7, 14, 24};  // damage above step k: sound k + 1
static const int16_t KICK_SOUNDS[HIT_SOUND_STEPS] = {17, 18, 18, 19};
static const int16_t KICK_STEPS[HIT_SOUND_STEPS - 1] = {15, 20, 22};

// What the clip list held, sounded or not.
typedef struct {
    bool voice;      // selector 2: no attack voice
    bool hit_sound;  // selector 1, 7 or 8: no hit sound after the clips
} ClipsSeen;

// The leg bones among the TK6 hitbox codes (0..0x15 are bones in TK5's order). TK5 also counts the leg points; TK6's
// special point codes are not read yet (sim_contract.md 9.7).
static bool kicks(uint8_t hitbox_code) { return hitbox_code >= 14 && hitbox_code <= 21; }

// The guard sound on a guard, else the hit sound by the attacker's damage.
// (hole tk6-hit-sound-models :tags (tk6 audio) :sev polish) a hit on Jack-6 (model 19) plays 497, then 499 (kick) or 500 (punch) from 20 damage; a hit on Mokujin (model 18) one of 468..472 at random; both play the plain hit sound here.
static uint16_t hit_sound(const T6Fighter *attacker, const T6Fighter *opponent, bool kick) {
    if (opponent->guarded) return GUARD_SOUND;
    const int16_t *steps = kick ? KICK_STEPS : PUNCH_STEPS;
    int step = 0;
    while (step < HIT_SOUND_STEPS - 1 && attacker->damage > steps[step]) step++;
    return (uint16_t)(kick ? KICK_SOUNDS : PUNCH_SOUNDS)[step];
}

static uint32_t voice_word(uint32_t selector, uint32_t number) { return selector << T6_VOICE_SELECTOR_SHIFT | number; }
static uint32_t sound(uint16_t number) { return voice_word(SELECTOR_SOUND, number); }

// The clip as the presenter plays it, or T6_VOICECLIP_END when the game plays nothing this frame.
static uint32_t played_clip(const T6Fighter *f, const T6Fighter *opponent, uint32_t clip, bool kick) {
    bool move_starts = f->frame == 1 && f->frame_changed && f->health > 0;
    switch (clip >> T6_VOICE_SELECTOR_SHIFT) {
    case SELECTOR_VOICE: case SELECTOR_VOICE_KIND_6: return move_starts ? clip : T6_VOICECLIP_END;
    case SELECTOR_SOUND: case SELECTOR_SPECIAL_ON_HIT: return f->hit_landed ? clip : T6_VOICECLIP_END;
    case SELECTOR_HIT_SOUND: case SELECTOR_HIT_SOUND_7:
        return f->hit_landed ? sound(hit_sound(f, opponent, kick)) : T6_VOICECLIP_END;
    case SELECTOR_SPECIAL: return clip;
    default: return T6_VOICECLIP_END;
    }
}

// entry: the clip in T6Motbin.voiceclips, -1 for the sounds after the clips.
static void send(T6World *w, const T6Fighter *f, uint16_t id, uint32_t value, int32_t entry) {
    T6CueKey key = {t6_side_of(w, f), T6_FROM_VOICE_CLIP, f->move, entry};
    t6_cue_add(&w->cues, w->frame, (T6Cue){T6_CUE_VOICE, id, value, key.side, key, {}, {}});
}

// The game rolls with libc rand(); here the roll comes from a copy of the sim RNG, which the fight never sees.
static void random_voice(T6World *w, const T6Fighter *f, T6Rng *voice_rng, uint16_t kind) {
    uint16_t roll = (uint16_t)(t6_rand(voice_rng) & ROLL_MASK);
    send(w, f, T6_VOICE_RANDOM, voice_word(kind, roll), -1);
}

static bool coin(T6Rng *voice_rng) { return t6_rand(voice_rng) & 1; }

static ClipsSeen fighter_clips(T6World *w, const T6Fighter *f, const T6Fighter *opponent, const T6Move *move, bool kick) {
    ClipsSeen seen = {};
    const T6Motbin *motbin = t6_set(w, f->move.set);
    if (move->voiceclips < 0 || move->voiceclips >= motbin->voiceclip_count) return seen;
    for (int32_t entry = move->voiceclips; entry < move->voiceclips + T6_VOICECLIPS && entry < motbin->voiceclip_count; entry++) {
        uint32_t clip = motbin->voiceclips[entry];
        if (clip == T6_VOICECLIP_END) break;
        uint32_t selector = clip >> T6_VOICE_SELECTOR_SHIFT;
        seen.voice |= selector == SELECTOR_VOICE;
        seen.hit_sound |= selector == SELECTOR_HIT_SOUND || selector == SELECTOR_HIT_SOUND_7 || selector == SELECTOR_SPECIAL_ON_HIT;
        uint32_t played = played_clip(f, opponent, clip, kick);
        if (played != T6_VOICECLIP_END) send(w, f, T6_VOICE_CLIP, played, entry);
    }
    return seen;
}

// The sound after the clips: a KO hit, the hit sound no clip played, or the swing at the first active frame. The game
// also needs a voice character; every fighter has one.
static uint16_t strike_sound(const T6Fighter *f, const T6Fighter *opponent, const T6Move *move, ClipsSeen seen, bool kick) {
    if (opponent->clean_hit && opponent->health <= 0) return (uint16_t)(kick ? KICK_SOUNDS : PUNCH_SOUNDS)[HIT_SOUND_STEPS - 1];
    bool reacts = f->reaction_rule == REACT_ALWAYS;
    if (!seen.hit_sound && f->hit_landed && reacts) return hit_sound(f, opponent, kick);
    if (f->frame_changed && f->frame == move->first_active && reacts) return kick ? SWING_KICK_SOUND : SWING_PUNCH_SOUND;
    return NO_SOUND;
}

static void fighter_sounds(T6World *w, T6Fighter *f, const T6Fighter *opponent, T6Rng *voice_rng) {
    const T6Move *move = t6_move_at(w, f->move);
    if (move == nullptr) return;
    bool kick = kicks(move->hitbox[0]);
    if (f->ko) random_voice(w, f, voice_rng, VOICE_KNOCKED_OUT);
    ClipsSeen seen = fighter_clips(w, f, opponent, move, kick);

    if (move->first_active != 0 && !t6_in_throw(f->throw.chain) && f->anim_changed && !seen.voice && coin(voice_rng))
        random_voice(w, f, voice_rng, f->damage > HEAVY_ATTACK_DAMAGE ? VOICE_HEAVY_ATTACK : VOICE_ATTACK);
    if (f->clean_hit && f->health != 0 && coin(voice_rng))
        random_voice(w, f, voice_rng, opponent->damage > HEAVY_HURT_DAMAGE ? VOICE_HEAVY_HURT : VOICE_HURT);

    uint16_t strike = strike_sound(f, opponent, move, seen, kick);
    if (strike != NO_SOUND) send(w, f, T6_VOICE_CLIP, sound(strike), -1);

    if (f->frame == move->window_start && f->frame != 1) {
        send(w, f, T6_VOICE_CLIP, sound(WINDOW_SOUND), -1);
        return;
    }
    uint32_t landed = f->limbs_a.below[BELOW_ROSE];
    bool feet_land = (f->sound_mask & SOUND_FEET) && (landed & (1u << LIMB_R_FOOT | 1u << LIMB_L_FOOT));
    bool hips_land = (f->sound_mask & SOUND_HIPS) && (landed & 1u << LIMB_HIPS);
    if (f->move_end || feet_land) send(w, f, T6_VOICE_CLIP, voice_word(SELECTOR_STAGE_STEP, 0), -1);
    else if (f->touchdown || hips_land) send(w, f, T6_VOICE_CLIP, voice_word(SELECTOR_STAGE_FALL, STAGE_FALL_BOTH), -1);
}

void t6_voice_clips_pass(T6World *w) {
    T6Rng voice_rng = w->rng;
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        T6Fighter *f = w->fighters[side];
        if (f->force_update) fighter_sounds(w, f, w->fighters[1 - side], &voice_rng);  // the game's sound flag of the side
    }
}
