// Poses frame 0 of an anim through the TK6 sim's pose code and prints the bones' world positions in mm, one per line:
// slot x y z. The root sits on the anim's root channels, as the root motion places it.
// Usage: tk6_pose_check db character anim_file
#include <stdio.h>
#include <stdlib.h>

#include "load.h"
#include "sim/anim.h"
#include "sim/skel.h"
#include "sqlite3.h"

static T6Bytes read_file(const char *path) {
    FILE *in = fopen(path, "rb");
    if (!in) return (T6Bytes){};
    fseek(in, 0, SEEK_END);
    size_t size = (size_t)ftell(in);
    uint8_t *data = malloc(size);
    rewind(in);
    size = fread(data, 1, size, in);
    fclose(in);
    return (T6Bytes){data, size};
}

int main(int count, char **arguments) {
    if (count != 4) return 2;
    sqlite3 *db;
    if (sqlite3_open_v2(arguments[1], &db, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) return 3;
    static T6Skeleton skeleton;
    if (t6_load_skeleton(&skeleton, db, arguments[2])) return 4;
    T6Anim anim;
    if (t6_anim_parse(&anim, read_file(arguments[3])) != 0) return 5;

    static T6Rig rig;
    t6_rig_load(&rig, &skeleton);
    T6Vec4 pose[T6_CHANNELS];
    t6_anim_sample(&anim, 0.0f, pose, false);
    t6_skel_pose(rig.bones_a, &skeleton, pose);
    for (int axis = 0; axis < 3; axis++) rig.root.local.m[3][axis] = pose[CHANNEL_ROOT].v[axis] + pose[CHANNEL_HIP].v[axis];
    rig.root.world = rig.root.local;
    t6_skel_world_a(&rig, &skeleton);
    for (int slot = 0; slot < T6_POSE_BONES; slot++) {
        const float *row = rig.bones_a[slot].world.m[3];
        printf("%d %.1f %.1f %.1f\n", slot, row[0], row[1], row[2]);
    }
    return 0;
}
