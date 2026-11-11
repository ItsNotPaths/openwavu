// The stock TK6 gameplay module's match: the world and fighters it steps (rollback state), and the data init loads.
#ifndef T6_MATCH_H
#define T6_MATCH_H

#include "loadout.h"
#include "sim/fighter.h"
#include "sim/stage.h"
#include "view.h"

typedef struct {
    T6World world;
    T6Fighter fighters[T6_FIGHTER_COUNT];
} T6MatchState;

enum { ROUNDS_MAX = 2 * 10 - 1 };  // the most rounds a match takes: rounds_to_win is at most 10

// A move set as init loads it, on the heap; a round copies it in.
typedef struct {
    char character[T6_NAME_BYTES];  // the db character whose moves these are
    uint8_t chara;                  // its move set id (T6Fighter.chara)
    T6FighterData data;
} T6Moveset;

// One side as init loads it.
typedef struct {
    T6Loadout loadout;
    int16_t model;  // its body model id (T6Fighter.chara_40); requirements compare it and the move set id
    const T6Moveset *round_movesets[ROUNDS_MAX];  // the move set of each round: one for most, Mokujin's from the seed
    T6FighterData data;  // the move set of this round, a copy (properties write its aliases)
} T6SideData;

// Read only after init, except each side's data, which a round start copies in and properties write.
typedef struct {
    T6SideData sides[T6_FIGHTER_COUNT];
    T6Stage stage;
    char stage_id[T6_NAME_BYTES];
} T6MatchData;

extern T6MatchState t6_match;
extern T6MatchData t6_match_data;

// Puts the loaded fighters on the stage and starts the round flow.
void t6_match_begin(uint64_t seed);
const char *t6_view_begin(void);  // NULL or the failure

#endif
