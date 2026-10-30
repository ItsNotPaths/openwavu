// Quaternions (x, y, z, w) as the engine uses them: row-vector matrices, w last.
#ifndef T5_QUAT_H
#define T5_QUAT_H

#include "sim/vec.h"

void t5_quat_axis_angle(T5Vec4 *turn, float angle, const T5Vec4 *axis);
void t5_quat_blend(T5Vec4 *out, float weight, const T5Vec4 *from, const T5Vec4 *to);  // shortest-arc lerp, no normalize
void t5_quat_normalize(T5Vec4 *out, const T5Vec4 *turn);  // zero-size turn becomes all zeros
void t5_quat_nlerp(T5Vec4 *out, float weight, const T5Vec4 *from, const T5Vec4 *to);  // blend, then fix length
void t5_quat_to_mat(T5Mat4 *matrix, const T5Vec4 *turn);                // rows 0..2 and matrix[3][3]
void t5_mat_to_quat(T5Vec4 *turn, const T5Mat4 *matrix);  // matrix back to turn; the largest part keeps its sign
void t5_quat_multiply(T5Vec4 *out, const T5Vec4 *left, const T5Vec4 *right);  // (left x right + left.w right + right.w left, left.w right.w - left.right)
float t5_quat_yaw(const T5Vec4 *turn);                                  // atan2(-matrix[0][2], matrix[0][0])

#endif
