// The look-at: the hips, neck and head of a fighter turn toward the opponent's head, within limits and
// smoothed over frames. The eyes are cosmetic: the visual part aims them from t6_look_aim.
#ifndef T6_LOOK_H
#define T6_LOOK_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/fighter.h"
#include "sim/limb.h"
#include "sim/world.h"

// Look init (at the model init): the state at rest, the hips limits, the gaze tilt of the character, and the
// look yaw along the facing.
void t6_look_init(T6Fighter *f);
void t6_look_snap(T6World *w);                                  // every look-at jumps to its target once
void t6_look_limits(T6Fighter *f, float upper, float lower);    // the hips limits

typedef enum { AXIS_X, AXIS_Y, AXIS_Z } T6Axis;

typedef struct {
    T6Axis axis;
    int32_t steps;  // 65536 a turn
} T6Turn;

// The limits of an aimed joint (radians, in the frame of its parent).
typedef struct {
    float yaw_min, yaw_max;
    float pitch_down, pitch_up;
    float pitch_hold;  // the pitch waits while the yaw moves more than this
} T6AimLimits;

// A joint the look-at aims. The neck and head turn by the pitch about one axis, then by the yaw about another, then by
// fixed turns that line their frame up with the aim (the head's model frame). The hips turn about -y (`t6_look_hips`).
typedef struct {
    uint8_t bone, parent;  // parent: the bone whose frame the aim is seen in
    T6Axis pitch_axis, yaw_axis;
    uint8_t fixed_count;
    T6Turn fixed[3];  // applied after the pitch and yaw turns, in order
    T6AimLimits limits;
    float rate, fast_rate;  // share of the way a frame
    bool pitches;  // the joint also aims its pitch (hips do not)
    bool stops_behind;      // a target behind holds the yaw at the limit of its side and levels the pitch; else a clamp
    bool chest_speeds_up;   // twice the rate while the chest turns against the aim faster than the step
    bool leads_hips;        // locked on and turning against the hips goal, the aim leads by the hips turn still to come
} T6AimJoint;

extern const T6AimJoint T6_AIM_HIPS;  // its yaw limits are the ones at rest, a move sets its own (t6_look_limits)
extern const T6AimJoint T6_AIM_NECK;
extern const T6AimJoint T6_AIM_HEAD;  // without the character's head turn

// The head joint of a character: T6_AIM_HEAD and the head turn of its gaze.
[[nodiscard]] T6AimJoint t6_aim_head(T6Gaze gaze);

// The local of an aimed bone: its pose turned toward (yaw, pitch), mixed in by weight / LOOK_WEIGHT_FULL.
[[nodiscard]] T6Mat4 t6_aim_turn(T6AimJoint joint, T6Mat4 pose, float yaw, float pitch, int32_t weight);

// The zone of a yaw, and the zone rules of the aim step.
[[nodiscard]] enum T6AimZone t6_aim_zone(float yaw);
[[nodiscard]] static inline bool t6_aim_behind(enum T6AimZone z) {
    return z >= AIM_ZONE_BEHIND_RIGHT;  // both behind zones
}
[[nodiscard]] bool t6_aim_crosses_behind(enum T6AimZone last, enum T6AimZone now);  // from one side behind to the other
[[nodiscard]] enum T6AimZone t6_aim_zone_kept(enum T6AimZone last, enum T6AimZone now);  // both behind: keeps the last side
[[nodiscard]] float t6_aim_clamp(float value, float low, float high);  // NaN takes the high limit

// What an aim step reads besides its joint.
typedef struct {
    bool fast;                 // the joint's fast rate (neck, head: snap; hips: free)
    bool lock, look_on, snap;  // lock: the hips lead; looking on and no snap: the pitch may wait
    T6HipsAim hips;  // hips goal and yaw, for the lock lead
    float chest_yaw_change, chest_pitch_change;  // chest turn per frame, read by the neck and head speed-up
} T6AimFrame;

typedef struct {
    T6AimState aim;
    float yaw_goal;  // the yaw it heads for
} T6AimNext;

// One smoothing step of a joint from `last` toward `seen`, within its limits.
[[nodiscard]] T6AimNext t6_aim_step(T6AimJoint joint, T6AimState last, T6AimState seen, T6AimFrame aim_frame);

// Hips: step the hips aim toward `target` (a world point), turn the hips by it and re-solve the legs.
// `limb_rig` is the A skeleton of f. Locked on, or in a move with active frames, the hips turn slowly.
void t6_look_hips(const T6World *w, T6Fighter *f, const T6LimbRig *limb_rig, bool lock, T6Vec4 target);

// The look-at (motion step 13, after the blend): picks the targets, aims the hips, the neck and the head, and
// rebuilds the A worlds it changes. Clears the snap request. Never runs paused (the battle frame is not paused).
void t6_look_at(T6World *w, T6Fighter *f, const T6LimbRig *limb_rig);

// The direction from `eyes` to `target` in the frame of a bone's world, placed at the eyes.
[[nodiscard]] T6Vec4 t6_look_seen_from(const T6Mat4 *frame_world, T6Vec4 eyes, T6Vec4 target);

// What the head aims at, worked out again from the fighter after its step: for the visual part's eyes. Reads only.
typedef struct {
    T6Vec4 eyes, target;  // world: the point the fighter looks from, and the point the head aims at
    bool look_on, lock;
} T6LookAim;
[[nodiscard]] T6LookAim t6_look_aim(const T6World *w, const T6Fighter *f);

#endif
