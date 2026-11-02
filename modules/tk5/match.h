// The stock TK5 gameplay module's match: the world and fighters it steps (rollback state), and the data init loads.
#ifndef T5_MATCH_H
#define T5_MATCH_H

#include "loadout.h"
#include "sim/fighter.h"
#include "sim/stage.h"
#include "view.h"

typedef struct {
    T5World world;
    T5Fighter fighters[T5_FIGHTER_COUNT];
    float view_normal[2];  // xz direction from the fighters to the camera; screen sides follow it
} T5MatchState;

// A character's ids in the game: its move set (T5Fighter.chara) and its body model (chara_40), both compared by requirements.
typedef struct {
    uint8_t chara;
    int16_t model;
} T5CharacterIds;

// Read only after init, except the moves and aliases, which properties write (hole snapshot-range).
typedef struct {
    T5Loadout loadouts[T5_FIGHTER_COUNT];
    T5CharacterIds ids[T5_FIGHTER_COUNT];
    T5FighterData data[T5_FIGHTER_COUNT];
    T5Stage stage;
    char stage_id[T5_NAME_BYTES];
} T5MatchData;

extern T5MatchState t5_match;
extern T5MatchData t5_match_data;

// Puts the loaded fighters on the stage and starts the round flow.
void t5_match_begin(uint64_t seed);

#endif
