// Presentation out of the sim (openwavu ws.md, two tiers): one-shot cues of move properties and hits, and the pose
// properties of a move. The presenter plays both; neither feeds back into the sim. Cues stay in a ring in the sim state,
// so a rollback fixes them; the view sends the last T5_CUE_FRAMES frames' cues.
#ifndef T5_CUE_H
#define T5_CUE_H

#include <stdint.h>

#include "sim/motbin.h"
#include "sim/phase.h"
#include "sim/vec.h"

// T5_CUE_NONE: no cue, the sim handles the property.
typedef enum : uint8_t { T5_CUE_NONE, T5_CUE_FX, T5_CUE_SOUND, T5_CUE_VOICE, T5_CUE_CAMERA, T5_CUE_HIT, T5_CUE_ANNOUNCE, T5_CUE_MUSIC } T5CueKind;

// The id of a hit cue: the sparks the game draws for it. Its value is the damage.
typedef enum : uint16_t {
    T5_SPARK_CLEAN,  // a clean hit, or a KO
    T5_SPARK_GUARD,
    T5_SPARK_TOUCH,  // a hit that makes no reaction
} T5Spark;

// The id of an announcer cue. Its value: the round, for T5_LINE_ROUND. Its owner: the winner, for T5_LINE_WINNER.
typedef enum : uint16_t {
    T5_LINE_ROUND,
    T5_LINE_FINAL_ROUND,
    T5_LINE_FIGHT,
    T5_LINE_KO,
    T5_LINE_TIME_UP,
    T5_LINE_DOUBLE_KO,
    T5_LINE_PERFECT,
    T5_LINE_GREAT,   // a close win
    T5_LINE_WINNER,  // the winner's name, then "wins"
    T5_LINE_DRAW,
} T5Line;

// The id of a voice cue from a move's voice clips (voice_clip.c); a property's voice cue has the property id. Its value: the
// clip, with selectors 1 and 7 turned into 6 and the common record of the hit sound.
enum : uint16_t { T5_VOICE_CLIP = 0 };

// The id of a music cue.
typedef enum : uint16_t { T5_MUSIC_START, T5_MUSIC_FADE } T5MusicCue;

// The list of a move a property fires from.
typedef enum : uint8_t {
    T5_FROM_CALL,          // a direct call (tests, harnesses)
    T5_FROM_FRAMES,        // the per-frame list
    T5_FROM_START,         // the start list
    T5_FROM_END,           // the end property
    T5_FROM_CANCEL,        // the instant properties of a cancel
    T5_FROM_GROUP_CANCEL,  // the instant properties of a group cancel
    T5_FROM_HIT,           // a hit record; entry: the record
    T5_FROM_ROUND,         // the round flow; entry: the phase
    T5_FROM_VOICE_CLIP,    // a move's voice clips; entry: the clip in T5Motbin.voiceclips
} T5PropSource;

// Names one firing: the same state gives the same key, so a resimulated frame repeats it. entry: the place of the property
// in its table of the move set (properties, start properties or requirements).
typedef struct {
    T5Who side;  // the firing fighter; T5_NOBODY for an extra
    T5PropSource source;
    T5Ref move;  // the fighter's move as it fires
    int32_t entry;
} T5CueKey;

// id and value are the property's. An effect's anchor is a joint below 108, else a special point. It is the whole value, but for
// 0x801b, 0x801d, 0x802b, 0x802c and 0x803a: there it is the high byte, and the low byte is a record id, a row or a size.
typedef struct {
    T5CueKind kind;
    uint16_t id, value;
    T5Who owner;  // whose voice bank, body or slot it plays on: the firing fighter, its target, or T5_NOBODY (common bank, screen)
    T5CueKey key;
    T5Vec3 position;   // mm, world: an effect's anchor, a hit's point; else zero
    T5Vec3 direction;  // a hit's: the way the hitbox travelled; else zero
} T5Cue;

enum { T5_CUE_FRAMES = 60 };  // the view sends the cues of this many frames: what the presenter can rebuild
enum { T5_CUE_RING = 128 };   // cues kept

typedef struct {
    uint32_t frame;   // the world frame it was sent on
    uint32_t number;  // counts every cue sent: the same in a resimulated frame, so its effect looks the same
    T5Cue cue;
} T5CueEntry;

typedef struct {
    T5CueEntry entries[T5_CUE_RING];  // cue number n at n % T5_CUE_RING
    uint32_t sent;
} T5CueRing;

void t5_cue_add(T5CueRing *ring, uint32_t frame, T5Cue cue);
// Forgets the cues, for a round start that counts the frames from 0 again; the numbers go on.
void t5_cue_clear(T5CueRing *ring);

// The last pose property of a layer (a hand shape, a face); it lasts until the next one or a round reset. Zero: none.
typedef struct {
    uint16_t id, value;
    uint32_t set_frame;  // world frame of the last set: a repeat of the same pose restarts the layer
} T5PoseProp;

#endif
