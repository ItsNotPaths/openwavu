// Battle-wide state that the game keeps in globals. Passed in explicitly.
// The object table (PL) and the fighter data of each slot live here; a fighter names them by index.
#ifndef T6_WORLD_H
#define T6_WORLD_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/cue.h"
#include "sim/input.h"
#include "sim/limb.h"
#include "sim/phase.h"
#include "sim/rng.h"
#include "sim/skel.h"
#include "sim/vec.h"

typedef struct T6Fighter T6Fighter;
typedef struct T6FighterData T6FighterData;
typedef struct T6Reaction T6Reaction;

typedef struct T6Stage T6Stage;  // stage.h

// Game state the stage queries read besides the stage file (a recording can hold it).
typedef struct {
    float disabled_ceiling;  // the answer of the ceiling masks while the floor is disabled
    bool object_floor;       // a stage object provides the special floor
    float object_floor_y;    // its height
} T6StageState;

// Input of objects that read no pad: the CPU AI and the script source.
// context is passed back; a null function gives no input.
typedef struct {
    T6StdInput (*cpu)(void *context, const T6Fighter *f);  // (control 1)
    T6StdInput (*script)(void *context, const T6Fighter *f);  // control 2
    void *context;
} T6InputSources;

// Reaction lists of a move set (a hit condition holds the index): t6_reaction_list
// is the default, NULL = no reaction move for a throw victim.
typedef struct {
    const T6Reaction *(*list)(void *context, uint32_t set, uint32_t index);
    void *context;
} T6ReactionHooks;

enum { T6_FIGHTER_COUNT = 2 };  // the fighters of a match: the loops over fighters run to this
enum { T6_MODE_PRACTICE = 8 };  // T6World.mode of practice: health 0 is no KO

typedef struct T6World {
    uint32_t frame;
    T6Rng rng;
    T6Fighter *fighters[T6_FIGHTER_COUNT];
    T6FighterData *data[2];     // moves, anims and skeleton per slot; T6Ref.set and T6Fighter.data name a slot
    int32_t mode;               // match mode: 8 is practice (no KO at health 0)
    uint32_t mode_30;           // second game mode word; requirements compare it, 8 shows up in bonus stage checks
    uint32_t battle_state;      // 4: fighting; the start move cancels ask for it
    uint32_t scene_state;       // the outer scene machine
    uint32_t stage_id;
    uint32_t match_setting;     // first entry of the match config's list (-1 reads 1); requirements 160..162 compare it
    int32_t start_record;       // the stage start record the round init places the fighters on
    uint16_t practice_16;       // a practice setting word; requirements compare it, its meaning is unclear
    const T6Stage *stage;       // the stage collision and start points; required (t6_motion_setup and t6_match_start assert it)
    T6StageState stage_state;
    int16_t scene_turn;         // `PROP_SCENE_TURN`: the turn of both fighters at a scene start
    T6Fighter *extras;          // PL[2], extra k at extras[k]
    uint32_t extra_count;
    int32_t floor_disabled;     // nonzero = floor height 0
    const struct T6EffectHitboxes *effect_hitboxes;  // per side
    float distance;             // xz distance of the fighters' base positions
    float arena_centre[4];      // {x, 0, z, 1}: kept across frames, set by the arena pass
    float stage_depth;          // set by the stage; the arena pass uses it as "out of range"
    bool unpause;               // the frame the pause ends
    T6InputSources input_sources;
    uint16_t pushback_template[14];  // writable data: the juggle launch reads [3]
    T6ReactionHooks reactions;
    T6CueRing cues;             // the one-shot presentation of properties and hits (cue.h)
    uint32_t skip_apply_moves;  // the next apply-moves pass only clears it
    uint32_t no_damage;         // (mode 10): health stops changing
    uint32_t guard_chips;       // nonzero = every guarded hit chips
    int32_t force;              // forced full update. Round init sets 1, the end of the battle frame clears it
    T6LimbEnv limb_env;         // limb globals: origin_y, floor_origin (the image holds 1). none_y and the
                                // mode flags in it are refreshed by every motion step
    int32_t blend_snap_left;    // frames left without pose interpolation (t6_blend_snap). Stock: a countdown of producer calls

    // round flow (round.c): the phase table of the match, its rules and the round state
    const T6MatchFlow *flow;    // null: no round flow
    T6MatchRules rules;
    T6RoundState round;
    uint32_t round_seed;        // the RNG seed of a round (a tick counter in the game: the host must store it)
} T6World;

// The PL table: both fighters, then the extras (stage animals, the stock game's mobs, are not in the sim).
int32_t t6_extra_count(const T6World *w);
T6Fighter *t6_extra_entry(const T6World *w, int32_t extra);
uint32_t t6_fighter_order(const T6World *w);           // G_frame & 1
// The fighters in the turn order of the frame: P1 first on odd frames.
typedef struct { T6Fighter *first, *second; } T6TurnOrder;
T6TurnOrder t6_turn_order(const T6World *w);
// Fighters, then extras.
void t6_each_object(T6World *w, void (*visit)(T6World *w, T6Fighter *f));
// The extras only.
void t6_each_extra(T6World *w, void (*visit)(T6World *w, T6Fighter *f));

// Object references are positions in the PL table: 0, 1 the fighters, then the extras.
// -1 is none. Two positions can hold the same object; compare objects, not indexes.
T6Fighter *t6_object(const T6World *w, int32_t index);
int32_t t6_object_index(const T6World *w, const T6Fighter *f);  // first position of f, -1 if absent
T6Who t6_side_of(const T6World *w, const T6Fighter *f);  // a fighter's side; T6_NOBODY for an extra

int32_t t6_floor_disabled(const T6World *w);


// The row of the current phase; all false outside a match.
T6PhaseRow t6_phase_row(const T6World *w);
bool t6_phase_reads_pads(const T6World *w);  // the input pass runs
bool t6_phase_frozen(const T6World *w);      // the fighters stand still: no movement, throws or cancels (the flashback)

void t6_distance_pass(T6World *w);
void t6_arena_pass(T6World *w);  // far apart: pulls outside fighters onto the arena edge; close: centres the arena
void t6_input_pass(T6World *w);                        // input of the fighters
const T6Fighter *t6_human_player(const T6World *w);    // the pad fighter that throws are measured against: P1, or P2 when P1 is not on a pad
void t6_input_sample_of(T6World *w, T6Fighter *f);     // one sample of the pad (or the AI) of f

#endif
