// The state word of a fighter (copied from T6Move.vuln at a move change) and its class. The stance code
// (stance.c) writes them from the held direction. Bits that no reader names have a number; they are part of the stance words.
#ifndef T6_STATE_H
#define T6_STATE_H

#include <stdbool.h>
#include <stdint.h>

// Bits 0..2 are the hurt mask: an attack of class 2^i hits a state with bit i. Bits 3 and 4 are the guard bits.
enum : uint32_t {
    STATE_HURT_1 = 1 << 0,       // crouching hurt height
    STATE_HURT_2 = 1 << 1,       // also: standing (the reaction pick)
    STATE_HURT_4 = 1 << 2,       // also: against a wall (the reaction pick); a hit-down move that ends in it touches down
    STATE_GUARD_CROUCH = 1 << 3, // set by the crouch stances (guard.c)
    STATE_GUARD_STAND = 1 << 4,  // set by the stand stances (guard.c)
    STATE_THROW_CROUCHING = 1 << 5,  // a crouching throw takes them (when no standing one does)
    STATE_THROW_STANDING = 1 << 6,   // a standing throw takes them
    STATE_THROW_LYING = 1 << 7,      // a throw of a lying fighter takes them: face up, or face down when downed
    STATE_GUARD_LOCKED = 1 << 8, // the move change clears the guard bits, unless neutral_guard
    STATE_DOWNED = 1 << 9,       // lying on the floor; a lying throw sees them face down
    STATE_LAUNCHED = 1 << 10,    // a launch or hit-down reaction (classes 14, 15): off the ground
};

enum { STATE_CLASS_SHIFT = 11, STATE_CLASS_COUNT = 32 };  // bits 11..15 are the class

// What the reaction pick reads from the hurt bits.
enum : uint32_t {
    STATE_STANDING = STATE_HURT_2,
    STATE_AT_WALL = STATE_HURT_4,
};

enum : uint32_t {
    STATE_GUARD_BITS = STATE_GUARD_CROUCH | STATE_GUARD_STAND,  // the part of the state that is the guard mask (guard.c)
    STATE_HURT_BITS = STATE_HURT_1 | STATE_HURT_2 | STATE_HURT_4,  // the heights a fighter can be hit at; the low bits of a hit level
};

// The class of a state (state >> STATE_CLASS_SHIFT). Classes the stance code sets are named by the stance. The others are
// named by what the move step does with them.
enum : uint8_t {
    CLASS_STANCE_FIRST = 1, CLASS_STANCE_LAST = 11,         // the stances on the ground: stand, crouch, no guard, alternate
    CLASS_STAND = 2, CLASS_NO_GUARD = 5, CLASS_CROUCH = 6,
    CLASS_ALTERNATE_STAND = 8, CLASS_ALTERNATE_CROUCH = 9, CLASS_ALTERNATE_CROUCH_LOW = 10, CLASS_ALTERNATE_DOWN = 11,
    CLASS_HIT_DOWN_FIRST = 14, CLASS_HIT_DOWN_LAST = 15,    // a hit-down move that ends touches down; may carry STATE_HURT_4
    CLASS_FALLEN_FIRST = 18, CLASS_FALLEN_LAST = 19,         // the same end
    CLASS_JUMP_A = 23, CLASS_JUMP_B = 24,                    // moves in the air; every jump move of a character is class 23
    CLASS_AIR_GUARD_FIRST = 25, CLASS_AIR_GUARD_LAST = 26,   // the classes that guard in the air
    CLASS_JUMP_LAST = 28,                                    // CLASS_JUMP_A..this: the jump and air guard classes
    CLASS_UNHITTABLE_FIRST = 30, CLASS_UNHITTABLE_LAST = 31, // TK6 classes 0x15, 0x16: the hit test never hits them
};

// true if any of the bits is set
[[nodiscard]] static inline bool t6_state_has(uint32_t state, uint32_t bits) { return (state & bits) != 0; }
// true if first <= class_ <= last
[[nodiscard]] static inline bool t6_class_between(uint8_t class_, uint8_t first, uint8_t last) { return class_ >= first && class_ <= last; }
[[nodiscard]] static inline uint8_t t6_state_class(uint32_t state) { return (uint8_t)(state >> STATE_CLASS_SHIFT); }
// the state word for a class and bits
[[nodiscard]] static inline uint32_t t6_state_of(uint8_t class_, uint32_t bits) { return ((uint32_t)class_ << STATE_CLASS_SHIFT) | bits; }

#endif
