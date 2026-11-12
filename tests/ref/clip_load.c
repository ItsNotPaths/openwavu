// Loads a character's finger and face clips as the presenter does (modules/tk5/gamerender/hand_bank.c, face_bank.c) and
// prints the clip counts: hand poses, hand gestures, face poses, face clips.
// Usage: clip_load db root character
#include <stdio.h>
#include <stdlib.h>

#include "gamerender/face_bank.h"
#include "gamerender/hand_bank.h"
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
    T5HandBanks hands;
    T5FaceBanks faces;
    const char *failed = t5_load_hands(&hands, db, argv[3], read_file, argv[2]);
    if (!failed) failed = t5_load_faces(&faces, db, argv[3], read_file, argv[2]);
    if (failed) return fprintf(stderr, "%s\n", failed), 1;
    printf("%u %u %u %u\n", hands.poses.clip_count, hands.gestures.clip_count, faces.poses.clip_count, faces.clips.clip_count);
    return 0;
}
