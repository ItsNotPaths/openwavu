// Loads a character's anim banks from a db (modules/tk5/load.c) and prints, per anim of its own bank, frames and the
// first key of the last frame, then whether anims 0 and 2, and 0 and 3, are one record; or the load error.
// Usage: load_anims db root character
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

int main(int argc, char **argv) {
    sqlite3 *db;
    if (argc != 4 || sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return 2;
    size_t bytes;
    const char *failed = t5_load_anims_storage(db, argv[3], &bytes);
    T5Arena arena = {malloc(bytes), bytes, 0};
    T5FighterFiles files = {};
    if (!failed) failed = t5_load_anims(&files, db, argv[3], read_file, argv[2], &arena);
    if (failed) return printf("%s\n", failed), 1;
    const T5AnimBank *bank = &files.character;
    for (uint32_t index = 0; index < bank->anim_count; index++) {
        const T5Anim *anim = &bank->anims[index];
        printf("%u:%g ", anim->frame_count, anim->keys ? (double)anim->keys[anim->frame_count - 1][0][0] : 0.0);
    }
    if (bank->anim_count >= 4)
        printf("same %d %d", t5_anim_same(&bank->anims[0], &bank->anims[2]), t5_anim_same(&bank->anims[0], &bank->anims[3]));
    return 0;
}
