#include "sim/quat.h"

#include <math.h>
#include <stdbool.h>

#include "sim/math.h"

static const float EPSILON = 1e-5f;

// turn = (axis * sin(angle/2), sqrt(1 - sin^2)); the axis w lane is scaled too, then replaced
void t5_quat_axis_angle(T5Vec4 *turn, float angle, const T5Vec4 *axis) {
    float sine = t5_sin(angle * 0.5f);  // turn by angle around axis: a joint rotation, e.g. hips yaw
    t5_vec_scale(turn, axis, sine);
    turn->w = sqrtf(1.0f - sine * sine);
}

void t5_quat_blend(T5Vec4 *out, float weight, const T5Vec4 *from, const T5Vec4 *to) {
    if (fabsf(weight) < EPSILON) {  // blend two joint rotations: weight 0 is all from, 1 is all to (used to fade between poses)
        *out = *from;  // no weight, keep the from pose
        return;
    }
    float weight_from = 1.0f - weight;
    if (t5_vec_dot4(from, to) < 0.0f) weight_from = -weight_from;  // opposite ways: flip one, take the short way
    T5Vec4 scaled_from, scaled_to;
    t5_vec_scale(&scaled_from, from, weight_from);
    t5_vec_scale(&scaled_to, to, weight);
    t5_vec_add(out, &scaled_from, &scaled_to);
    if (out->x < 0.0f) t5_vec_scale(out, out, -1.0f);  // the sign follows x, not w
}

void t5_quat_normalize(T5Vec4 *out, const T5Vec4 *turn) {
    float length = sqrtf(t5_vec_dot4(turn, turn));  // a zero-size rotation becomes all zeros
    if (length <= EPSILON) *out = (T5Vec4){{0, 0, 0, 0}};
    else t5_vec_scale(out, turn, 1.0f / length);
}

void t5_quat_nlerp(T5Vec4 *out, float weight, const T5Vec4 *from, const T5Vec4 *to) {
    t5_quat_blend(out, weight, from, to);  // blend, then fix the length
    t5_quat_normalize(out, out);
}

void t5_quat_to_mat(T5Mat4 *matrix, const T5Vec4 *turn) {
    float x = turn->x, y = turn->y, z = turn->z, w = turn->w;  // fills the top-left 3x3 of the matrix
    float xx = x * x;
    float yy = y * y;
    float zz = z * z;
    float xy = x * y;
    float xz = x * z;
    float yz = y * z;
    float wx = w * x;
    float wy = w * y;
    float wz = w * z;
    float (*rows)[4] = matrix->m;
    rows[0][0] = (1.0f - (yy + zz)) - (yy + zz);
    rows[0][1] = 2.0f * (xy - wz);
    rows[0][2] = 2.0f * (xz + wy);
    rows[0][3] = 0.0f;
    rows[1][0] = 2.0f * (xy + wz);
    rows[1][1] = (1.0f - (xx + zz)) - (xx + zz);
    rows[1][2] = 2.0f * (yz - wx);
    rows[1][3] = 0.0f;
    rows[2][0] = 2.0f * (xz - wy);
    rows[2][1] = 2.0f * (yz + wx);
    rows[2][2] = (1.0f - (xx + yy)) - (xx + yy);
    rows[2][3] = 0.0f;
    rows[3][3] = 1.0f;
}

// The largest of x2, y2, z2 keeps its sign; the others take the sign of the matching sums.
// The compares are written so that NaN picks the branch that fcmpu picks.
void t5_mat_to_quat(T5Vec4 *turn, const T5Mat4 *matrix) {
    const float (*rows)[4] = matrix->m;
    float x_squared = (((rows[0][0] + 1.0f) - rows[1][1]) - rows[2][2]) * 0.25f;  // squares from diagonal; signs come back below
    float y_squared = ((rows[1][1] + (1.0f - rows[0][0])) - rows[2][2]) * 0.25f;
    float z_squared = (rows[2][2] + ((1.0f - rows[0][0]) - rows[1][1])) * 0.25f;
    float w_squared = ((1.0f - x_squared) - y_squared) - z_squared;
    if (x_squared < 0.0f) x_squared = 0.0f;  // rounding can push a square below zero, clamp so the roots stay valid
    if (y_squared < 0.0f) y_squared = 0.0f;
    if (z_squared < 0.0f) z_squared = 0.0f;
    if (w_squared < 0.0f) w_squared = 0.0f;
    float x = sqrtf(x_squared);
    float y = sqrtf(y_squared);
    float z = sqrtf(z_squared);
    float w = sqrtf(w_squared);
    float xy = rows[0][1] + rows[1][0];  // sums and differences of mirrored entries give the signs of each pair
    float xz = rows[2][0] + rows[0][2];
    float yz = rows[1][2] + rows[2][1];
    float wx = rows[2][1] - rows[1][2];
    float wy = rows[0][2] - rows[2][0];
    float wz = rows[1][0] - rows[0][1];
    bool x_big = !(x_squared <= y_squared) && x_squared > z_squared;  // the largest keeps its positive root
    bool y_big = x_squared <= y_squared && !(y_squared <= z_squared);
    if (x_big) {  // set the other signs relative to the largest
        if (xy < 0.0f) y = -y;
        if (xz < 0.0f) z = -z;
        if (wx < 0.0f) w = -w;
    } else if (y_big) {
        if (yz < 0.0f) z = -z;
        if (xy < 0.0f) x = -x;
        if (wy < 0.0f) w = -w;
    } else {
        if (xz < 0.0f) x = -x;
        if (yz < 0.0f) y = -y;
        if (wz < 0.0f) w = -w;
    }
    *turn = (T5Vec4){{x, y, z, w}};
}

void t5_quat_multiply(T5Vec4 *out, const T5Vec4 *left, const T5Vec4 *right) {
    T5Vec4 cross_part, scaled;  // combine two rotations: left then right, as one rotation
    t5_vec_cross(&cross_part, left, right);
    cross_part.w = left->w;
    t5_vec_scale(&scaled, right, left->w);
    t5_vec_add(&cross_part, &cross_part, &scaled);
    t5_vec_scale(&scaled, left, right->w);
    float w = left->w * right->w;
    float dot = t5_vec_dot3(left, right);
    t5_vec_add(out, &cross_part, &scaled);
    out->w = w - dot;
}

float t5_quat_yaw(const T5Vec4 *turn) {
    T5Mat4 matrix;  // facing angle around the up axis: build the matrix, read the heading from its first row
    t5_quat_to_mat(&matrix, turn);
    return t5_atan2(-matrix.m[0][2], matrix.m[0][0]);
}
