// Limb solver of the skeleton build and its helpers.
#ifndef T5_LIMB_H
#define T5_LIMB_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/anim.h"
#include "sim/motbin.h"
#include "sim/skel.h"

typedef struct T5World T5World;  // world.h

// The limbs the solver keeps off the floor, and that hitbox aims move.
enum T5LimbId { LIMB_R_FOOT, LIMB_L_FOOT, LIMB_R_HAND, LIMB_L_HAND, LIMB_NECK, LIMB_HEAD, LIMB_HIPS, T5_LIMB_COUNT };

typedef struct {
    T5Vec4 push;        // floor correction, carried over frames (x 0.7 a frame)
    T5Vec4 push_step;  // push decay step: minus 0.3 of push a frame (not when paused)
    T5Vec4 world_now;   // world point of the limb bone, set by the snapshot
    T5Vec4 world_previous;  // the one before
    T5Vec3 contact;  // x, floor height + radius, z where the limb last touched
    float origin_level; // level of the second probe over the stage origin floor, kept near the last contact
    T5Vec4 offset;      // limb offset (x 0.9 a frame), read by the hitbox points
    float special_y;    // y at the last special-floor query
    uint8_t padding_1[12];
} T5Limb;

typedef struct { uint32_t kind; float y, special_y; } T5FloorCache;  // ground kind 9 in bits 24..27: special floor; special_y: the special floor height

// The hip drop of one skeleton: how far the body is lowered (the root's y offset) and how it leans on a rising floor.
typedef struct {
    float height;        // lowering of the body toward the floor target
    float fall_speed;    // falling speed of the drop
    float pelvis_twist;  // pelvis turn that follows the floor slope, smoothed (radians)
    float spine_twist;  // spine turn that follows the floor slope, smoothed (radians)
} T5HipDrop;

// Heights from the init, in mm.
typedef struct {
    float head_tilt;     // radians, smoothed (t5_limb_head)
    float neck_height;   // neck above the hips at rest: base lift + spine + neck lengths
    float base_lift;     // the base lift of the init (written, never read)
    float leg_reach;     // leg length from the hip to the sole, less the base lift: the room the drop bias can use
} T5LimbHeights;

// Limb state of one skeleton of one fighter.
typedef struct T5LimbState {
    T5Limb limb[T5_LIMB_COUNT];  // one per limb (see T5LimbId)
    T5HipDrop drop;  // hip drop of this skeleton
    float drop_last;                      // the hip drop as of the snapshot (the opponent's drop target reads it)
    float padding_2[3];
    T5Vec4 aim_offset[2];                 // per hitbox slot: the aimed end point minus the plain one
    T5Vec4 aim_end[2];                    // the plain end point at the last active frame
    T5Vec4 aim_goal[2];                   // the aimed end point
    float aim_start;                      // anim time the aim was set
    uint8_t aim_on[2], aim_limb[2];       // aim on per hitbox slot, its limb
    uint8_t padding_3[8];
    T5LimbHeights heights;
    uint32_t below[4];                    // limbs near the floor: now, last, rose, fell
    uint32_t below_special[4];            // same against the special floor
    T5FloorCache floor[T5_LIMB_COUNT];  // floor query cache per limb: height, kind, special height
    uint8_t padding_4[12];
    T5Vec4 head_probe;                    // head probe point, in head space
    float head_probe_radius;  // radius of the head probe, scaled by the head end length
    float segment_length[4];              // thigh, shin, upper arm, forearm
    float neck_length;                    // bone 3 x (the sixth length of the init; never read)
    uint8_t padding_5[8];
} T5LimbState;

// The stage floor values of the limb code; its queries go to the stage of the world (stage.h).
typedef struct {
    float origin_y;  // floor height at the stage origin (round init)
    float none_y;    // -: the height where no floor polygon is found
} T5Floor;

// Battle state the limb code reads and writes outside the fighter (the same for both fighters).
typedef struct {
    T5Floor floor;
    bool hip_snap;   // a round reset forces this frame: the hips take their target at once
    bool hip_bias;   // the hip target gets the foot height bias (show poses: T5PhaseRow.fight_pose off)
    bool floor_origin;  // the limb init floors origin_y at the fighter (1 in the image)
} T5LimbEnv;

// The hip drop of one fighter (single globals in the game: the fighter that runs second saw what the first left).
typedef struct {
    int32_t reset;   // set by the limb init; the next drop update takes its target and clears it
    float drop_b;    // hip drop of the last pass on skeleton B
} T5LimbDrop;

// What the limb code works on: one skeleton (A or B) of one fighter, with its limb state.
typedef struct {
    T5Rig *rig;  // the fighter's rig: bone records of A and B, and the root
    const T5Skeleton *skel;  // skeleton layout: bone parents of A and B
    int32_t skeleton;          // 0 A, 1 B
    T5LimbState *state;        // this skeleton's
    const T5LimbState *opponent;  // the opponent's, same skeleton
    T5World *world;            // its stage and limb_env
    bool paused;  // game paused: no push decay, aim update, offset shrink, drop update or head tilt
    T5Bone *scratch;           // 22 records, the rig the aim prediction poses; T5Fighter.pose_scratch
    T5LimbDrop *drop;          // T5Fighter.limb_drop
} T5LimbRig;

// The fighter fields of the limb pass.
typedef struct {
    bool off;                     // no limb pass
    int16_t frame2;               // 1 on the first frame of a move
    float anim_time;  // time in the move's animation
    uint16_t hit_level;  // hit level; aims are made only for the high levels and no height
    uint16_t transition;  // transition into the move; a carry transition changes how aims ease in
    const T5Move *move;  // the move being played
    bool target_airborne;         // the target is off the ground
    float position_y;  // fighter's y position
    float anchor_x, anchor_z;  // fighter's x, z at the frame start: the drop anchor for flag 8 moves
    float bone1_y;  // fighter's bone 1 y; the limb code does not read it
    uint8_t hip_drop_from_opponent;  // takes the hip drop target from the opponent
    bool in_window;  // in the air window of its move; the limb code does not read it
    uint32_t state;  // fighter state; the shin floor candidates count only at 0
    const T5Anim *anim;           // for the aim prediction
    float scale_xz, scale_xz_add, scale_y;  // body scale: x and z (plus the add), and y
    bool hold;                    // != 0 (`PROP_OTHER_POSE_FIRST`)
    float hold_angle[2];          // toe angles of the hold (not ported)
    float position_x, position_z;           // (limb init)
    float scale_base;  // base scale; the base lift is this times 1150
    T5HeadProbe head_probe;       // BODY row of the fighter
} T5LimbBody;

// Keep limb `limb_index` (`point`, probes `probe` and `probe2`) at least `radius` above the floor of w's stage
// (`probe2`: above origin_y); carries the correction in the limb's push. Moves `point` and returns true when the
// correction is 1 or more. `probe2` may be null.
bool t5_limb_floor(T5LimbState *limbs, int32_t limb_index, float radius, T5Vec4 *point, const T5Vec4 *probe, const T5Vec4 *probe2,
                   bool paused, const T5World *w, float origin_y);

// Hip drop: lowers the body (base y, root world y) toward the floor target and sets the pelvis and spine
// twists (T5HipDrop). The limb_env's `hip_bias` adds the foot height to the target.
void t5_limb_drop(const T5LimbRig *limb_rig, T5LimbBody *body);

// The limb pass of one skeleton: worlds, limb offsets and their hitbox aims, hip drop and twists, legs, toes,
// neck, head, arms. `mode` is the key decoder mode (the aim prediction samples the anim).
void t5_limb_pass(const T5LimbRig *limb_rig, T5LimbBody *body, T5KeyMode *mode);

// Limb init of one skeleton (round init and the teleport move property): clears the limb state, puts
// the base on the fighter at the floor plus 1150, sets the head probe. Floors limb_env.floor.origin_y when
// limb_env.floor_origin; sets drop->reset and drop->drop_b; raises the head end point (bone 22 z) to 150 if under 10.
void t5_limb_init(const T5LimbRig *limb_rig, const T5LimbBody *body);

// Limb points of one skeleton: the world points move to world_prev, then take the world positions of the feet,
// hands, neck, head and hips of `rig_bones` (bone records of A or B); drop_last = drop.height.
void t5_limb_snapshot(T5LimbState *limbs, const T5Bone *rig_bones);

// The A worlds of the long form (see t5_skel_world_a_extra), then the snapshot of both skeletons.
// Does not do B worlds (t5_skel_world_b); `a` and `b` are the limb rigs of one fighter.
void t5_limb_worlds_long(const T5LimbRig *skeleton_a, const T5LimbRig *skeleton_b);

// Steps of the skeleton build that are not ported; a null `run` skips the step.
typedef struct { void (*run)(void *context, T5Rig *rig); void *context; } T5RigHook;
typedef struct {
    T5RigHook blend;  // motion blend loop and its store of A locals
    T5RigHook look;   // look-at (not in game mode 10): neck and head toward the opponent, writes look_yaw
} T5BuildHooks;

// step 13 (not paused): root world = root local, A posed from `pose`, the hooks, B rotations from A,
// the limb pass on B, then on A. `b` and `a` are the limb rigs of the two skeletons of this fighter.
// The face and finger poses only touch A bones 51 and up and are left out.
void t5_skel_build(T5Rig *rig, const T5Skeleton *skeleton, const T5Vec4 pose[T5_CHANNELS], const T5LimbRig *limbs_b,
                   const T5LimbRig *limbs_a, T5LimbBody *body, T5KeyMode *mode, const T5BuildHooks *hooks);

// World of bone i = local * parent world (the parent of the root bones is the rig root).
void t5_limb_world_of(const T5LimbRig *limb_rig, int32_t bone);
// `upper` and `lower` solved to reach the world position of `end` (length ids segment, segment + 1), then their worlds;
// `end` keeps its world rotation.
void t5_limb_reach(const T5LimbRig *limb_rig, int32_t upper, int32_t lower, int32_t end, int32_t segment, bool flip);

// Leg 0 (right) or 1 (left): foot kept above the floor by the thigh and shin; the toe and sole points follow.
// `before` gets the foot position before the correction.
void t5_limb_leg(const T5LimbRig *limb_rig, int32_t leg, T5Vec4 *before);
// Arm 0 (right) or 1 (left): hand kept above the floor by the upper arm and forearm.
void t5_limb_arm(const T5LimbRig *limb_rig, int32_t arm);

// Neck (limb 4) kept above the floor by turning the chest toward it.
void t5_limb_neck(const T5LimbRig *limb_rig);
// Head probe (limb 5) against the floor: tilts the neck about z (smoothed).
void t5_limb_head(const T5LimbRig *limb_rig);
// Toe 0 (right) or 1 (left): the sole point follows the foot's lift; the toe bends up when its tip is below
// the floor (or by `hold_angle` when `hold`). `before` is the foot position before the leg correction.
void t5_limb_toe(const T5LimbRig *limb_rig, int32_t toe, const T5Vec4 *before, bool hold, float hold_angle);

// Two-bone solve: turn `upper` (and bend `lower` about local z) so the chain end reaches `target` (world).
// `parent` is the world matrix of upper's parent; `flip` bends the other way (the legs).
void t5_limb_two_bone(T5Mat4 *upper, T5Mat4 *lower, const T5Mat4 *parent, float upper_length, float lower_length,
                      const T5Vec4 *target, bool flip);

#endif
