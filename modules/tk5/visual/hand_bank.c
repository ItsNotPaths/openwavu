#include "visual/hand_bank.h"

#include <string.h>

#include "sim/math.h"
#include "sim/quat.h"

enum {
    BANK_TYPE = 1,  // every bank starts with this type
    BANK_HEADER = 8,         // u16 type, clips, channels, b
    ROTATION_TYPE_FIRST = 5,  // rotation channel types are FIRST to LAST
    ROTATION_TYPE_LAST = 8,
    VALUES = 3 * FINGER_JOINTS,  // axis x, axis y, angle per joint
    FRAMES_PER_BLOCK = 16,  // frames per delta block
    FIELD_UNITS = 512,       // head: bits 0..8 the field length in u16, the rest the first bits of the stream
    HEAD_BITS = 7,  // bits of the head that start the stream
    WORD_BITS = 16,  // stream is read in 16 bit words
    CODE_BITS = 4,  // each mode code is 4 bits
    RUN_CODE = 8,            // a code from here on repeats its mode for the next nibble + 1 values
    LITERAL_MODE = 7,        // a 12 bit signed value replaces the value
    LITERAL_BITS = 12,  // literal width in bits
    LITERAL_SIGN = 2048,  // literals from here up are negative
    LITERAL_RANGE = 4096,  // subtracted from negative literals
    ROTATION_SCALE = 16,     // the deltas of a rotation channel are in steps of 16 angle units
};

static const char MAGIC[4] = {'T', '5', 'H', '1'};  // file starts with this tag
static const float BLEND_MIN = 1e-5f;  // weights below this skip the blend

// Delta modes 1..6: bits read, then added with the offset.
static const struct { uint8_t bits; int8_t offset; } DELTAS[LITERAL_MODE] = {
    {0, 0}, {6, -84}, {4, -20}, {2, -4}, {2, 1}, {4, 5}, {6, 21},
};

static uint16_t read16(const uint8_t *bytes) { return (uint16_t)(bytes[0] | bytes[1] << 8); }  // little endian: low byte first
static uint32_t read32(const uint8_t *bytes) { return (uint32_t)read16(bytes) | (uint32_t)read16(bytes + 2) << 16; }

static int bank_parse(T5HandBank *bank, T5Bytes bytes) {
    if (bytes.size < BANK_HEADER) return -1;  // too short for a header
    uint16_t channels = read16(bytes.data + 4);
    bank->bytes = bytes;
    bank->clip_count = read16(bytes.data + 2);
    size_t types = BANK_HEADER + 4 * (size_t)bank->clip_count;  // channel types follow the clip table
    if (read16(bytes.data) != BANK_TYPE || channels != FINGER_JOINTS || bank->clip_count == 0) return -1;  // bad type or shape
    if (bytes.size < types + 2 * (size_t)channels) return -1;  // too short for the channel table
    for (int channel = 0; channel < channels; channel++) {  // check every channel's type
        uint16_t type = read16(bytes.data + types + 2 * channel);
        if (type < ROTATION_TYPE_FIRST || type > ROTATION_TYPE_LAST) return -1;  // not a rotation type
    }
    return 0;
}

int t5_hand_banks_parse(T5HandBanks *banks, T5Bytes file) {
    if (file.size < 8 || memcmp(file.data, MAGIC, sizeof MAGIC) != 0) return -1;  // too short or wrong magic
    uint32_t pose_size = read32(file.data + 4);  // pose bank size, after the magic
    if (pose_size > file.size - 8) return -1;  // pose bank must fit in the file
    T5Bytes poses = {file.data + 8, pose_size};  // pose bank follows the 8 byte header
    T5Bytes gestures = {file.data + 8 + pose_size, file.size - 8 - pose_size};  // gesture bank is the rest of the file
    if (bank_parse(&banks->poses, poses) != 0) return -1;  // a bad pose bank fails the file
    return bank_parse(&banks->gestures, gestures);  // the gesture bank's result is the answer
}

// --- clips: u16 frames, s16 first[VALUES], s16 last[VALUES], u16 block[], blocks

static const uint8_t *clip_at(T5HandBank bank, uint16_t clip) {
    if (clip >= bank.clip_count) clip = 0;  // a clip past the end reads clip 0
    uint32_t offset = read32(bank.bytes.data + BANK_HEADER + 4 * clip);  // clip's offset from the table
    return bank.bytes.data + offset - offset % 2;  // round the offset down to even
}

uint16_t t5_hand_clip_frames(T5HandBank bank, uint16_t clip) { return read16(clip_at(bank, clip)); }  // frame count

// LSB-first bit reader over the u16 words of a field
typedef struct {
    const uint8_t *next;  // next unread word
    uint32_t bits;  // bits read but not used yet
    int32_t count;  // how many bits are in bits
} Bits;

static int32_t bits_take(Bits *reader, int32_t width) {  // take width bits from the stream
    while (reader->count < width) {  // load words until there are enough bits
        reader->bits |= (uint32_t)read16(reader->next) << reader->count;  // add the next word above the held bits
        reader->next += 2;
        reader->count += WORD_BITS;
    }
    int32_t value = (int32_t)(reader->bits & ((1u << width) - 1));  // low width bits are the value
    reader->bits >>= width;  // drop the taken bits
    reader->count -= width;
    return value;
}

// The value after `steps` steps from the first frame. First order: each step adds a delta or sets a literal.
static int16_t field_value(const uint8_t *field, int16_t first, int32_t steps) {
    uint16_t head = read16(field);  // head word: field length and first stream bits
    Bits reader = {field + 2, head / FIELD_UNITS, HEAD_BITS};  // stream starts after the head
    int32_t value = first, mode = 0, run = 0;  // last mode, and steps left in a run
    for (int32_t step = 0; step < steps; step++) {  // apply each step in turn
        if (run > 0) {  // in a run: reuse the mode
            run--;
        } else {
            mode = bits_take(&reader, CODE_BITS);  // read a new mode code
            if (mode >= RUN_CODE) {  // a run code: repeat the mode
                run = bits_take(&reader, CODE_BITS) + 1;  // run length: next 4 bits, plus one
                mode -= RUN_CODE;  // strip the run flag from the mode
            }
        }
        if (mode == LITERAL_MODE) {  // mode 7: a literal replaces the value
            int32_t literal = bits_take(&reader, LITERAL_BITS);  // read the 12 bit literal
            if (literal >= LITERAL_SIGN) literal -= LITERAL_RANGE;  // large literals are negative
            value = literal * ROTATION_SCALE;  // set the value, in angle units
        } else if (mode != 0) {  // modes 1 to 6: add a delta
            value += (bits_take(&reader, DELTAS[mode].bits) + DELTAS[mode].offset) * ROTATION_SCALE;  // add the delta
        }
        value = (int16_t)value;  // wrap to 16 bits
    }
    return (int16_t)value;
}

typedef struct { int16_t value[VALUES]; } RawFrame;  // the raw numbers of one frame

// Frame 0 and earlier read `first`, the last frame and later `last`; frame n reads step (n-1) % 16 + 1 of block (n-1) / 16.
// Every block starts from `first`.
static RawFrame clip_frame(const uint8_t *clip, int32_t frame) {
    int32_t frames = read16(clip);
    const uint8_t *first = clip + 2, *last = first + 2 * VALUES;  // first and last values follow the frame count
    const uint8_t *source = first;
    if (frame + 1 >= frames) source = last;  // last frame and later use the last values
    RawFrame raw;
    for (int value = 0; value < VALUES; value++) raw.value[value] = (int16_t)read16(source + 2 * value);  // start values
    if (frame <= 0 || frame + 1 >= frames) return raw;  // first and last frames need no steps
    const uint8_t *blocks = last + 2 * VALUES;  // block offsets follow the last values
    const uint8_t *field = clip + 2 * read16(blocks + 2 * ((frame - 1) / FRAMES_PER_BLOCK));  // block of this frame
    int32_t steps = (frame - 1) % FRAMES_PER_BLOCK + 1;  // steps into that block
    for (int value = 0; value < VALUES; value++) {  // decode each value's field in turn
        raw.value[value] = field_value(field, raw.value[value], steps);  // run the steps on this value
        field += 2 * (read16(field) % FIELD_UNITS);  // move to the next value's field
    }
    return raw;
}

// axis = row 2 of RotY(axis y) then RotX(axis x) on the matrix stack, turned by the angle (data.md 6.2)
static T5Vec4 joint_turn(int16_t axis_x, int16_t axis_y, int16_t angle) {
    T5Mat4 matrix;
    t5_mat_identity(&matrix);  // start from identity
    t5_mat_rotate_y(&matrix, axis_y);  // first turn: around y
    t5_mat_rotate_x(&matrix, axis_x);  // then turn: around x
    T5Vec4 axis = {{matrix.m[2][0], matrix.m[2][1], matrix.m[2][2], matrix.m[2][3]}}, turn;
    t5_quat_axis_angle(&turn, (float)angle * T5_ANGLE_TO_RAD, &axis);  // angle units to radians
    return turn;
}

static T5FingerPose frame_pose(const uint8_t *clip, int32_t frame) {
    RawFrame raw = clip_frame(clip, frame);  // decode the frame's raw numbers
    T5FingerPose pose;
    for (int joint = 0; joint < FINGER_JOINTS; joint++)  // turn each joint's 3 numbers into a turn
        pose.joint[joint] = joint_turn(raw.value[3 * joint], raw.value[3 * joint + 1], raw.value[3 * joint + 2]);
    return pose;
}

T5FingerPose t5_hand_clip_sample(T5HandBank bank, uint16_t clip, float time) {
    const uint8_t *bytes = clip_at(bank, clip);  // the clip's bytes
    float whole;
    float weight = t5_modf(time, &whole);  // split time: fraction is the blend weight
    int32_t frame = t5_fctiwz(whole);  // whole part is the frame
    T5FingerPose pose = frame_pose(bytes, frame);  // pose at this frame
    if (!(weight >= BLEND_MIN)) return pose;  // no real blend: tiny or NaN weight
    T5FingerPose next = frame_pose(bytes, frame + 1);  // next frame, to blend toward
    for (int joint = 0; joint < FINGER_JOINTS; joint++)  // blend each joint toward the next frame
        t5_quat_blend(&pose.joint[joint], weight, &pose.joint[joint], &next.joint[joint]);
    return pose;
}
