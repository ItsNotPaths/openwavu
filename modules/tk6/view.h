// The stock TK6 sim view: what the presenter (gamerender.wasm) reads of the last sim frame (ow_sim_view, ow_view).
// Plain data, no pointers, so it copies between modules as bytes.
#ifndef T6_VIEW_H
#define T6_VIEW_H

#include "loadout.h"
#include "sim/look.h"
#include "sim/phase.h"
#include "sim/skel.h"
#include "sim/throw.h"
#include "sim/world.h"

enum { T6_VIEW_VERSION = 9 };

typedef struct {  // the fighter fields the presenter's hand poses read
    T6PoseProp right_pose, left_pose;  // the hand channel properties
    bool posable;          // a fighter kind: other kinds keep the sim's fingers
    bool posed;            // a property posed the hands in this move
    bool new_anim;         // the move change took another anim
    bool damaging;         // the move does damage
    bool clean_streak;     // in a clean-hit streak
    bool thrown;
    bool clean_hit;
    int32_t frames_to_active;  // the move's first active frame minus the move frame
    uint8_t hitbox_code;   // the move's first hitbox code; 0 = no move
} T6ViewHands;

typedef struct {  // the fighter fields the presenter's face reads
    T6PoseProp pose;       // the face property
    bool posable;          // a fighter kind
    bool posed;            // a property posed the face in this move
    bool move_started;     // the move changed in this frame
    bool state_4;          // the move has T6_MOVE_STATE_4
    bool hurt_unlooking;   // the move's body state has STATE_HURT_4 and the move does not look
    int32_t frames_to_active;  // the move's first active frame minus the move frame
    int16_t character_id, model_id;  // T6Fighter.chara, chara_40
} T6ViewFace;

typedef struct {  // the look-at fields the presenter's eyes read
    T6LookAim aim;
    T6HipsAim hips;
    float chest_yaw_change, chest_pitch_change;
    int32_t weight;        // 0..LOOK_WEIGHT_FULL
} T6ViewLook;

typedef struct {
    T6Loadout loadout;
    char moveset[T6_NAME_BYTES]; // the db character whose moves run this round (Mokujin takes another's)
    int32_t health, max_health;  // 16.16 fixed point
    int16_t wins;                // rounds won
    T6Rig rig;                   // mm; root translation = base position; B worlds are the slots a model's bones follow
    int8_t parent_a[T6_BONES_A]; // the skeleton's A parents, to rebuild posed bones
    int8_t parent_b[T6_BONES_B];
    T6ViewHands hands;
    T6ViewFace face;
    T6ViewLook look;
    T6Ref move;                  // set = the side whose move set it is: a thrown fighter plays its thrower's moves
    int16_t move_frame;          // 1-based
    int16_t move_yaw;            // 65536 a turn: camera shots are placed by it, not by facing
    T6Vec3 position;             // mm, on the floor: where camera shots are placed
    T6ThrowRole throw_role;      // a thrower's move camera category picks a throw shot; it follows the thrown fighter
} T6ViewFighter;

typedef struct {
    uint32_t version;  // T6_VIEW_VERSION
    uint32_t frame;
    T6Phase phase;
    int32_t phase_frame;  // frames of the phase so far
    uint32_t round;       // rounds started
    int32_t timer;        // frames left on the round clock
    uint32_t wins_needed;
    char stage[T6_NAME_BYTES];  // the db stage id
    T6ViewFighter fighters[T6_FIGHTER_COUNT];
    bool snap;             // a scene cut: the fighters jump, so the display must not blend into this frame
    int8_t focus;          // the side an intro or win pose is about, -1: none
    uint32_t cue_count;
    T6CueEntry cues[T6_CUE_RING];  // the cues of the last T6_CUE_FRAMES frames, oldest first
} T6View;

// The frame, each fighter's rig, parents, hand, face and look blocks, move and move yaw, and the recent cues, from the world.
void t6_view_poses(T6View *view, const T6World *w);

#endif
