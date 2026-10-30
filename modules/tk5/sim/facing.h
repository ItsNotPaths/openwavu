// Facing: how a fighter turns toward or around its opponent (code-map section 15, step 11) and how a new move re-aligns
// it. The profiles are data (tracking.h): the sim runs the row that the move, or `PROP_TRACKING`, names.
#ifndef T5_FACING_H
#define T5_FACING_H

#include <stdbool.h>
#include <stdint.h>

#include "sim/fighter.h"
#include "sim/tracking.h"
#include "sim/units.h"
#include "sim/world.h"

// The row of a state. A row past the table of its data set is the zero row: hold.
const T5FacingRow *t5_facing_row(const T5World *w, T5FacingState facing);

// A move change, `PROP_TRACKING` and the reset start a row of the table of data set `set`.
T5FacingState t5_facing_begin(const T5World *w, uint8_t set, uint8_t row);

// The tracking a move change starts: the pick of the fighter if it has one, else the tracking of the move, with the far
// row taken when the angle it names is above far_angle.
T5FacingState t5_facing_for_move(const T5World *w, const T5Fighter *f, T5Ref move);

// The pick of a cancel entry of the list in data set `owner_set`; its rows are rows of that set's table. `raw` is the extradata the transition filter got and `filtered` what it returned: a
// carry cancel that the filter rewrote to the soft homing code takes the fixed carry tracking.
T5TrackingPick t5_pick_of_cancel(const T5World *w, uint8_t owner_set, const T5Cancel *cancel, uint16_t raw, uint16_t filtered);
T5TrackingPick t5_pick_guard(const T5World *w, uint8_t owner_set);

void t5_facing_step(T5World *w, T5Fighter *f);  // step 11 of the movement step

// Move start: the transition bits pick how the fighter re-aligns (code-map section 6, step 15).
typedef enum : uint8_t {  // TO rows set the facing too; YAW_TO rows only aim the move yaw
    START_KEEP, START_KEEP_ROOT, START_YAW_TO_FACING, START_YAW_TO_FACING_ROOT,
    START_TO_OPPONENT, START_YAW_TO_OPPONENT, START_YAW_TO_OPPONENT_OR_REFERENCE,
    START_TO_REFERENCE, START_YAW_TO_REFERENCE, START_TO_LOOK, START_YAW_TO_LOOK,
    START_THROW_PARTNER, START_TO_WALL, START_HALF_TURN, START_YAW_TO_REFERENCE_LESS_REACTION, START_UNUSED_15,
    START_ALIGNMENT_COUNT,
} T5StartAlignment;

typedef struct {
    T5Target target;  // angle the move turns to; TARGET_NONE leaves the facing alone
    bool turns_with_anim;  // the facing first takes the yaw change of the new anim
    bool sets_facing;      // the facing follows the move yaw
} T5StartRow;

const T5StartRow *t5_start_row(T5StartAlignment align);
// Aim the move yaw (and the facing) per the row. `reaction_yaw`: the old move asks for the reaction angle to be taken off.
void t5_facing_start(T5Fighter *f, const T5StartRow *row, bool reaction_yaw);

#endif
