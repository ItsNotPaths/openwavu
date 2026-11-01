#include "sim/anim.h"

#include <math.h>
#include <string.h>

#include "sim/math.h"
#include "sim/quat.h"

// --- .anim file (docs/formats.md): "OWAN", u32 version, char[8] layout, u32 frames, u32 fps, f32 metres per unit,
// u32 channels, per channel {u8 kind, u8 components, i16 bone}, then f32 keys[frames][channels][components]

enum { ANIM_VERSION = 2, HEADER_BYTES = 32, CHANNEL_BYTES = 4, KIND_POSITION = 1, KIND_AXIS_ANGLE = 3, KEY_COMPONENTS = 3 };

static uint32_t read32(const uint8_t *bytes) {  // little endian
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

uint16_t t5_anim_file(T5Bytes file, const char *layout, int32_t channels, bool (*is_rotation)(int32_t), const float **keys) {
    const size_t start = HEADER_BYTES + (size_t)channels * CHANNEL_BYTES, frame_bytes = (size_t)channels * KEY_COMPONENTS * sizeof(float);
    if (file.size < start || memcmp(file.data, "OWAN", 4) != 0 || read32(file.data + 4) != ANIM_VERSION) return 0;
    if (strncmp((const char *)file.data + 8, layout, 8) != 0 || read32(file.data + 28) != (uint32_t)channels) return 0;
    uint32_t frames = read32(file.data + 16);
    if (frames > UINT16_MAX || (file.size - start) / frame_bytes < frames) return 0;
    const uint8_t *channel = file.data + HEADER_BYTES;
    for (int32_t index = 0; index < channels; index++, channel += CHANNEL_BYTES) {
        uint8_t kind = is_rotation(index) ? KIND_AXIS_ANGLE : KIND_POSITION;
        if (channel[0] != kind || channel[1] != KEY_COMPONENTS) return 0;
    }
    *keys = (const float *)(file.data + start);
    return (uint16_t)frames;
}

int t5_anim_parse(T5Anim *anim, T5Bytes file) {
    const float *keys;
    uint16_t frames = t5_anim_file(file, "tk5", T5_CHANNELS, t5_channel_is_rotation, &keys);  // the layout the samplers read
    *anim = frames ? (T5Anim){frames, (const T5AnimKeys *)keys} : (T5Anim){0};
    return frames ? 0 : -1;
}

void t5_anim_keys(const T5Anim *anim, T5Vec4 *out, int32_t frame, int32_t count) {
    static const T5AnimKeys NONE;
    const T5AnimKeys *keys = &NONE;
    if (anim->keys) {
        if (frame < 0) frame = 0;  // before the start: the first frame
        if (frame + 1 >= anim->frame_count) frame = anim->frame_count - 1;  // past the end: the last frame
        keys = &anim->keys[frame];
    }
    for (int32_t channel = 0; channel < count; channel++)
        for (int axis = 0; axis < 3; axis++) out[channel].v[axis] = (*keys)[channel][axis];
}

// --- samplers

static const float LERP_MIN = 1e-5f;

void t5_anim_key_turn(T5Vec4 *turn, const T5Vec4 *key) {
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

void t5_anim_sample(const T5Anim *anim, float frame, T5Vec4 pose[T5_CHANNELS], bool keep_hips) {
    float whole;
    float weight = t5_modf(frame, &whole);  // split the time into whole frame and fraction between frames
    int32_t whole_frame = t5_fctiwz(whole);
    T5Vec4 keys_now[T5_CHANNELS], keys_next[T5_CHANNELS];
    t5_anim_keys(anim, keys_now, whole_frame, T5_CHANNELS);
    if (weight >= LERP_MIN) {  // between two frames: decode both and blend
        t5_anim_keys(anim, keys_next, next_frame(whole_frame), T5_CHANNELS);
        for (int32_t channel = 0; channel < T5_CHANNELS; channel++) {
            if (!t5_channel_is_rotation(channel)) {  // positions blend in a straight line
                lerp3(&pose[channel], weight, &keys_now[channel], &keys_next[channel]);
                continue;
            }
            T5Vec4 turn_now, turn_next;
            t5_anim_key_turn(&turn_now, &keys_now[channel]);
            t5_anim_key_turn(&turn_next, &keys_next[channel]);
            t5_quat_nlerp(&pose[channel], weight, &turn_now, &turn_next);  // rotations blend as turns
        }
    } else {
        for (int32_t channel = 0; channel < T5_CHANNELS; channel++) {
            if (t5_channel_is_rotation(channel)) t5_anim_key_turn(&pose[channel], &keys_now[channel]);
            else for (int axis = 0; axis < 3; axis++) pose[channel].v[axis] = keys_now[channel].v[axis];
        }
    }
    pose[CHANNEL_ROOT].z = -pose[CHANNEL_ROOT].z;  // flip the depth axis of the root
    pose[CHANNEL_HIP].z = -pose[CHANNEL_HIP].z;  // flip the depth axis of the hip
    if (!keep_hips) t5_pose_level_hips(pose);  // unless asked to keep them, level the hips
}

enum { YAW_CHANNELS = CHANNEL_ROOT_YAW + 1 };  // the decoder reads channels in order, up to the root yaw

void t5_anim_sample_yaw(const T5Anim *anim, float frame, T5Vec4 *turn) {
    float whole;
    float weight = t5_modf(frame, &whole);  // split the time into whole frame and fraction between frames
    int32_t whole_frame = t5_fctiwz(whole);
    T5Vec4 keys_now[YAW_CHANNELS], keys_next[YAW_CHANNELS], turn_now, turn_next;
    t5_anim_keys(anim, keys_now, whole_frame, YAW_CHANNELS);
    if (!(weight >= LERP_MIN)) {  // on a whole frame: no blend needed
        t5_anim_key_turn(turn, &keys_now[CHANNEL_ROOT_YAW]);
        return;
    }
    t5_anim_keys(anim, keys_next, next_frame(whole_frame), YAW_CHANNELS);
    t5_anim_key_turn(&turn_now, &keys_now[CHANNEL_ROOT_YAW]);
    t5_anim_key_turn(&turn_next, &keys_next[CHANNEL_ROOT_YAW]);
    t5_quat_nlerp(turn, weight, &turn_now, &turn_next);  // blend the two yaw turns
}

// The single-frame path converts the frame itself, not its integer part (same value).
void t5_anim_sample_root(const T5Anim *anim, float frame, T5Vec4 root[2]) {
    float whole;
    float weight = t5_modf(frame, &whole);  // split the time into whole frame and fraction between frames
    T5Vec4 keys_now[2], keys_next[2];
    if (weight >= LERP_MIN) {  // between two frames: decode both and blend
        int32_t whole_frame = t5_fctiwz(whole);
        t5_anim_keys(anim, keys_now, whole_frame, 2);
        t5_anim_keys(anim, keys_next, next_frame(whole_frame), 2);
        // blend root and hip positions
        for (int channel = 0; channel < 2; channel++) lerp3(&root[channel], weight, &keys_now[channel], &keys_next[channel]);
    } else {
        t5_anim_keys(anim, keys_now, t5_fctiwz(frame), 2);
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

bool t5_anim_same(const T5Anim *first, const T5Anim *second) { return first == second || (first && second && first->keys == second->keys); }
