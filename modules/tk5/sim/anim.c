#include "sim/anim.h"

#include <math.h>
#include <string.h>

#include "sim/math.h"
#include "sim/quat.h"


// --- little endian reads of the file bytes (the game swaps in place, then reads big endian)

static uint16_t read16(const uint8_t *bytes) { return (uint16_t)(bytes[0] | bytes[1] << 8); }
static uint32_t read32(const uint8_t *bytes) { return (uint32_t)read16(bytes) | (uint32_t)read16(bytes + 2) << 16; }
static float read_float(const uint8_t *bytes) { uint32_t word = read32(bytes); float value; memcpy(&value, &word, 4); return value; }

// --- bank

enum { BANK_BODY = 100, ANIM_POSITION_SCALE = 6, ANIM_BASE = 18, ANIM_BLOCKS = 174 };  // the bank type; offsets in an anim record
enum { ROTATION_SHIFT_RANGE = 128 };  // the low 7 bits of byte 2; bit 7 is the ready flag

static void parse_anim(T5Anim *anim, const uint8_t *record) {
    anim->ready = true;  // the bank swap sets the ready flag when it swaps the anim
    anim->frame_count = read16(record);  // how many frames the clip has
    anim->rotation_shift = record[2] % ROTATION_SHIFT_RANGE;  // bit shift that scales decoded rotation keys back up
    anim->position_shift = (int8_t)record[3];  // bit shift that scales decoded position keys back up
    // size of one position key step, per position channel
    for (int axis = 0; axis < 3; axis++) anim->position_scale[axis] = read_float(record + ANIM_POSITION_SCALE + sizeof(float) * axis);
    const uint8_t *base_bytes = record + ANIM_BASE;  // frame 0 pose: one entry per channel, packed back to back
    for (int32_t channel = 0; channel < T5_CHANNELS; channel++) {  // walk every channel of the pose
        if (t5_channel_is_rotation(channel)) {  // rotation channel: three 16 bit angles
            for (int axis = 0; axis < 3; axis++) anim->base[channel].rotation[axis] = (int16_t)read16(base_bytes + 2 * axis);
            base_bytes += 6;  // skip the three angles
        } else {  // position channel: three floats
            for (int axis = 0; axis < 3; axis++) anim->base[channel].position[axis] = read_float(base_bytes + 4 * axis);
            base_bytes += 12;  // skip the three floats
        }
    }
    anim->blocks = record + ANIM_BLOCKS;  // the packed key data for frames after the first
}

// header: u16 type, u16 anim_count, u16 bone_count, u16 bone_type[], pad to 4, u32 anim_offset[]
enum { BANK_HEADER_BYTES = 6, BONE_TYPE_BYTES = 2, OFFSET_BYTES = 4, OFFSET_ALIGN = 2 };

static bool bank_offsets(T5Bytes file, uint16_t *count, const uint8_t **offsets) {
    // too small, or not a body animation bank
    if (file.size <= BANK_HEADER_BYTES || read16(file.data) != BANK_BODY) return false;
    uint16_t bones = read16(file.data + 4);
    size_t table = BANK_HEADER_BYTES + BONE_TYPE_BYTES * bones;  // the offset table starts after the bone type list
    if (bones % 2 == 0) table += OFFSET_ALIGN;  // pad the table start to a 4 byte boundary
    *count = read16(file.data + 2);
    *offsets = file.data + table;
    return table + (size_t)*count * OFFSET_BYTES <= file.size;  // the whole offset table must fit in the file
}

int32_t t5_anim_bank_count(T5Bytes file) {
    uint16_t count;
    const uint8_t *offsets;
    if (!bank_offsets(file, &count, &offsets)) return -1;
    return count;
}

int t5_anim_bank_parse(T5AnimBank *bank, T5Bytes file, T5Arena *arena) {
    memset(bank, 0, sizeof *bank);
    uint16_t count;
    const uint8_t *offsets;
    if (!bank_offsets(file, &count, &offsets)) return -1;
    T5Anim *anims = t5_arena_take(arena, t5_anim_bank_bytes(count));  // room for every anim plus one empty anim
    if (!anims) return -1;
    memset(anims, 0, t5_anim_bank_bytes(count));  // empty anims are not ready, so they decode to zeros
    for (uint32_t anim_index = 0; anim_index < count; anim_index++) {  // parse each anim record in the bank
        size_t offset = read32(offsets + OFFSET_BYTES * anim_index);
        offset -= offset % 2;  // bit 0 is a flag
        if (offset > file.size || file.size - offset < ANIM_BLOCKS) return -1;  // record must fit in the file
        parse_anim(&anims[anim_index], file.data + offset);
    }
    *bank = (T5AnimBank){file.data, count, anims};  // bank keeps pointers into the file bytes
    return 0;
}

// --- key decoder

// PPC slw / sraw: the shift count is 6 bits, counts of 32..63 shift everything out
enum { SHIFT_RANGE = 64 };
static uint32_t slw(int32_t x, uint32_t shift) {
    shift %= SHIFT_RANGE;
    if (shift >= 32) return 0;  // shift too big: everything falls out
    return (uint32_t)x << shift;
}
static int16_t sraw16(int16_t x, uint32_t shift) {
    shift %= SHIFT_RANGE;
    if (shift > 15 && x < 0) return -1;  // shifted out: negative becomes all ones
    if (shift > 15) return 0;  // shifted out: positive becomes zero
    if (x < 0) return (int16_t)~(~x >> shift);  // negative keeps its sign (arithmetic shift)
    return (int16_t)(x >> shift);
}

// MSB-first bit reader (the game's kkTypeToBits state). At most 23 bits are buffered.
typedef struct {
    const uint8_t *next;
    uint32_t buffer;
    int32_t buffered;
} Bits;

static uint32_t bits_read(Bits *bits, int32_t count) {  // take the next count bits off the stream
    while (bits->buffered < count) {  // not enough bits buffered: pull in whole bytes
        bits->buffer = bits->buffer << 8 | *bits->next++;
        bits->buffered += 8;
    }
    bits->buffered -= count;  // these bits leave the buffer
    uint32_t value = bits->buffer >> bits->buffered;
    bits->buffer &= ~(UINT32_MAX << bits->buffered);  // drop the bits just taken, keep the rest
    return value;
}

enum { CODE_RUN = 14, CODE_HOLD = 15 };

// The delta of a key code: {bits read, offset added}. Codes come in pairs, a positive band and its negative mirror.
static const T5KeyMode MODES[14] = {
    {0, 0},       // 0: no change
    {2, 1},       // 1: +1 .. +4
    {2, -4},      // 2: -4 .. -1
    {4, 5},       // 3: +5 .. +20
    {4, -20},     // 4: -20 .. -5
    {6, 21},      // 5: +21 .. +84
    {6, -84},     // 6: -84 .. -21
    {8, 85},      // 7: +85 .. +340
    {8, -340},    // 8: -340 .. -85
    {10, 341},    // 9: +341 .. +1364
    {10, -1364},  // 10: -1364 .. -341
    {12, 1365},   // 11: +1365 .. +5460
    {12, -5460},  // 12: -5460 .. -1365
    {16, 0},      // 13: any int16
};

static void set_mode(T5KeyMode *mode, uint32_t code) {
    if (code == CODE_HOLD) *mode = (T5KeyMode){T5_KEY_HOLD, 0};  // hold: the value stops changing for the rest of the block
    else *mode = MODES[code];  // pick the delta size for this code
}

static int32_t read_delta(Bits *bits, const T5KeyMode *mode) {
    if (mode->bits == 0) return 0;  // no change
    return (int16_t)bits_read(bits, mode->bits) + mode->offset;  // read the delta bits, then add the band start
}

enum { HEAD_CODE_HIGH = 4, HEAD_DATA_BITS = 6, RUN_LOW_BITS = 2, CODE_BITS = 4 };

// One axis of one channel. Head: b0 = size << 2 | code bits 9..8, b1 = code bits 7..6 | 6 data bits.
// The first delta moves the value; each later step adds a second-order delta. Runs count
// in 16 bits, so a run of 0 (count 65535) never ends inside a block.
static int16_t decode_field(T5KeyMode *mode, const uint8_t *field, int16_t value, int32_t steps) {
    uint32_t code = (field[0] % HEAD_CODE_HIGH) << (8 - HEAD_DATA_BITS) | field[1] >> HEAD_DATA_BITS;  // code from the head bits
    uint32_t data = field[1] % (1u << HEAD_DATA_BITS);  // the first data bits that share the head byte
    Bits bits = {field + 2, data, HEAD_DATA_BITS};  // bit stream starts with those data bits
    uint16_t run = 0;
    if (code == CODE_RUN) {  // head says: repeat the carried over mode for a run of steps
        run = (uint16_t)((data >> RUN_LOW_BITS) - 1);  // run length, minus the step this head covers
        bits.buffer = data % (1u << RUN_LOW_BITS);  // the remaining data bits stay in the stream
        bits.buffered = RUN_LOW_BITS;
    } else {
        set_mode(mode, code);  // head picks a new delta mode
    }
    int32_t first = 0;
    if (mode->bits != T5_KEY_HOLD) first = read_delta(&bits, mode);  // first delta moves the start value
    uint16_t current = (uint16_t)(value + first);  // value after frame 0 (wraps at 16 bits)
    int32_t velocity = 0;  // speed of the key, changed by each delta
    for (int32_t step = 0; step < steps; step++) {  // play the steps up to the wanted frame in the block
        if (run == 0) {  // no run left: read the next code
            code = bits_read(&bits, CODE_BITS);
            if (code == CODE_RUN) run = (uint16_t)(bits_read(&bits, CODE_BITS) - 1);  // run code: read how long it repeats
            else set_mode(mode, code);  // new delta mode
        } else {  // run still going
            run--;  // one step of the run used
        }
        if (mode->bits == T5_KEY_HOLD) break;  // hold: value stays as is, stop early
        velocity += read_delta(&bits, mode);  // delta changes the speed
        current = (uint16_t)(current + velocity);  // speed moves the value
    }
    return (int16_t)current;
}

static float position_scale(const T5Anim *anim, int32_t channel) {
    if (channel == CHANNEL_TRUNK_POINT) return anim->position_scale[2];  // trunk point shares the third position scale
    return anim->position_scale[channel];  // root and hip use their own scale
}

// Frame 0 is the base pose. Frame n > 0 is step (n-1) & 15 of block (n-1) >> 4; each block
// starts again from the base. Out-of-range frames clamp to 0..frame_count-1.
void t5_anim_decode(T5KeyMode *mode, const T5Anim *anim, T5Vec4 *out, int32_t frame, int32_t count) {
    if (!anim->ready) {  // anim was never loaded: pose is all zeros
        for (int32_t channel = 0; channel < count; channel++)
            for (int axis = 0; axis < 3; axis++) out[channel].v[axis] = 0.0f;
        return;
    }
    int32_t clamped_frame = frame;
    if (clamped_frame < 0) clamped_frame = 0;  // before the start: stay on the first frame
    if (clamped_frame + 1 >= anim->frame_count) clamped_frame = anim->frame_count - 1;  // past the end: stay on the last frame

    int16_t state[T5_CHANNELS][3] = {{0}};  // start values for the key decoder, per channel and axis
    for (int32_t channel = 0; channel < count; channel++) {
        for (int axis = 0; axis < 3; axis++) {
            if (t5_channel_is_rotation(channel)) {
                out[channel].v[axis] = (float)anim->base[channel].rotation[axis] * T5_ANGLE_TO_RAD;
                state[channel][axis] = sraw16(anim->base[channel].rotation[axis], anim->rotation_shift);
            } else {
                out[channel].v[axis] = anim->base[channel].position[axis];
            }
        }
    }
    if (clamped_frame == 0 || count <= 0) return;  // frame 0 is the base pose, nothing to decode

    // find the 16 frame block for this frame
    const uint8_t *field = anim->blocks + read32(anim->blocks + 4 * ((clamped_frame - 1) >> 4));
    int32_t steps = (clamped_frame - 1) & 15;  // how far into the block the frame is
    T5KeyMode key_mode = *mode;  // work on a copy, so the caller mode only changes on success
    for (int32_t channel = 0; channel < count; channel++) {
        for (int axis = 0; axis < 3; axis++) {
            int16_t decoded = decode_field(&key_mode, field, state[channel][axis], steps);
            field += field[0] >> 2;  // jump to the next field using its stored size
            if (t5_channel_is_rotation(channel))
                out[channel].v[axis] = (float)(int32_t)slw(decoded, anim->rotation_shift) * T5_ANGLE_TO_RAD;
            else
                out[channel].v[axis] = fmaf((float)(int32_t)slw(decoded, (uint8_t)anim->position_shift), position_scale(anim, channel), out[channel].v[axis]);
        }
    }
    *mode = key_mode;  // hand the delta mode on to the next decode
}

// --- samplers

static const float LERP_MIN = 1e-5f;

// axis = row 2 of RotY(yaw) then RotX(pitch) on the matrix stack, angle = key z
static void key_quat(T5Vec4 *turn, const T5Vec4 *key) {
    T5Mat4 matrix;
    t5_mat_identity(&matrix);
    t5_mat_rotate_y(&matrix, t5_rad_to_angle_round(key->y));
    t5_mat_rotate_x(&matrix, t5_rad_to_angle_round(key->x));
    T5Vec4 axis = {{matrix.m[2][0], matrix.m[2][1], matrix.m[2][2], matrix.m[2][3]}};
    t5_quat_axis_angle(turn, key->z, &axis);
}

static void lerp3(T5Vec4 *out, float weight, const T5Vec4 *from, const T5Vec4 *to) {
    float remaining = 1.0f - weight;  // weight is how far we are towards the next key
    for (int axis = 0; axis < 3; axis++) out->v[axis] = fmaf(remaining, from->v[axis], weight * to->v[axis]);
}

static int32_t next_frame(int32_t frame) { return frame + 1; }  // the frame after this one

void t5_anim_sample(T5KeyMode *mode, const T5Anim *anim, float frame, T5Vec4 pose[T5_CHANNELS], bool keep_hips) {
    float whole;
    float weight = t5_modf(frame, &whole);  // split the time into whole frame and fraction between frames
    int32_t whole_frame = t5_fctiwz(whole);
    T5Vec4 keys_now[T5_CHANNELS], keys_next[T5_CHANNELS];
    t5_anim_decode(mode, anim, keys_now, whole_frame, T5_CHANNELS);
    if (weight >= LERP_MIN) {  // between two frames: decode both and blend
        t5_anim_decode(mode, anim, keys_next, next_frame(whole_frame), T5_CHANNELS);
        for (int32_t channel = 0; channel < T5_CHANNELS; channel++) {
            if (!t5_channel_is_rotation(channel)) {  // positions blend in a straight line
                lerp3(&pose[channel], weight, &keys_now[channel], &keys_next[channel]);
                continue;
            }
            T5Vec4 turn_now, turn_next;
            key_quat(&turn_now, &keys_now[channel]);
            key_quat(&turn_next, &keys_next[channel]);
            t5_quat_nlerp(&pose[channel], weight, &turn_now, &turn_next);  // rotations blend as turns
        }
    } else {
        for (int32_t channel = 0; channel < T5_CHANNELS; channel++) {
            if (t5_channel_is_rotation(channel)) key_quat(&pose[channel], &keys_now[channel]);
            else for (int axis = 0; axis < 3; axis++) pose[channel].v[axis] = keys_now[channel].v[axis];
        }
    }
    pose[CHANNEL_ROOT].z = -pose[CHANNEL_ROOT].z;  // flip the depth axis of the root
    pose[CHANNEL_HIP].z = -pose[CHANNEL_HIP].z;  // flip the depth axis of the hip
    if (!keep_hips) t5_pose_level_hips(pose);  // unless asked to keep them, level the hips
}

enum { YAW_CHANNELS = CHANNEL_ROOT_YAW + 1 };  // the decoder reads channels in order, up to the root yaw

void t5_anim_sample_yaw(T5KeyMode *mode, const T5Anim *anim, float frame, T5Vec4 *turn) {
    float whole;
    float weight = t5_modf(frame, &whole);  // split the time into whole frame and fraction between frames
    int32_t whole_frame = t5_fctiwz(whole);
    T5Vec4 keys_now[YAW_CHANNELS], keys_next[YAW_CHANNELS], turn_now, turn_next;
    t5_anim_decode(mode, anim, keys_now, whole_frame, YAW_CHANNELS);
    if (!(weight >= LERP_MIN)) {  // on a whole frame: no blend needed
        key_quat(turn, &keys_now[CHANNEL_ROOT_YAW]);
        return;
    }
    t5_anim_decode(mode, anim, keys_next, next_frame(whole_frame), YAW_CHANNELS);
    key_quat(&turn_now, &keys_now[CHANNEL_ROOT_YAW]);
    key_quat(&turn_next, &keys_next[CHANNEL_ROOT_YAW]);
    t5_quat_nlerp(turn, weight, &turn_now, &turn_next);  // blend the two yaw turns
}

// The single-frame path converts the frame itself, not its integer part (same value).
void t5_anim_sample_root(T5KeyMode *mode, const T5Anim *anim, float frame, T5Vec4 root[2]) {
    float whole;
    float weight = t5_modf(frame, &whole);  // split the time into whole frame and fraction between frames
    T5Vec4 keys_now[2], keys_next[2];
    if (weight >= LERP_MIN) {  // between two frames: decode both and blend
        int32_t whole_frame = t5_fctiwz(whole);
        t5_anim_decode(mode, anim, keys_now, whole_frame, 2);
        t5_anim_decode(mode, anim, keys_next, next_frame(whole_frame), 2);
        // blend root and hip positions
        for (int channel = 0; channel < 2; channel++) lerp3(&root[channel], weight, &keys_now[channel], &keys_next[channel]);
    } else {
        t5_anim_decode(mode, anim, keys_now, t5_fctiwz(frame), 2);
        for (int channel = 0; channel < 2; channel++)
            for (int axis = 0; axis < 3; axis++) root[channel].v[axis] = keys_now[channel].v[axis];
    }
    root[0].z = -root[0].z;  // flip the depth axis, same as the full sampler
    root[1].z = -root[1].z;
}

// --- pose fix-ups


// matrix * inverse, with row 3 of both set to (0,0,0,1) first
static void times_rotation(T5Mat4 *matrix, const T5Mat4 *inverse) {
    static const float W[4] = {0, 0, 0, 1};
    T5Mat4 product = *inverse, rows = *matrix;
    memcpy(product.m[3], W, sizeof W);
    memcpy(rows.m[3], W, sizeof W);
    t5_mat_multiply(&product, &rows);  // inverse times matrix
    *matrix = product;
}

static void quat_mat(T5Mat4 *matrix, const T5Vec4 *turn) {
    t5_mat_identity(matrix);
    t5_quat_to_mat(matrix, turn);
}

static const float LEVEL_HIPS_MIN = 0.707106709f;  // one ulp under cos 45 degrees 

void t5_pose_level_hips(T5Vec4 pose[T5_CHANNELS]) {
    static const T5Vec4 DOWN = {{0, -1, 0, 0}};
    T5Mat4 hips, spine, pelvis, product;
    quat_mat(&hips, &pose[CHANNEL_HIPS]);  // hips, spine and pelvis turns as matrices
    if (fabsf(hips.m[1][1]) < LEVEL_HIPS_MIN) return;  // hips tilted more than 45 degrees (lying, flipping): leave the pose alone
    quat_mat(&spine, &pose[CHANNEL_SPINE]);
    quat_mat(&pelvis, &pose[CHANNEL_PELVIS]);
    product = hips;
    t5_mat_multiply(&product, &spine);
    spine = product;
    product = hips;
    t5_mat_multiply(&product, &pelvis);
    pelvis = product;

    // hips keep only the facing turn (root yaw)
    t5_quat_axis_angle(&pose[CHANNEL_HIPS], t5_quat_yaw(&pose[CHANNEL_ROOT_YAW]), &DOWN);
    t5_quat_to_mat(&hips, &pose[CHANNEL_HIPS]);
    t5_mat_inverse(&hips);  // undo the hips change
    times_rotation(&spine, &hips);  // spine and pelvis take over the tilt the hips gave up
    times_rotation(&pelvis, &hips);
    t5_mat_to_quat(&pose[CHANNEL_SPINE], &spine);  // write the new spine and pelvis turns back
    t5_mat_to_quat(&pose[CHANNEL_PELVIS], &pelvis);
}

void t5_pose_scale_root(T5Vec4 root[2], float scale_xz, float scale_xz_add, float scale_y) {
    float scale_xz_total = scale_xz + scale_xz_add;  // sideways and depth scale (body width)
    for (int channel = 0; channel < 2; channel++) {  // root and hip
        root[channel].x *= scale_xz_total;
        root[channel].y *= scale_y;  // height scale
        root[channel].z *= scale_xz_total;
    }
}

bool t5_anim_same(const T5Anim *first, const T5Anim *second) { return first == second || (first && second && first->blocks == second->blocks); }
