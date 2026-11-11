// Caller-owned memory for the core: input bytes and the arena the parsers copy into. The core opens no files and never allocates.
#ifndef T6_MEMORY_H
#define T6_MEMORY_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    const uint8_t *data;
    size_t size;
} T6Bytes;

enum { T6_ARENA_ALIGN = 16 };

typedef struct {
    uint8_t *base;
    size_t size, used;
} T6Arena;

static inline size_t t6_arena_round(size_t bytes) {
    return (bytes + T6_ARENA_ALIGN - 1) / T6_ARENA_ALIGN * T6_ARENA_ALIGN;  // round up to a 16-byte multiple
}

// The next `bytes` of the arena, or NULL when it is full. Every parser takes the same sizes its storage query adds up.
static inline void *t6_arena_take(T6Arena *arena, size_t bytes) {
    size_t rounded = t6_arena_round(bytes);
    if (rounded > arena->size - arena->used) return NULL;  // not enough room left
    void *at = arena->base + arena->used;
    arena->used += rounded;  // move the used mark past this block
    return at;
}

#endif
