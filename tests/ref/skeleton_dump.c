// The skeletons the sim builds from a .t5b file, little endian: scale; per A slot parent, translation, euler;
// per B slot parent, translation.
#include <stdio.h>

#include "sim/skel.h"

static uint8_t file[1 << 16];
static T5Skeleton skeleton;
static T5Rig rig;

int main(int argc, char **argv) {
    FILE *in = argc == 2 ? fopen(argv[1], "rb") : NULL;
    if (!in) return 1;
    size_t size = fread(file, 1, sizeof file, in);
    fclose(in);
    if (t5_skeleton_parse(&skeleton, &rig, (T5Bytes){file, size}) != 0) return 1;
    fwrite(&skeleton.scale, 4, 1, stdout);
    for (int bone = 0; bone < T5_BONES_A; bone++) {
        fwrite(&skeleton.parent_a[bone], 1, 1, stdout);
        fwrite(skeleton.translation[bone], 4, 3, stdout);
        fwrite(skeleton.euler[bone], 4, 3, stdout);
    }
    for (int bone = 0; bone < T5_BONES_B; bone++) {
        fwrite(&skeleton.parent_b[bone], 1, 1, stdout);
        fwrite(rig.bones_b[bone].local.m[3], 4, 3, stdout);
    }
    return 0;
}
