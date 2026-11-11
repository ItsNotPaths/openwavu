// The transition word of a move change (T6Fighter.transition; the low 14 bits of a cancel's extradata): a class, the
// start alignment of the new move (T6StartAlignment, facing.h) and a motion code (the stock tracking of the change).
// The extradata bits above the word are the pending flags of the cancel.
#ifndef T6_TRANSITION_H
#define T6_TRANSITION_H

#include <stdint.h>

#include "sim/facing.h"

enum { TRANSITION_ALIGN_SHIFT = 6, TRANSITION_CLASS_SHIFT = 10, TRANSITION_BITS = 14 };
enum { TRANSITION_CODE_COUNT = 64, TRANSITION_ALIGN_COUNT = 16, TRANSITION_CLASS_COUNT = 16 };

// How the move change takes the frame and the anim of the new move.
enum T6TransitionClass : uint8_t {
    TRANSITION_START,    // frame 1
    TRANSITION_CARRY,    // the next frame of the old move (frame 1 when the new move's active frames are past)
    TRANSITION_PARAM,    // the frame start_param names
    TRANSITION_END,      // the last frame, playing backward
    TRANSITION_BACK,     // the frame before, playing backward
    TRANSITION_NEXT,     // the next frame
    TRANSITION_THROWER,  // frame 1; the thrower's side of a throw, linked to the opponent
    TRANSITION_THROWN,   // frame 1; the victim of a throw
    TRANSITION_JUGGLE,   // the frame the reaction asks for; the launch starts
};

// Motion codes (transition bits 0..5) that the sim acts on. Code 0 and the codes from MOTION_CODE_END on leave the tracking as it is.
enum : uint8_t {
    MOTION_NONE = 0,
    MOTION_HOMING_FIRST = 2,           // 2..4 home on the opponent; 2 is also the carry rewrite of the transition filter
    MOTION_HOMING_LAST = 4,
    MOTION_HOMING_REFERENCE = 11,      // homes on the reference direction
    MOTION_APPROACH = 14,              // turn to the target until the first active frame and slide in
    MOTION_SWEEP = 16,                 // locks the cancels for a while
    MOTION_SWEEP_LAST = 17,            // clears the scripted turn, as the sweep does
    MOTION_TURN_TO_TARGET = 19,        // turn to the target until the first active frame; from behind, half a turn more
    MOTION_TURN_TO_TARGET_AHEAD = 20,  // the same, from any side
    MOTION_SETTLE_FIRST = 21,          // 21..23: turn to the move yaw (not in a throw); the pushback stops
    MOTION_THROWN = 23,                // the victim of a throw; settles, but no turn while the throw lasts
    MOTION_GUARD = 24,                 // 24..32: the pushbacks of a hit (decide.c reactions)
    MOTION_JUGGLE = 25,                // the launch: sets the juggle weight and clears the turn
    MOTION_HIT_DOWN = 26,              // knockdown and wall hits; juggle weight goes to 0
    MOTION_COUNTER = 27,
    MOTION_HIT_FRONT = 28,
    MOTION_HIT_BACK = 29,              // a back hit with no set yaw turns them 10 degrees away from the reference side
    MOTION_HIT_LEFT = 30,
    MOTION_HIT_RIGHT = 31,
    MOTION_HIT_TO_TARGET = 32,         // the front pushback, aimed from the target angle
    MOTION_CHASE_FIRST = 45,           // 45..54 home on the opponent at set rates, 55 faces the stage centre; all clear the turn
    MOTION_CODE_END = 56,
};

[[nodiscard]] static inline uint16_t t6_transition(enum T6TransitionClass class_, T6StartAlignment align, uint8_t code) {
    return (uint16_t)((class_ << TRANSITION_CLASS_SHIFT) | (align << TRANSITION_ALIGN_SHIFT) | code);
}

// The alignment and code of a word under another class (the bits above the class are dropped).
[[nodiscard]] static inline uint16_t t6_transition_reclass(uint16_t word, enum T6TransitionClass class_) {
    return (uint16_t)((word % (1 << TRANSITION_CLASS_SHIFT)) | (class_ << TRANSITION_CLASS_SHIFT));
}

[[nodiscard]] static inline uint16_t t6_transition_recode(uint16_t word, uint8_t code) {  // same class and align, new code
    return (uint16_t)(word - word % TRANSITION_CODE_COUNT + code);
}

[[nodiscard]] static inline enum T6TransitionClass t6_transition_class(uint16_t word) {
    return (enum T6TransitionClass)((word >> TRANSITION_CLASS_SHIFT) % TRANSITION_CLASS_COUNT);
}

[[nodiscard]] static inline uint8_t t6_transition_code(uint16_t word) { return (uint8_t)(word % TRANSITION_CODE_COUNT); }

[[nodiscard]] static inline T6StartAlignment t6_transition_align(uint16_t word) {
    return (T6StartAlignment)((word >> TRANSITION_ALIGN_SHIFT) % TRANSITION_ALIGN_COUNT);
}

[[nodiscard]] static inline bool t6_motion_homes(uint8_t code) {
    return (code >= MOTION_HOMING_FIRST && code <= MOTION_HOMING_LAST) || code == MOTION_HOMING_REFERENCE;
}

// --- a cancel's extradata: the transition word, then the pending flags (T6PendingFlags)

enum : uint32_t {
    EXTRADATA_NO_BLEND_OUT = 1 << 14,  // no blend out into the next move
    EXTRADATA_TURN = 1 << 15,          // the fighter turns around: half a turn more
    EXTRADATA_NO_ROOT_FIX = 1 << 16,   // the root is not re-placed for the new move
    EXTRADATA_ROOT_HIPS = 1 << 17,     // the root fix places the fighter by the hips and base position
};

[[nodiscard]] static inline uint16_t t6_extradata_transition(uint32_t extradata) { return (uint16_t)(extradata % (1 << TRANSITION_BITS)); }

[[nodiscard]] static inline bool t6_extradata_turns(uint32_t extradata) { return (extradata & EXTRADATA_TURN) != 0; }

[[nodiscard]] static inline T6PendingFlags t6_pending_flags_of(uint32_t extradata) {
    return (T6PendingFlags){
        .no_blend_out = (extradata & EXTRADATA_NO_BLEND_OUT) != 0,
        .turn = (extradata & EXTRADATA_TURN) != 0,
        .no_root_fix = (extradata & EXTRADATA_NO_ROOT_FIX) != 0,
        .root_hips = (extradata & EXTRADATA_ROOT_HIPS) != 0,
    };
}

// --- the start frame word (T6Fighter.start_param, `PROP_START_FRAME` and the eleven after it, class TRANSITION_PARAM): an offset from a frame
// counter, or a frame

enum : uint16_t {
    START_PARAM_AFTER_FRAME = 1 << 12,    // frame + offset
    START_PARAM_BEFORE_FRAME = 1 << 13,   // frame - offset
    START_PARAM_AFTER_FRAME2 = 1 << 14,   // frame2 + offset
    START_PARAM_BEFORE_FRAME2 = 1 << 15,  // frame2 - offset
};
enum { START_PARAM_OFFSET_RANGE = 256 };  // the offset is the low 8 bits of the word

#endif
