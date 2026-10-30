// Tracking: the data of how a fighter turns toward or around its opponent. A character file holds a table of rows
// (T5FacingRow, one per profile the character's moves use; row 0 is hold) and each move names its row. The laws that read
// them are in facing.h. All values are in units (degrees, degrees a frame, frames, world units); the stock seeds are in
// tools/tracking.py.
#ifndef T5_TRACKING_H
#define T5_TRACKING_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/units.h"

// Which phase a fighter's profile is in. The stock game keeps the phase in its mode byte.
typedef enum : uint8_t {
    FACING_RUNNING,   // the row's law runs. Zero: a zeroed fighter holds its facing on the move yaw
    FACING_FREE,      // nothing runs, only the scripted turn of the move step
    FACING_REAIM,     // the startup is over; every few frames plan one scripted turn to the reference angle
    FACING_SCRIPTED,  // a spread turn (turn_speed over turn_frames) does the work
} T5FacingPhase;

// The profile of a fighter: a row of the table in data set `set` (the set of the move that started it), and its phase.
typedef struct {
    uint8_t row;          // the row in the character's table
    T5FacingPhase phase;
    uint8_t set;
} T5FacingState;

// The angle a law aims at.
typedef enum : uint8_t {
    TARGET_NONE,                      // no target: a move start keeps the facing; a turn law aims at the opponent
    TARGET_OPPONENT,                  // aims at the opponent
    TARGET_BEHIND_OPPONENT,           // the opposite way from the opponent
    TARGET_REFERENCE,                 // the opponent, or the opposite way when they stand behind
    TARGET_SIDE_OF_OPPONENT,          // the opponent, offset to the side the root offset leans to
    TARGET_STAGE_CENTRE,              // toward the middle of the stage
    TARGET_OPPONENT_START_SPOT,       // where the opponent stood when the move began
    TARGET_FACING,                    // move start only from here on
    TARGET_LOOK,                      // the way the fighter's look yaw points
    TARGET_WALL,                      // the angle of the wall
    TARGET_OPPONENT_OR_REFERENCE,     // the reference when the opponent is far behind, else the opponent
    TARGET_REFERENCE_LESS_REACTION,   // the reference angle, less the reaction turn
} T5Target;

typedef enum : uint8_t {
    LAW_HOLD,      // facing stays on the move yaw
    LAW_HOME,      // turn toward the target, capped by the rate and the total limit
    LAW_SETTLE,    // close a share of the gap to the target each frame
    LAW_SWEEP,     // swing the yaw to one side of the target over the move
    LAW_EASE_OUT,  // a share of the gap that grows over the move
    LAW_EASE_IN,   // a share of the gap that ramps up over the first frames
    LAW_LEAVE      // face the spot where the opponent stood, on the near side
} T5FacingLaw;

typedef enum : uint8_t {
    WHEN_NEVER,
    WHEN_ALWAYS,
    WHEN_UNLESS_ANIM_CHANGED,     // only when the move change did not switch anim
} T5When;

typedef enum : uint8_t {
    GATE_NONE,                    // no gate: the turn is never held back or spread
    GATE_SKIP_WHILE_BUSY,         // no turn while a timed turn runs or the opponent is busy
    GATE_SPREAD_WHILE_BUSY,       // opponent busy: spread the turn over the startup
    GATE_SPREAD_EARLY_WHILE_BUSY, // the same, only while frame_9c is at most `until`
} T5GateKind;

typedef struct {
    T5Frames until;        // clock limit for the early spread gate
    int32_t min_distance;  // the law waits while the fighters are closer (world units)
    T5GateKind kind;
} T5FacingGate;

typedef enum : uint8_t { HALVING_NONE, HALVING_ALL, HALVING_LATE } T5Halving;

// Degrees a frame. `late` replaces `normal` from frame_9c `late_from`; `air` while airborne.
typedef struct {
    T5Degrees normal, late, air;
    T5Frames late_from;      // the late rate applies from this point of the move
    T5Frames frames;         // settle and sweep close 1 / frames of the gap a frame; ease-in ramps up over them
    T5Halving halving;       // ALL: the picked rate halves. LATE: `late` is half of `normal`
    bool frames_by_distance; // settle: frames from the distance of the fighters
} T5FacingRate;

enum { SECTOR_FRONT, SECTOR_LEFT, SECTOR_BACK, SECTOR_RIGHT, SECTOR_COUNT };  // T5Fighter.side_band: where the opponent is

typedef struct {
    T5Degrees total;                // the most a move turns in all
    T5Degrees sweep[SECTOR_COUNT];  // sweep angle by sector of the opponent; the sign follows the root offset
} T5FacingLimit;

typedef struct {
    T5Frames grace;                    // frames past first_active that the row runs on
    T5When move_yaw_when, pivot_when;  // after the turn: move yaw follows the facing, the anchor re-pivots
    T5FacingPhase phase;               // the phase from first_active + grace on
} T5FacingEnd;

typedef struct {
    T5FacingLaw law;      // the law that turns the fighter each frame
    T5FacingPhase start;  // phase of a fighter that begins this row
    T5Target target;      // the angle the law aims at
    uint8_t stock_mode;   // the stock game's mode byte of this row, for the oracle and the diff harness only
    T5FacingGate gate;    // when the turn waits, skips or spreads
    T5FacingRate rate;    // how fast the turn goes
    T5FacingLimit limit;  // the most the move turns
    T5FacingEnd end;      // what happens when the turn ends
} T5FacingRow;

_Static_assert(sizeof(T5FacingRow) == 68, "T5FacingRow must match the TRKR record");

// What picks the far row at move start: the angle to the opponent above `far_angle`.
typedef enum : uint8_t { FAR_NEVER, FAR_BY_OPP_ANGLE, FAR_BY_ANGLE_84 } T5FarSource;

// The tracking a move starts: a row of the character's table, and a far row that applies instead when the angle that
// `far_source` names is above `far_angle`. Moves carry one (their default); cancel entries may carry another.
typedef struct {
    uint8_t row;              // the normal row
    uint8_t far_row;          // the row used when the far test is true
    T5FarSource far_source;
    uint8_t pad;
    uint16_t far_angle;       // far when the source angle is above this
    uint16_t pad2;
} T5MoveTracking;

_Static_assert(sizeof(T5MoveTracking) == 8, "T5MoveTracking must match the TOVR and TFIX records");

// T5Motbin.fixed_tracking: the tracking of the paths that the sim cannot read from a cancel entry.
enum {
    TRACKING_FIXED_CARRY,  // a carry cancel that the transition filter rewrites to the soft homing code
    TRACKING_FIXED_GUARD,  // the reaction to a guarded hit
    TRACKING_FIXED_COUNT,
};

// What a move change starts, set where the transition word is set. Zero: the move's own tracking.
typedef enum : uint8_t { PICK_MOVE, PICK_DATA } T5PickKind;

typedef struct {
    T5PickKind kind;          // PICK_MOVE: the move's own tracking; PICK_DATA: a picked row
    uint8_t set;              // PICK_DATA: the data set whose table the rows name (the set of the cancel's list)
    T5MoveTracking tracking;  // PICK_DATA
} T5TrackingPick;

#endif
