// Presentation out of the sim (openwavu ws.md, two tiers): one-shot cues of move properties and hits, and the pose
// properties of a move. The presenter plays both; neither feeds back into the sim. Cues stay in a ring in the sim state,
// so a rollback fixes them; the view sends the last T6_CUE_FRAMES frames' cues.
#ifndef T6_CUE_H
#define T6_CUE_H

#include <stdint.h>

#include "sim/motbin.h"
#include "sim/phase.h"
#include "sim/vec.h"

// T6_CUE_NONE: no cue, the sim handles the property.
typedef enum : uint8_t { T6_CUE_NONE, T6_CUE_FX, T6_CUE_SOUND, T6_CUE_VOICE, T6_CUE_CAMERA, T6_CUE_HIT, T6_CUE_ANNOUNCE, T6_CUE_MUSIC } T6CueKind;

// The id of a hit cue: the sparks the game draws for it. Its value is the damage.
typedef enum : uint16_t {
    T6_SPARK_CLEAN,  // a clean hit, or a KO
    T6_SPARK_GUARD,
    T6_SPARK_TOUCH,  // a hit that makes no reaction
} T6Spark;

// The id of an announcer cue. Its value: the round, for T6_LINE_ROUND. Its owner: the winner, for T6_LINE_WINNER.
typedef enum : uint16_t {
    T6_LINE_ROUND,
    T6_LINE_FINAL_ROUND,
    T6_LINE_FIGHT,
    T6_LINE_KO,
    T6_LINE_TIME_UP,
    T6_LINE_DOUBLE_KO,
    T6_LINE_PERFECT,
    T6_LINE_GREAT,   // a close win
    T6_LINE_WINNER,  // the winner's name, then "wins"
    T6_LINE_DRAW,
} T6Line;

// The ids of the voice cues of the per-frame move sounds (voice_clip.c); a property's voice cue has the property id.
// T6_VOICE_CLIP: a move's clip, with selectors 1 and 7 turned into 6 and the sound number of the hit sound; after the clips,
// 6 a sound number, 9 and 10 the stage sounds as in a property value. T6_VOICE_RANDOM: kind as the selector, a roll of
// 0..0xfff as the number; the presenter plays row roll % count of the kind.
enum : uint16_t { T6_VOICE_CLIP = 0, T6_VOICE_RANDOM = 1 };

// A voice word in the TK6 form: selector << T6_VOICE_SELECTOR_SHIFT | number. Move clips and the values of the voice
// properties hold one (TK5: selector << 12).
enum { T6_VOICE_SELECTOR_SHIFT = 24 };
static constexpr uint32_t T6_VOICE_NUMBER_MASK = (1u << T6_VOICE_SELECTOR_SHIFT) - 1;

// The id of a music cue.
typedef enum : uint16_t { T6_MUSIC_START, T6_MUSIC_FADE } T6MusicCue;

// The list of a move a property fires from.
typedef enum : uint8_t {
    T6_FROM_CALL,          // a direct call (tests, harnesses)
    T6_FROM_FRAMES,        // the per-frame list
    T6_FROM_START,         // the start list
    T6_FROM_END,           // the end property
    T6_FROM_CANCEL,        // the instant properties of a cancel
    T6_FROM_GROUP_CANCEL,  // the instant properties of a group cancel
    T6_FROM_HIT,           // a hit record; entry: the record
    T6_FROM_ROUND,         // the round flow; entry: the phase
    T6_FROM_VOICE_CLIP,    // a move's voice clips; entry: the clip in T6Motbin.voiceclips, -1 for the sounds after them
} T6PropSource;

// Names one firing: the same state gives the same key, so a resimulated frame repeats it. entry: the place of the property
// in its table of the move set (properties, start properties or requirements).
typedef struct {
    T6Who side;  // the firing fighter; T6_NOBODY for an extra
    T6PropSource source;
    T6Ref move;  // the fighter's move as it fires
    int32_t entry;
} T6CueKey;

// id and value are the property's. An effect's anchor is a joint below 108, else a special point. It is the whole value, but for
// 0x801b, 0x801d, 0x802b, 0x802c and 0x803a: there it is the high byte, and the low byte is a record id, a row or a size.
typedef struct {
    T6CueKind kind;
    uint16_t id;
    uint32_t value;
    T6Who owner;  // whose voice bank, body or slot it plays on: the firing fighter, its target, or T6_NOBODY (common bank, screen)
    T6CueKey key;
    T6Vec3 position;   // mm, world: an effect's anchor, a hit's point; else zero
    T6Vec3 direction;  // a hit's: the way the hitbox travelled; else zero
} T6Cue;

enum { T6_CUE_FRAMES = 60 };  // the view sends the cues of this many frames: what the presenter can rebuild
enum { T6_CUE_RING = 128 };   // cues kept

typedef struct {
    uint32_t frame;   // the world frame it was sent on
    uint32_t number;  // counts every cue sent: the same in a resimulated frame, so its effect looks the same
    T6Cue cue;
} T6CueEntry;

typedef struct {
    T6CueEntry entries[T6_CUE_RING];  // cue number n at n % T6_CUE_RING
    uint32_t sent;
} T6CueRing;

void t6_cue_add(T6CueRing *ring, uint32_t frame, T6Cue cue);
// Forgets the cues, for a round start that counts the frames from 0 again; the numbers go on.
void t6_cue_clear(T6CueRing *ring);

// The last pose property of a layer (a hand shape, a face); it lasts until the next one or a round reset. Zero: none.
typedef struct {
    uint16_t id, value;
    uint32_t set_frame;  // world frame of the last set: a repeat of the same pose restarts the layer
} T6PoseProp;

#endif
