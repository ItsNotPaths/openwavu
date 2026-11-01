// The finger clips of a character loaded from a db (modules/tk5/load.c), little endian: for the pose bank, then the
// gesture bank, per clip u32 frames, then per frame the 45 keys (axis x, axis y, angle per joint) in radians.
// Usage: hand_dump db root character
#include <stdio.h>
#include <stdlib.h>

#include "load.h"
#include "sqlite3.h"

static T5Bytes read_file(void *root, const char *path) {
    char full[1024];
    snprintf(full, sizeof full, "%s/%s", (const char *)root, path);
    FILE *in = fopen(full, "rb");
    if (!in) return (T5Bytes){};
    fseek(in, 0, SEEK_END);
    size_t size = (size_t)ftell(in);
    uint8_t *data = malloc(size);
    rewind(in);
    size = fread(data, 1, size, in);
    fclose(in);
    return (T5Bytes){data, size};
}

static void dump(T5HandBank bank) {
    for (uint32_t clip = 0; clip < bank.clip_count; clip++) {
        uint32_t frames = bank.clips[clip].frame_count;
        fwrite(&frames, 4, 1, stdout);
        fwrite(bank.clips[clip].keys, sizeof(T5HandKeys), frames, stdout);
    }
}

int main(int argc, char **argv) {
    sqlite3 *db;
    if (argc != 4 || sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return 2;
    size_t bytes;
    const char *failed = t5_load_hands_storage(db, argv[3], &bytes);
    T5Arena arena = {malloc(bytes), bytes, 0};
    T5HandBanks banks = {};
    if (!failed) failed = t5_load_hands(&banks, db, argv[3], read_file, argv[2], &arena);
    if (failed) return fprintf(stderr, "%s\n", failed), 1;
    dump(banks.poses);
    dump(banks.gestures);
    return 0;
}
