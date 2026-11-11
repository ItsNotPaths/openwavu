// Quaternions (x, y, z, w) as the engine uses them: row-vector matrices, w last.
#ifndef T6_QUAT_H
#define T6_QUAT_H

#include "sim/vec.h"

void t6_quat_axis_angle(T6Vec4 *turn, float angle, const T6Vec4 *axis);
void t6_quat_blend(T6Vec4 *out, float weight, const T6Vec4 *from, const T6Vec4 *to);  // shortest-arc lerp, no normalize
void t6_quat_normalize(T6Vec4 *out, const T6Vec4 *turn);  // zero-size turn becomes all zeros
void t6_quat_nlerp(T6Vec4 *out, float weight, const T6Vec4 *from, const T6Vec4 *to);  // blend, then fix length
void t6_quat_to_mat(T6Mat4 *matrix, const T6Vec4 *turn);                // rows 0..2 and matrix[3][3]
void t6_mat_to_quat(T6Vec4 *turn, const T6Mat4 *matrix);  // matrix back to turn; the largest part keeps its sign
void t6_quat_multiply(T6Vec4 *out, const T6Vec4 *left, const T6Vec4 *right);  // (left x right + left.w right + right.w left, left.w right.w - left.right)
float t6_quat_yaw(const T6Vec4 *turn);                                  // atan2(-matrix[0][2], matrix[0][0])

#endif
