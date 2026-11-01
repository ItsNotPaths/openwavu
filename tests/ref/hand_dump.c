// The finger frames the sim decodes from a .t5h file, little endian: for the pose bank, then the gesture bank, per
// clip u32 frames, then per frame the 45 values (axis x, axis y, angle per joint) in radians.
#include <stdio.h>

#include "visual/hand_bank.c"

static uint8_t file[1 << 21];

static void dump(T5HandBank bank) {
    for (uint16_t clip = 0; clip < bank.clip_count; clip++) {
        const uint8_t *bytes = clip_at(bank, clip);
        uint32_t frames = read16(bytes);
        fwrite(&frames, 4, 1, stdout);
        for (int32_t frame = 0; frame < (int32_t)frames; frame++) {
            RawFrame raw = clip_frame(bytes, frame);
            for (int value = 0; value < VALUES; value++) {
                float radians = (float)raw.value[value] * T5_ANGLE_TO_RAD;
                fwrite(&radians, 4, 1, stdout);
            }
        }
    }
}

int main(int argc, char **argv) {
    FILE *in = argc == 2 ? fopen(argv[1], "rb") : NULL;
    if (!in) return 1;
    size_t size = fread(file, 1, sizeof file, in);
    fclose(in);
    T5HandBanks banks;
    if (t5_hand_banks_parse(&banks, (T5Bytes){file, size}) != 0) return 1;
    dump(banks.poses);
    dump(banks.gestures);
    return 0;
}
