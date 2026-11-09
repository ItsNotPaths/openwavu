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
} T5MatchState;

enum { ROUNDS_MAX = 2 * 10 - 1 };  // the most rounds a match takes: rounds_to_win is at most 10

// A move set as init loads it, on the heap; a round copies it in.
typedef struct {
    char character[T5_NAME_BYTES];  // the db character whose moves these are
    uint8_t chara;                  // its move set id (T5Fighter.chara)
    T5FighterData data;
} T5Moveset;

// One side as init loads it.
typedef struct {
    T5Loadout loadout;
    int16_t model;  // its body model id (T5Fighter.chara_40); requirements compare it and the move set id
    const T5Moveset *round_movesets[ROUNDS_MAX];  // the move set of each round: one for most, Mokujin's from the seed
    T5FighterData data;  // the move set of this round, a copy (properties write its aliases)
} T5SideData;

// Read only after init, except each side's data, which a round start copies in and properties write (hole snapshot-range).
typedef struct {
    T5SideData sides[T5_FIGHTER_COUNT];
    T5Stage stage;
    char stage_id[T5_NAME_BYTES];
} T5MatchData;

extern T5MatchState t5_match;
extern T5MatchData t5_match_data;

// Puts the loaded fighters on the stage and starts the round flow.
void t5_match_begin(uint64_t seed);
const char *t5_view_begin(void);  // NULL or the failure

#endif
