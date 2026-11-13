// Tuning values of the stock game: decimal, in their unit type. One place to read them.
#ifndef T6_CONSTANTS_H
#define T6_CONSTANTS_H

#include "sim/units.h"

// Round phases (round.c): the frames a phase lasts at most; the first frame counts 1.
static constexpr T6Frames READY_FRAMES = {168};        // the countdown
static constexpr T6Frames KO_FRAMES = {120};           // the KO fall or the time up
static constexpr int32_t FLASHBACK_ANGLES = 3;         // the host shows the flashback in this many camera angles
static constexpr T6Frames FLASHBACK_FRAMES_PER_ANGLE = {48};  // 0.8 s at 60 fps
static constexpr T6Frames FLASHBACK_FRAMES = {FLASHBACK_ANGLES * FLASHBACK_FRAMES_PER_ANGLE.ticks};  // frozen frames
static constexpr T6Frames ROUND_END_FRAMES = {256};    // the round win pose (stock: until 374 frames after the round end, less the KO)
static constexpr T6Frames MATCH_END_FRAMES = {16385};  // the match win pose
static constexpr T6Frames SETUP_FRAMES = {1};         // the frame of a round init: no wait or skip ends a phase in it
static constexpr T6Frames DEFAULT_ROUND_TIME = {3600};  // the round clock: one minute at 60 fps
static constexpr uint32_t DEFAULT_WINS_NEEDED = 2;  // round wins that take the match
// Frames a scene cut stays snapped (no pose interpolation). Stock counts 20 pose calls: 20 frames when one fighter poses, 10 when both do.
static constexpr T6Frames SNAP_ENTRANCE = {20};  // the entrance scene cut
static constexpr T6Frames SNAP_ROUND = {10};  // the round setup cut (round start and round end)
static constexpr T6Frames SNAP_MATCH_END = {20};  // the match end cut
// A dash command (N then a direction) and a tap command (a direction then N) must fit in this many frames of history.
static constexpr T6Frames DASH_FRAMES = {20};  // the frame window of a dash command
static constexpr T6Frames TAP_FRAMES = {16};  // the frame window of a tap command
// The arena (world.c t6_arena_pass): fighters further apart than the pull-in distance are pulled back onto the ring.
// (hole tk6-stage12-arena :tags (tk6 sim) :sev polish) stage 12 uses radius 5000, pull-in 7391.95; the db has no column, one arena for all.
static constexpr float ARENA_RADIUS = 4012.0f;    // mm
static constexpr float ARENA_PULL_IN = 5931.3f;   // mm
static constexpr float RING_OUT_DISTANCE = 7000000.0f;  // ground distance from the stage origin: this far or more is a ring out

static constexpr T6Health OBJECT_START_HEALTH = {5242880};  // 80.0
static constexpr uint32_t KO_HARD_DAMAGE = 13;  // points: killing hits of this much take the hard KO moves (scenario modes: 11)

// --- Facing (facing.c). The tracking rows are data; these are the values the laws keep.
static constexpr T6Degrees TURN_RATE_SPREAD_MAX = {14};  // degrees a frame
static constexpr T6Degrees TURN_RATE_REAIM = {3};  // top turn speed of a re-aim, degrees a frame
static constexpr T6Degrees SIDE_TARGET_OFFSET = {10};  // degrees to the side of the opponent that the side target aims
static constexpr T6Degrees REAIM_OPPONENT_LIMIT = {120};  // no re-aim when the opponent is further off than this
static constexpr T6Angle BEHIND_ANGLE = {ANGLE_FROM_DEG(112)};  // "opponent behind" for the move start align
static constexpr T6Frames REAIM_PERIOD = {5};  // a re-aim runs every this many frames after the first active frame
static constexpr T6Frames REAIM_MIN_TURN = {5};  // the shortest re-aim turn, in frames
static constexpr int32_t CLOSE_APPROACH_NUMERATOR = 50000;  // approach by distance: this / (distance + offset)
static constexpr int32_t CLOSE_APPROACH_OFFSET = 5000;      // world units

// --- Movement (root_motion.c, move_timers.c). Units: mm, frames, mm/frame^2.
static constexpr float GRAVITY = 6.0f;                      // mm/frame^2 downward
static constexpr int32_t APPROACH_FAR_DISTANCE = 3072;      // mm: past this the approach slide covers APPROACH_FAR_TRAVEL
static constexpr int32_t APPROACH_FAR_TRAVEL = 2572;        // mm
static constexpr int32_t APPROACH_STOP_GAP = 500;           // mm left between the fighters
static constexpr float PUSH_SPEED_UNIT = 1.0f / 256.0f;     // forward push and drift speeds count 1/256 mm a frame
static constexpr int32_t PUSHBACK_STREAK_FREE = 3;          // repeats of a hit before the pushback grows
static constexpr int32_t PUSHBACK_STREAK_STEP = 40;         // mm a repeat past it adds
static constexpr int32_t PUSHBACK_STREAK_BASE = 10;         // mm
static constexpr int16_t JUGGLE_WEIGHT_FREE_LENGTH = 30;    // the juggle weight counts down once the thrown length is this or less
static constexpr uint16_t COUNTER_MAX = 65535;              // the counters that count up stop here

// --- Walls (wall.c). Units: mm; angles in steps of 65536 a turn.
static constexpr float WALL_RADIUS = 150.0f;                // joint sphere against a wall
static constexpr float WALL_RADIUS_NECK = 225.0f;  // neck sphere against a wall: bigger than the others
static constexpr float WALL_MIN_HEIGHT = 50.0f;             // a wall quad must be this tall to push
static constexpr int32_t WALL_SOLVE_CAP = 100;              // rounds of the six spheres, and passes of one sphere
static constexpr uint16_t WALL_FACING_LIMIT = 9104;         // the contact faces the wall if the angle to it is less (about 50 degrees)
static constexpr float WALL_FACING_FULL = 1.3f;             // the facing factor is this minus angle / WALL_FACING_SCALE, at most 1
static constexpr float WALL_FACING_SCALE = 9104.0f;  // the angle that takes 1.0 off the facing factor (about 50 degrees)
static constexpr int32_t WALL_HISTORY = 6;                  // contact points kept per fighter

// --- Body push (body_push.c). Units: mm; the push code's angles have 4096 steps a turn (units.h).
static constexpr float PUSH_CROSS_DEPTH = 400.0f;           // least depth when the facing lines cross
static constexpr float PUSH_CROSS_HEIGHT = 300.0f;          // the fighters cross only if their heights differ by less (or touch)
static constexpr float PUSH_CROSS_REACH = 200.0f;           // the facing point is this far in front of the base position
static constexpr float PUSH_CROSS_RANGE = 500.0f;           // the facing points must be closer than this on each axis
static constexpr int32_t PUSH_SOFTEN_FRAMES = 16;           // frames the push is softened after a throw
static constexpr float PUSH_EVEN_SHARE = 0.5f;             // each fighter takes half of the push, unless softened
static constexpr float PUSH_STANDSTILL_TRAVEL = 1.0f;       // two fighters that have not moved count as having moved this much each
static constexpr float PUSH_SOFTEN_SHARE = 0.2f;            // of the summed travel, added to each fighter's share while softened
static constexpr int16_t PUSH_WEIGHT_FULL = 4096;           // T6Fighter.push_weight of 1.0

// --- Damage (damage.c). Units: health points; T6Ratio shares truncate toward zero.
static constexpr T6Ratio CHIP_SHARE = {1, 10};              // of the attack's damage, when the guard chips
static constexpr int32_t CHIP_ADD = 2;                      // points a chip adds to its share
static constexpr T6Ratio COUNTER_HIT_SCALE = {12, 10};  // counter hit: the damage times this, then the counter bonus
static constexpr T6Ratio COUNTER_BONUS_SHARE = {3, 10};     // of the defender's own attack damage; twice over unless forced
// A hit on an airborne fighter, by the juggle hits before it; JUGGLE_LATE_SCALE past the table. A hit that did damage
// keeps at least 1 point.
static constexpr T6Ratio JUGGLE_SCALES[] = {{60, 100}, {50, 100}, {50, 100}, {45, 100}, {45, 100}, {45, 100},
                                            {40, 100}, {40, 100}, {40, 100}};
static constexpr T6Ratio JUGGLE_LATE_SCALE = {30, 100};
static constexpr T6Ratio FALLEN_SCALE = {70, 100};          // a hit on a fallen fighter
// The stock T6MatchRules of TK6 (lobby params).
static constexpr int32_t CLEAN_HIT_BONUS_PERCENT = 20;      // clean_hit_bonus
static constexpr int32_t RAGE_HEALTH_POINTS = 20;           // rage_health
static constexpr int32_t RAGE_BONUS_PERCENT = 35;           // rage_bonus
static constexpr int32_t BOUNDS_PER_COMBO = 1;              // bounds_per_combo

// --- Hits (hit.c)
static constexpr T6Frames HIT_LOCKOUT = {4};                // no further hit lands on a fighter who took a damaging or airborne hit
static constexpr T6Frames JUMP_WINDOW_END_CUT = {3};  // lows miss a jumping fighter until this many frames before window end

// --- Throws (throw.c)
static constexpr T6Frames THROW_SLIDE_FRAMES = {16};        // the victim slides to the spot of the thrower's start over this many frames
static constexpr T6Frames THROWN_FRAMES_MAX = {300};        // the thrown length counts at most this many frames
static constexpr int16_t THROWN_JUGGLE_WEIGHT_MIN = 34;     // a throw puts the victim's juggle weight in this..JUGGLE_WEIGHT_MAX
static constexpr int16_t JUGGLE_WEIGHT_MAX = 66;  // the top of the juggle weight

// --- Body scale (pose.c)
static constexpr int32_t SCALE_EASE_STEPS = 10;            // pose steps the height eases over after a throw or a hit in the air
static constexpr float PAIR_HEIGHT_SMALLER = 0.8f;          // the pair of a throw takes this share of the smaller scale
static constexpr float PAIR_HEIGHT_LARGER = 0.19999999f;    // and this of the larger (the game's float, one ulp under 0.2)

// --- Ride (pose.c ride_scale): a thrower who rides the partner is lifted by the partner's head height.
static constexpr float RIDE_REFERENCE_HEAD_TOP = 1750.0f;  // mm: about a standard human head top; at it the rider keeps its height
static constexpr T6Frames RIDE_EASE_START = {56};          // anim frame where the rider starts to ease back to its own height
static constexpr T6Frames RIDE_EASE_FRAMES = {8};  // frames the ease back takes

// --- Move blend (blend.c). Lengths in frames.
static constexpr T6Frames BLEND_IN_FRAMES = {4};            // blend in to a move without active frames
static constexpr T6Frames BLEND_IN_FRAMES_MAX = {16};       // at most, and into a move without active frames while thrown
static constexpr T6Frames BLEND_OUT_WINDOW = {15};          // a move blends out when this many frames or fewer are left
static constexpr float BLEND_TURN_BACK = -0.5f;             // cos 120 degrees: a new root turned further than this blends from the old one turned half

// --- Look-at (look.c, look_at.c). Angles in radians (written in degrees), distances in mm.
static constexpr float LOOK_HIPS_LIMIT = RAD_FROM_DEG(30);  // the hips turn at most this far off the body yaw
static constexpr float LOOK_UPRIGHT_MIN = 0.707106769f;     // the spine's x axis must point at most 45 degrees off level to look
static constexpr float AIM_BEHIND = RAD_FROM_DEG(160);      // a target further round is behind
static constexpr float AIM_YAW_LIMIT = RAD_FROM_DEG(40);      // the neck and head turn at most this far
static constexpr float AIM_PITCH_DOWN = RAD_FROM_DEG(-32.5);  // lowest pitch of the neck and head
static constexpr float AIM_PITCH_UP = RAD_FROM_DEG(15);  // highest pitch of the neck and head
static constexpr float AIM_PITCH_HOLD = RAD_FROM_DEG(5);      // the pitch waits while the yaw moves more than this
static constexpr float AIM_RATE = 0.125f;                   // share of the way the neck and head turn a frame
static constexpr float AIM_RATE_SNAP = 1.0f;  // share used on a snap: the whole way at once
static constexpr float HIPS_RATE = 0.0625f;  // share of the way the hips turn a frame
static constexpr float HIPS_RATE_FREE = 0.5f;               // not locked on, in a move without active frames
static constexpr int32_t LOOK_WEIGHT_FULL = 6;              // frames the look takes to fade in; it fades out two a frame
static constexpr int32_t LOOK_WEIGHT_FADE = 2;
static constexpr T6Frames LOOK_END_WINDOW = {17};           // a move with active frames looks from this many frames before its end
static constexpr T6Frames LOOK_LOCK_WINDOW = {12};          // ... and locks on from this many frames before the fighter can act
static constexpr float LOOK_AHEAD = 1000.0f;                // not looking, the neck and head aim this far along their own axes
static constexpr float HIPS_AHEAD = 2000.0f;                // the hips aim this far ahead of the pelvis

// --- Cancels and the move change (decide.c, move_change.c)
static constexpr T6Frames LOOKAHEAD_FRAMES = {5};           // with a press, the scan looks past the move this many frames before its end window
static constexpr uint16_t CANCEL_LOCK_LIMIT = 25;           // no cancel scan while the cancel lock is above this
static constexpr uint16_t SWEEP_CANCEL_LOCK = 24;           // the cancel lock a sweep (MOTION_SWEEP) sets
static constexpr T6Ratio REVERSAL_DAMAGE_SHARE = {1, 2};    // of the attacker's damage, to a reversal
static constexpr int32_t REVERSAL_DAMAGE_ADD = 25;  // flat bonus damage of a reversal
static constexpr T6Frames REPEAT_WINDOW_EXTRA = {10};       // a repeated hit pushback counts within the new move's length and this
static constexpr T6Frames SETTLE_TURN_FRAMES = {16};        // MOTION_SETTLE_FIRST.. turn to the move yaw over this many frames
static constexpr T6Frames TURN_FRAMES_MAX = {16};           // a turn to the target with no active frame takes the old move's length, at most this

// --- Juggle launch (motion.c t6_juggle_launch). Speeds in mm a frame, frames.
static constexpr int32_t LAUNCH_AWAY_BASE = 17;             // the speed away from the attacker: base + damage + this per juggle hit
static constexpr int32_t LAUNCH_AWAY_PER_JUGGLE = 7;
static constexpr int32_t LAUNCH_AWAY_MAX = 100;  // the top of the away speed
static constexpr int32_t LAUNCH_LIFT_BASE = 40;             // the speed up: base + this per damage point, less this per juggle hit,
static constexpr int32_t LAUNCH_LIFT_PER_DAMAGE = 4;        // plus an eighth of the vertical motion and of the hit direction
static constexpr int32_t LAUNCH_LIFT_PER_JUGGLE = 7;
static constexpr int32_t LAUNCH_LIFT_MAX = 100;             // either way
static constexpr int32_t LAUNCH_CARRY_SHIFT = 3;  // carry is shifted this many bits: 3 is an eighth
static constexpr T6Frames LAUNCH_FIRST_EXTRA = {10};        // the first launch of a juggle flies this much longer
static constexpr T6Frames RELAUNCH_WINDOW = {9};            // a relaunch into the same anim within this of the start rewinds
static constexpr T6Frames RELAUNCH_REWIND = {10};           // to this many frames before the current one
static constexpr T6Frames LAUNCH_LANDING_SLACK = {4};       // a flight may last this much past the frames left in the move
static constexpr int16_t LAUNCH_CURVE_FRAMES = 8;           // the pushback curve of the generic launch
static constexpr int16_t LAUNCH_HOLD_COUNT = 255;           // a launched fighter holds the hold frame of the move this many times
static constexpr float NEAR_SIDE_DISTANCE = 512.0f;         // mm: the near side angles follow the target only past this distance

// --- Reactions (decide.c)
static constexpr float LOW_LAUNCH_HEIGHT = 736.0f;          // mm: a launched fighter whose base is this low or lower takes the low launch

#endif
