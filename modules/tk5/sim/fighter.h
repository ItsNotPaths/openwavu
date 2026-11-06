// One fighter or object: plain data with fixed-width fields and no pointers, so the
// layout is the same on wasm32 and native. References are indexes: objects by their PL position
// (t5_object), moves and pushbacks by T5Ref.
// tools/layout.py keeps that map for the diff harness.
#ifndef T5_FIGHTER_H
#define T5_FIGHTER_H

#include <stddef.h>

#include "sim/anim.h"
#include "sim/damage.h"
#include "sim/hit.h"
#include "sim/input.h"
#include "sim/limb.h"
#include "sim/motbin.h"
#include "sim/skel.h"
#include "sim/state.h"
#include "sim/throw.h"
#include "sim/world.h"

// Values of T5Fighter.kind, root_mode and hold_count.
enum { T5_KIND_FIGHTER = 0, T5_KIND_EXTRA = 15 };
enum { T5_ROOT_GROUND = 0, T5_ROOT_LAUNCH = 1, T5_ROOT_HEIGHT_ONLY = 2 };
enum { T5_HOLD_NONE = -1 };
enum { T5_UPDATE_INACTIVE = -1 };  // update_divider: the fighter does not update

// Moves, anims and skeleton of one slot. Properties write moves and aliases, so reset restores them.
// T5Move.anim indexes `anims`: the character bank, the common bank, then the embedded bank (tools/motbin2bin.py).
// Where the target of an aimed bone lies, seen from the bone: in front on its right or left, or behind (past AIM_BEHIND) on
// either side. Zero is "not seen yet".
enum T5AimZone : int32_t { AIM_ZONE_NONE, AIM_ZONE_RIGHT, AIM_ZONE_LEFT, AIM_ZONE_BEHIND_RIGHT, AIM_ZONE_BEHIND_LEFT };

// The turn of an aimed bone (radians, in the frame of its parent) and the zone of its target.
typedef struct {
    float yaw, pitch;  // sideways turn and up-down turn
    enum T5AimZone zone;  // which side the target is on, or behind
} T5AimState;

// The hips turn about the vertical: `yaw` now, `goal` the yaw it heads for.
typedef struct {
    float yaw, goal;  // where the hips are turned now, and where they are heading
    enum T5AimZone zone;  // which side the target is on, or behind
} T5HipsAim;

// An angle seen each frame and its change since the last frame (radians).
typedef struct {
    float change, last;  // how far the angle moved since last frame, and the angle of last frame
} T5AngleTrack;

// The move blend: over a few frames after a move change the pose eases from the old pose into the new one
// (BLEND_IN), or before a move change from the current move into the next (BLEND_TO_PENDING, BLEND_OUT at the end of a move).
enum T5BlendMode : int32_t { BLEND_OFF, BLEND_IN, BLEND_TO_PENDING, BLEND_OUT };

// A blend length or the part of it done: whole frames and move clock units (CLOCK_PER_FRAME a frame).
typedef struct {
    int32_t frames, clock;  // whole frames, and the same length in clock units
} T5BlendSpan;

// A pose: a frame of a move.
typedef struct {
    T5Ref move;  // which move the pose is from
    int32_t frame;  // which frame of that move
} T5PoseAt;

typedef struct {
    enum T5BlendMode mode;  // which kind of blend is running
    enum T5BlendMode previous_mode;  // the mode of the last step
    int32_t resume;               // a blend toward a pending move takes over where a blend out stopped
    T5BlendSpan asked;            // the length a start asked for
    T5BlendSpan length;           // the length of the running blend, taken from `asked` at the start
    T5BlendSpan done;             // done so far: counts down in BLEND_IN, up in the others
    T5Ref previous_move;          // the move as of the last step
    T5PoseAt from, to;            // the two poses of the start frame
    uint8_t started;              // a blend started in this step
    T5Vec3 offset;                // the hip offset the blend adds, times the ratio
    float ratio;                  // 0..1
    float saved_ratio;            // the ratio where a blend out stopped
    T5Mat4 delta[T5_POSE_BONES];  // the blend matrix of each A local, times the ratio
} T5MoveBlend;

// Look-at state of one fighter: how far the neck, head and hips are turned toward the opponent. Written by the look-at; reset
// by the look init. The game keeps it with the eyes and a lock count, which only the
// unported eyes read (harness/stock_look.h converts).
typedef struct {
    int32_t weight;               // 0..LOOK_WEIGHT_FULL: how much of the aim the neck and head take
    T5AimState head, neck;  // turn and target zone of the head, and of the neck
    float gaze_tilt;              // T5Gaze.tilt of the fighter, taken at the look init
    T5HipsAim hips;               // offset from the body yaw
    float hips_upper, hips_lower; // the limits of the hips offset
    T5AngleTrack chest_yaw, chest_pitch;  // the chest turn of the pose: a chest turning against the aim speeds it up
} T5LookState;


struct T5FighterData {
    T5Motbin moves;  // the move data of the character
    T5AnimBank character, common, embedded;  // the three animation banks
    const T5Anim **anims;  // every anim of the banks, in bank order
    uint32_t anim_count;  // how many anims there are
    T5Skeleton skeleton;  // the bone layout of the character
    T5Rig bind;
};

// The cancel scan looking ahead past a move end (read by requirements 124..126).
enum T5ScanMode : uint32_t { SCAN_OWN_MOVE, SCAN_AHEAD };
typedef struct {
    enum T5ScanMode mode;  // scanning the own move, or looking ahead past its end
    bool set;                           // the cancel being looked ahead from
    uint16_t window_start, window_end;  // the cancel's window
} T5ScanAhead;

// The flags a cancel gives the move change (extradata bits 14..17, transition.h), kept until the change.
typedef struct {
    uint8_t no_blend_out;  // the current move does not blend out
    uint8_t turn;          // the new move turns the fighter around
    uint8_t no_root_fix;   // the new anim starts on the anchor as it is (no root fix, no throw snap)
    uint8_t root_hips;     // the root fix takes the hips with the root
} T5PendingFlags;

// T5Fighter.pick_kind: how the pending move was picked.
enum T5PickKind : uint8_t {
    PICKED_NONE,
    PICKED_REACTION,  // a reaction to a hit
    PICKED_CANCEL,    // a cancel of the move (or a forced move)
    PICKED_AHEAD,     // a cancel of the move that follows, looked ahead past the move's end
    PICKED_MOVE_END,  // the move ran out: its end entry
};

enum { T5_MOVE_OVERWRITE_COUNT = 16 };  // slots one round can overwrite; a full table drops the edit

// A slot of the fighter's move set that PROP_OVERWRITE_MOVE rewrote. The loaded moves stay read-only, so the edit
// is in the snapshot.
typedef struct {
    int16_t index;
    T5Move move;
} T5MoveOverwrite;

struct T5Fighter {
    // identity and references
    int32_t kind;                // 0 fighter, 15 extra (the mobs 1..14 and 16 of stock T5 are not in the sim)
    uint32_t ai_signal;
    uint16_t slot;               // 0 or 1
    int16_t side_index;          // 0 or 1
    int16_t chara;               // character id
    int16_t chara_40;            // character id of the radius tables
    int16_t costume;  // which costume the fighter wears
    uint8_t data;                // own move data: a slot of w->data
    uint8_t moveset;             // the slot move ids resolve in (the thrower's during a throw)
    uint8_t moveset_scan;        // the slot the last cancel scan took its group cancels and input sequences from
    uint8_t moveset_decided;     // moveset as of the decide pass
    T5MoveOverwrite move_overwrites[T5_MOVE_OVERWRITE_COUNT];  // edits of the set of this fighter's slot, for the round
    uint32_t move_overwrite_count;
    int16_t opponent;            // object index
    int16_t target;              // look/target object
    int16_t hit_targets[T5_HIT_TARGETS];  // objects hit by this move; reqs 219..226 read [0]
    T5Ref move;                  // current move
    T5Ref anim_move;             // move that owns the anim
    T5Ref alternate_move;               // set by `PROP_ALTERNATE_MOVE`
    T5Ref pending_move;  // the move that starts at the next move change
    T5Ref pushback;
    T5Ref pushback_curve;        // cursor in the pushback curves

    // position and motion
    T5Vec3 position;             // anchor x, y (up), z
    T5Vec3 previous_position;    // anchor at the start of the frame's root motion
    float body_yaw;              // facing + anim root yaw, radians in [-pi, pi]
    T5Vec3 bone0;                // root translation (channel 0, scaled)
    T5Vec3 bone1;                // hip translation (channel 1, scaled)
    T5Vec3 root_offset;          // bone0 + bone1
    float look_yaw;              // radians, written by the look-at
    float drift_speed;
    float scale_xz_add;          // extra horizontal root scale
    T5Vec3 velocity;
    float landing_y;             // root height at the landing frame of a launch
    float wall_factor;           // facing-to-wall factor
    float distance;              // distance to the opponent
    float distance2;             // second distance
    T5Vec3 previous_root;
    float last_base[4];          // base position and its w at the last root delta pass
    T5Vec3 base_delta;           // per-frame base delta; .y is the vertical speed
    float base_delta_w;
    float sway_scale;            // floor sway scale
    float last_y;                // position.y at the last root delta pass
    T5Vec3 push;                 // fighter push this frame
    float slide_step[2];         // x, z moved per frame during the slide
    float scale_xz;              // horizontal body scale
    float scale_y;               // vertical body scale
    float scale_base;            // body scale of the character
    float previous_scale_y;      // vertical scale the blend starts from
    int32_t scale_blend;         // blend counter, 10 = no blend
    T5Vec3 base_position;
    float base_position_w;       // base_pos w
    T5Mat4 root_copy;            // the root matrix as of the root matrix pass
    int16_t root_angle_x;        // euler x of the root matrix (usually 0)
    int16_t root_angle_z;        // euler z of the root matrix (usually 0)
    T5Vec3 root_local;           // bone1 with the blend added; .y is the height over the floor with move flag 8
    uint8_t alternate_to_frame;  // `PROP_ALTERNATE_TO_FRAME`: the blend to alternate_move samples frame value - 1
    uint8_t alternate_blend_length;  // `PROP_ALTERNATE_BLEND_LENGTH`: length in frames of the blend to alternate_move
    int16_t move_yaw;
    int16_t target_angle;        // angle to the target
    int16_t facing;  // the direction the fighter faces
    int16_t reference_yaw;       // facing, turned half a circle, or the look yaw
    int16_t side_angle;          // facing - angle to the target
    int16_t reference_side_angle;  // reference_yaw - target_angle
    int16_t opponent_angle;      // |side_angle| (ones' complement)
    int16_t angle_84;            // |reference_side_angle|
    int16_t side_band;           // band 0..3 of side_angle
    int16_t hit_side;            // 0 front, 1 left, 2 back, 3 right
    int16_t near_side_angle;     // target_angle, or half a turn off it when the opponent is behind the look yaw (far only)
    int16_t reference_near_side_angle;  // the same off the reference yaw
    int16_t turn_total;          // turn applied by tracking
    int16_t pivot_bone;          // -1 = none
    int16_t drift_angle;
    int16_t spin_frames;
    int16_t spin_speed;
    int16_t wall_slide_mode;
    int16_t push_weight;         // 4096 = 1.0
    int16_t push_counter;        // frames left in which a throw softens the push of the pair; the game keeps one for all
    int16_t slide_frames;        // frames left of the slide (prop 200, throw snap)
    int16_t turn_frames;
    int16_t turn_speed;
    int16_t countdown;           // tracking gate
    T5FacingState facing_state;  // the stock mode byte, as tracking row, phase and data set
    T5TrackingPick track_pick;   // the tracking that the pending move change starts, set with the transition word
    uint8_t side_band_table;     // index into the side band table of the moveset
    uint8_t drift_absolute;
    uint8_t no_gravity;  // gravity does not pull on the fighter
    uint8_t use_angle_84;
    uint8_t pivot_request;       // re-pivot the anchor at the next motion step (motion step 6)
    uint8_t skip_motion;
    uint8_t anim_changed;        // the move change took another anim (or a reaction, or a cancel picked ahead)
    uint8_t move_end;            // the move ran to its end this frame (voice code reads it)
    uint8_t touchdown;           // a launch landed, or a move ended in a hit-down state (dust and voice code read it)
    uint16_t old_facing;         // facing at the start of the movement step
    uint8_t in_air_window;       // in the air window of the move (window_start..window_end: the air frames of a jump), or juggled

    // move clock and state
    float anim_time;             // frame as float, 1-based
    uint32_t state;              // state/vuln word
    uint32_t state_copy;
    int32_t speed;               // frame speed, 4096 = 1
    int32_t speed_max;
    int32_t speed_min;
    int16_t frame;               // frame in the move, 1-based
    int16_t frame_decided;       // frame as of the decide pass
    int16_t previous_frame;      // frame before the last advance
    int16_t frame_9c;            // clock / 4096
    int16_t frame2;              // second frame counter (1 = first frame)
    int16_t previous_frame2;
    int16_t move_frames;         // frames since move start
    int16_t hold_count;
    int16_t play_direction;      // +1/-1
    int16_t update_divider;      // -1 = inactive
    uint16_t roll;               // G_rng roll taken at move start
    uint16_t hit_level;
    uint16_t guard_mask;
    uint8_t state_class;
    uint8_t move_start;          // first frame of the move
    uint8_t keeps_throw_immune;
    uint8_t throw_immune;
    uint8_t can_act;             // cancel frame reached (the stats code reads it)

    // the pending transition
    uint16_t transition;         // pending transition word
    uint16_t start_param;
    int16_t pending_id;
    int16_t pending_id_high;
    int16_t pending_frame;
    T5PendingFlags pending_flags;  // Rename later: pending_cancel_flags?
    enum T5PickKind pick_kind;   // Rename later: pick_source?
    int16_t launch_index;        // entry of the generic juggle reaction
    uint16_t lookahead_move;     // id of the cancel whose follow-up move the lookahead scanned
    uint8_t alternate_from_frame;  // `PROP_ALTERNATE_MOVE` (the frame): the blend from this move starts at this + length - 1

    // move variables and the cancel scan
    uint16_t vars[7];            // move variables (T5MoveVar)
    int16_t move_local_var;             // MOVE_VAR_LOCAL
    int16_t blend_length_override;  // `PROP_BLEND_LENGTH`: blend length for a move change, -1 = pick the length
    uint16_t cancel_lock;
    uint16_t option8;            // in/out of the cancel scan

    // hits landed and taken
    T5HitRecord records[T5_HIT_RECORDS];  // hits taken this frame
    T5Throw throw;               // partner, chain (a signed count), its copy, wall hit, the targets:
                                 // range, position code, state, move id
    int16_t juggle_count;        // hits in the juggle, counted by the move tick
    int16_t damage;
    T5SelfDamage self_damage;    // the effect (the game's mode byte), the points
    uint16_t reversal_damage;    // set by a reversal: half the opponent's damage + 25
    int16_t hit_lockout;         // frames left in which no further hit lands: a hit sets 4, a frame counts it down
    int16_t juggle_weight;
    int16_t thrown_length;
    int16_t force_counter_hit;
    int16_t air_reaction_list;   // the picked hit condition held REQ_AIR_REACTION: an air hit reacts from its reaction list
    int16_t reach_hit;           // the picked hit condition held REQ_NEAR (no reader)
    uint8_t attack_kind;         // high byte of the hit level of the move (guard.h ATTACK_KIND_*)
    uint8_t hit_this_move;       // was hit since the move started
    uint8_t landed_this_move;    // landed a hit in this move (a move change keeps it on the frame of a hit)
    uint8_t landed_since_move_start;  // landed a hit since the move started (no reader)
    uint8_t latch_result;        // result of reqs 106..108
    uint8_t hitbox_slots;        // slots that get points (0..2)
    uint8_t stance_rule;         // how the stance is found (T5StanceRule)
    uint8_t hides_attack;
    uint8_t reaction_facing;
    uint8_t hit_taken;           // hit registered this frame (defender)
    uint8_t guarded;
    uint8_t hit_landed;          // attack hit something this frame
    uint8_t whiffed;            // the attack hit nothing
    uint8_t pushed;              // set when the push solve moved this fighter
    uint8_t counter_hit;         // the hit taken was a counter hit
    uint8_t clean_hit;
    uint8_t ko;                  // the fighter is knocked out
    uint8_t ko_scored;           // set on the attacker when this object takes the KO; cleared by the damage pass
    int16_t damage_raw_frame;    // base damage of the hits taken this frame, plus self damage
    int16_t damage_taken_frame;  // health damage of this frame
    int16_t damage_hits_frame;   // final damage of the hits plus the second self damage sum
    uint16_t damage_absolute;
    uint8_t active_hitboxes;     // active hitbox count
    int8_t hit_record;           // the record of the hit that counts (a pointer in the game), -1 none

    // pushback
    float pushback_distance;     // distance per frame
    int16_t pushback_frames;  // frames the pushback still runs
    int16_t pushback_curve_frames;
    int16_t pushback_angle;
    int16_t pushback_angle_start;  // the heading the pushback started with (a copy of pushback_angle)
    uint8_t no_push;
    uint8_t no_spark;

    // walls
    int16_t wall_angle;
    int16_t wall_count;
    int16_t wall_angles[2];
    int16_t wall_history_count;
    int8_t wall_bits[6];         // per-joint wall side bits
    uint8_t stage_hit_new;
    uint8_t input_window;        // the cancel scan saw a T5_OPTION_INPUT entry in its window, or looked ahead
    uint8_t lookahead;           // the cancel scan looked ahead
    float wall_push[4];          // xz push of the last wall solve (y and w zero)
    uint32_t stage_hit_ids[8];   // stage objects this fighter hit lately
    int16_t stage_hit_count;     // used entries of stage_hit_ids, 0..7
    int16_t stage_hit_sphere;    // joint sphere of the chain, -1 = any
    uint16_t stage_hit_power;    // least power of a stage object hit; the damage pass puts the hit total here
    uint8_t stage_hit_this_move;             // set by a stage object hit

    // health and round marks
    int32_t health;  // health left
    int32_t max_health;  // health at full
    int16_t wins;                // rounds won
    int16_t last_round;          // the outcome of the last round: T5_ROUND_WON, T5_ROUND_LOST, T5_ROUND_NONE
    int16_t sound_ids[8];        // one-shot sounds

    // presentation the view carries (cue.h): the last pose property of each layer
    T5PoseProp right_hand_pose;  // the right hand channel (A bones 51..65)
    T5PoseProp left_hand_pose;   // the left hand channel (A bones 66..80)
    T5PoseProp face_pose;        // the face layer
    T5PoseProp other_pose;       // the two other channels

    // bytes properties write; readers not ported
    bool hands_posed;            // a property posed the hands in this move: the presenter's automatic hand poses wait
    bool face_posed;             // the same for the face (the face of a voice waits)
    uint8_t throw_linked, sound_mask;
    uint8_t hip_drop_from_opponent, limbs_off, claims_stage_object, moves_with_opponent;
    uint8_t keeps_own_height;    // property: in a throw the fighter eases to its own height, not the pair's
    uint8_t marks_zero_damage;   // `PROP_MARKS_ZERO_DAMAGE`: a hit of 0 damage still marks the defender (zero_damage_hit)
    uint8_t air_move;            // the move has an air window or started in a juggle: a hit in it resets the body scale
    uint8_t can_lock_look;       // the look-at may lock on (set at a move change, a property clears it)
    uint8_t no_reaim;
    uint8_t ai_assist;
    uint8_t marked_finished;             // "the move is finished": the round reset clears it, `PROP_MOVE_FINISHED` sets it. The face step
                                 // sets it too, only when a face clip of at most 5 frames plays; the port has no face clips (docs/code-map.md 15)

    // written at a move change; readers not ported
    uint8_t approach_state;      // the approach slide to the opponent: 0 idle, 1 ready (a move change sets it), 2 running
    uint8_t was_guarding, streak_clean;
    uint8_t took_damage;         // health went down this frame (a move without T5_MOVE_KEEPS_TOOK_DAMAGE clears it)
    uint8_t reaction_rule;       // how a hit of this move makes the defender react (T5ReactionRule), from its hit condition
    uint8_t root_mode;           // root motion: 0 ground, 1 launch set (none), 2 airborne (height only)
    uint8_t end_yaw_flag;        // the old move's end yaw applies at the next move change
    uint8_t neutral_guard;       // neutral and straight down guard; a guard-locked state guards (pad fighters; CPU fighters hold back)
    uint8_t frame_changed;
    uint8_t zero_damage_hit;     // the hits of the frame came to 0 damage from an attacker with marks_zero_damage
    int16_t damage_dealt;        // damage of the last hit this fighter landed, plus its self damage
    uint16_t hit_streak;
    uint16_t applied_move_id, applied_transition;   // pending_id, transition of the move just applied
    uint16_t can_act_frame;      // the frame from which the move can be left: window start of the move's end entry, or its length
    int16_t repeat_timer;        // frames left to count a repeat of a transition 221..223
    uint16_t repeat_count;
    uint16_t repeat_transition;
    uint16_t change_frame;       // frame at the last move change
    uint16_t change_hips;        // pending_flags.root_hips at the last move change
    uint16_t change_turn;        // pending_flags.turn at the last move change
    int32_t opponent_start_x, opponent_start_z;      // base position of the opponent at the move change, truncated
    int32_t approach_x, approach_z;  // whole mm moved a frame during the approach slide
    float anim_time_at_clock;    // anim_time as of the move clock
    float launch_flag;           // nonzero while a launch flies (a launch-class move sets 1.0; landing clears it)
    T5Reaction reaction;         // list of the last hit (a pointer in the game)

    // port-only state
    int32_t clock, elapsed, secondary;  // move clocks, 4096 = 1 frame
    uint32_t transitions;
    uint16_t rejected_transition;
    uint8_t error;

    // input
    T5Input input;  // the buttons and directions the fighter is given
    T5History history;           // `PROP_CLEAR_HISTORY` clears it
    T5StdInput standard_input;   // the host's input for the pad of this fighter's side
    T5MenuButtons menu_pressed;  // the host's menu buttons pressed this frame: they skip the waits of the round flow
    bool force_update;           // bit 6 + side: the pose motion and the hit test treat the fighter as updating
    uint32_t ai_engaged;         // set = AI drives a pad fighter
    T5LookState look;  // how far the neck, head and hips are turned toward the target
    bool look_snap;              // (one flag in the game, cleared by the first look-at): this fighter's look-at jumps to its target
    T5ScanAhead scan_ahead;
    T5LimbDrop limb_drop;        // (one pair in the game)

    // shapes, bones and limbs
    T5Vec4 wall_history[6];      // wall contact points
    T5Vec4 previous_sphere[6];   // joint spheres of the last wall solve
    T5Body body;                 // the body measures of the character (BODY row); a host may give another row (practice dummy)
    T5BodyPoints body_points;    // the fixed bone points and the shots of the character (ANCH row)
    T5Gaze gaze;                 // how the character looks at the opponent (GAZE row)
    T5Hit hit;
    T5SpecialPoints special;
    T5LimbState limbs;           // skeleton B limbs
    T5LimbState limbs_a;         // skeleton A limbs
    T5Vec4 pose[T5_CHANNELS];
    T5Vec4 joints[T5_BONES_A];   // world translation of each bone record
    T5Mat4 stored[T5_POSE_BONES];  // A locals of the last step
    T5MoveBlend blend;
    T5Bone pose_scratch[T5_POSE_BONES];     // (one table for both fighters in the game; here each fighter has its own). Only `local`
                                 // is kept: rows 0..2 are rewritten by every pose, row 3 (the translations) is what the last writer left
                                 // (the blend reset, the aim prediction)
    T5Rig rig;                   // root, skeletons A and B
};

// The move variables in the order of the requirements and properties. MOVE_VAR_LOCAL is apart (the move change
// clears it), the others are T5Fighter.vars.
enum T5MoveVar : uint8_t {
    MOVE_VAR_COUNT_UP_A, MOVE_VAR_COUNT_DOWN_A, MOVE_VAR_COUNT_DOWN_B, MOVE_VAR_D, MOVE_VAR_E, MOVE_VAR_LOCAL,
    MOVE_VAR_COUNT_UP_B, MOVE_VAR_G, T5_MOVE_VARS,
};
static const int8_t MOVE_VAR_SLOT[T5_MOVE_VARS] = {0, 1, 2, 3, 4, -1, 5, 6};  // index of vars, -1 for move_local_var

[[nodiscard]] static inline uint16_t t5_move_var(const T5Fighter *f, enum T5MoveVar variable) {
    if (variable == MOVE_VAR_LOCAL) return (uint16_t)f->move_local_var;  // the local variable is kept apart
    return f->vars[MOVE_VAR_SLOT[variable]];  // the others sit in the vars table
}

static inline void t5_set_move_var(T5Fighter *f, enum T5MoveVar variable, uint16_t value) {
    if (variable == MOVE_VAR_LOCAL) f->move_local_var = (int16_t)value;  // the local variable is kept apart
    else f->vars[MOVE_VAR_SLOT[variable]] = value;  // the others sit in the vars table
}

// Off the ground for a hit: in the air window of the move or a juggle, or in a launched state.
[[nodiscard]] static inline bool t5_off_ground(const T5Fighter *f) { return f->in_air_window != 0 || t5_state_has(f->state, STATE_LAUNCHED); }

_Static_assert(sizeof(T5Ref) == 4, "T5Ref");

// Sizes for tools/layout.py, which mirrors these structs.
extern const uint32_t t5_fighter_size, t5_fighter_data_size, t5_world_size, t5_motbin_size;

// The inputs of one fighter, caller-owned: the files, and the anim banks the caller built from .anim files. The data keeps
// pointers into them, so they must outlive it.
typedef struct {
    T5Bytes moves, skeleton;
    T5AnimBank character, common, embedded;  // embedded.anim_count 0 = no embedded bank
} T5FighterFiles;

// (hole sim-files-drop :tags (tk5mod port)) tk5decomp's gates still load fighters from .t5m and .t5b: switch them to t5_load_fighter behind the parity gate, then drop these parsers and the Python installers.
bool t5_fighter_storage(const T5FighterFiles *files, size_t *bytes);  // arena bytes that t5_fighter_build takes
int t5_fighter_build(T5FighterData *data, const T5FighterFiles *files, T5Arena *arena);  // 0 on success
// The steps after data's moves and skeleton are read: the anim list, the rig, the move lengths.
size_t t5_fighter_finish_storage(uint32_t anim_count);  // arena bytes t5_fighter_finish takes
int t5_fighter_finish(T5FighterData *data, const T5FighterFiles *files, T5Arena *arena);  // 0 on success
static inline const T5Anim *t5_fighter_anim(const T5FighterData *data, uint32_t index) {
    return index < data->anim_count ? data->anims[index] : NULL;  // an index past the bank gives no anim
}
// Reaction hook over the loaded lists; context is the T5World.
const T5Reaction *t5_reaction_list(void *world, uint32_t set, uint32_t index);

// Moves the anchor and the base position together in the ground plane.
static inline void t5_shift_root(T5Fighter *f, float offset_x, float offset_z) {
    f->position.x = f->position.x + offset_x;
    f->position.z = f->position.z + offset_z;
    f->base_position.x = f->base_position.x + offset_x;
    f->base_position.z = f->base_position.z + offset_z;
}

// Reference helpers. A ref with index -1 resolves to NULL.
static inline T5Ref t5_ref(uint32_t set, int32_t index) { return (T5Ref){(int16_t)index, (uint8_t)set, 0}; }
static inline bool t5_ref_none(T5Ref ref) { return ref.index < 0; }
static inline const T5Motbin *t5_set(const T5World *w, uint32_t set) { return &w->data[set]->moves; }
static inline T5Motbin *t5_set_mutable(const T5World *w, uint32_t set) { return &w->data[set]->moves; }
// Where the fighter's edit of slot `index` of its set is in move_overwrites, or -1.
static inline int32_t t5_move_overwrite(const T5Fighter *f, int16_t index) {
    for (uint32_t overwrite = 0; overwrite < f->move_overwrite_count; overwrite++)
        if (f->move_overwrites[overwrite].index == index) return (int32_t)overwrite;
    return -1;
}
static inline const T5Move *t5_move_at(const T5World *w, T5Ref ref) {
    if (ref.index < 0) return NULL;  // no move for a missing ref
    const T5Fighter *owner = w->fighters[ref.set];  // set k belongs to the fighter in slot k
    int32_t edited = t5_move_overwrite(owner, ref.index);
    return edited >= 0 ? &owner->move_overwrites[edited].move : &t5_set(w, ref.set)->moves[ref.index];
}
static inline const T5Pushback *t5_pushback_at(const T5World *w, T5Ref ref) {
    return ref.index < 0 ? NULL : &t5_set(w, ref.set)->pushbacks[ref.index];  // no pushback for a missing ref
}
static inline const T5Anim *t5_anim_at(const T5World *w, T5Ref move) {  // the anim of a move
    return t5_fighter_anim(w->data[move.set], t5_move_at(w, move)->anim);
}

// A new fighter has no move to come, no blend, no hit target: the game holds null pointers there, the port needs -1
// (a zeroed T5Ref is move 0, a zeroed object index is fighter 1). Call it once when the fighter is made.
void t5_fighter_clear_refs(T5Fighter *f);

// Move lookups (plain ids index the moveset,  k the own alias table|32768 | k the own alias table| k the own alias table).
T5Ref t5_move_lookup(const T5World *w, const T5Fighter *f, int32_t id);
int32_t t5_move_alias(const T5World *w, const T5Fighter *f, uint32_t index);
T5Ref t5_own_move(const T5World *w, const T5Fighter *f, int32_t id);  // own moves, alias ids resolved

#endif
