// The stock TK5 sim view: what the presenter (gamerender.wasm) reads of the last sim frame (ow_sim_view, ow_view).
// Plain data, no pointers, so it copies between modules as bytes.
#ifndef T5_VIEW_H
#define T5_VIEW_H

#include "loadout.h"
#include "sim/look.h"
#include "sim/phase.h"
#include "sim/skel.h"
#include "sim/world.h"

enum { T5_VIEW_VERSION = 7 };

typedef struct {  // the fighter fields the presenter's hand poses read
    T5PoseProp right_pose, left_pose;  // the hand channel properties
    bool posable;          // a fighter kind: other kinds keep the sim's fingers
    bool posed;            // a property posed the hands in this move
    bool new_anim;         // the move change took another anim
    bool damaging;         // the move does damage
    bool clean_streak;     // in a clean-hit streak
    bool thrown;
    bool clean_hit;
    int32_t frames_to_active;  // the move's first active frame minus the move frame
    uint8_t hitbox_code;   // the move's first hitbox code; 0 = no move
} T5ViewHands;

typedef struct {  // the fighter fields the presenter's face reads
    T5PoseProp pose;       // the face property
    bool posable;          // a fighter kind
    bool posed;            // a property posed the face in this move
    bool move_started;     // the move changed in this frame
    bool state_4;          // the move has T5_MOVE_STATE_4
    bool hurt_unlooking;   // the move's body state has STATE_HURT_4 and the move does not look
    int32_t frames_to_active;  // the move's first active frame minus the move frame
    int16_t character_id, model_id;  // T5Fighter.chara, chara_40
} T5ViewFace;

typedef struct {  // the look-at fields the presenter's eyes read
    T5LookAim aim;
    T5HipsAim hips;
    float chest_yaw_change, chest_pitch_change;
    int32_t weight;        // 0..LOOK_WEIGHT_FULL
} T5ViewLook;

typedef struct {
    T5Loadout loadout;
    char moveset[T5_NAME_BYTES]; // the db character whose moves run this round (Mokujin takes another's)
    int32_t health, max_health;  // 16.16 fixed point
    int16_t wins;                // rounds won
    T5Rig rig;                   // mm; root translation = base position; B worlds are the slots a model's bones follow
    int8_t parent_a[T5_BONES_A]; // the skeleton's A parents, to rebuild posed bones
    int8_t parent_b[T5_BONES_B];
    T5ViewHands hands;
    T5ViewFace face;
    T5ViewLook look;
    T5Ref move;                  // set = the side whose move set it is: a thrown fighter plays its thrower's moves
    int16_t move_frame;          // 1-based
    int16_t facing;              // 65536 a turn
    T5Vec3 position;             // mm, on the floor: where camera shots are placed
} T5ViewFighter;

typedef struct {
    uint32_t version;  // T5_VIEW_VERSION
    uint32_t frame;
    T5Phase phase;
    int32_t phase_frame;  // frames of the phase so far
    uint32_t round;       // rounds started
    int32_t timer;        // frames left on the round clock
    uint32_t wins_needed;
    char stage[T5_NAME_BYTES];  // the db stage id
    T5ViewFighter fighters[T5_FIGHTER_COUNT];
    bool snap;             // a scene cut: the fighters jump, so the display must not blend into this frame
    int8_t focus;          // the side an intro or win pose is about, -1: none
    uint32_t cue_count;
    T5CueEntry cues[T5_CUE_RING];  // the cues of the last T5_CUE_FRAMES frames, oldest first
} T5View;

// The frame, each fighter's rig, parents, hand, face and look blocks, move and facing, and the recent cues, from the world.
void t5_view_poses(T5View *view, const T5World *w);

#endif
