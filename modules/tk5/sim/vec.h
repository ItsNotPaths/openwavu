// Vector helpers and the VMX matrix stack.
// The game keeps the current matrix in thread-local storage; here it is an explicit T5Mat4.
#ifndef T5_VEC_H
#define T5_VEC_H

#include <math.h>
#include <stdint.h>

typedef union { _Alignas(16) float v[4]; struct { float x, y, z, w; }; } T5Vec4;  // v[] and x, y, z, w share storage
typedef struct { _Alignas(16) float m[4][4]; } T5Mat4;  // m[row][column]; row 3 holds translation

void t5_vec_add(T5Vec4 *out, const T5Vec4 *left, const T5Vec4 *right);
void t5_vec_add_xyz(T5Vec4 *out, const T5Vec4 *left, const T5Vec4 *right);  // x, y, z added; w of left kept
void t5_vec_subtract(T5Vec4 *out, const T5Vec4 *left, const T5Vec4 *right);
void t5_vec_scale(T5Vec4 *out, const T5Vec4 *left, float factor);
float t5_vec_dot3(const T5Vec4 *left, const T5Vec4 *right);
void t5_vec_cross(T5Vec4 *out, const T5Vec4 *left, const T5Vec4 *right); // left x right, w not written
float t5_vec_dot4(const T5Vec4 *left, const T5Vec4 *right);
void t5_vec_times_mat(T5Vec4 *out, const T5Vec4 *vector, const T5Mat4 *stack); // row vector * stack
float t5_vmx_subtract(float left, float right);                    // one VMX lane: denormals flush to zero

// Value-type vectors. Same float operation order as the pointer helpers above (dot and cross fuse as they do).
typedef struct { float x, y, z; } T5Vec3;

[[nodiscard]] static inline T5Vec3 vec3_add(T5Vec3 left, T5Vec3 right) { return (T5Vec3){left.x + right.x, left.y + right.y, left.z + right.z}; }
[[nodiscard]] static inline T5Vec3 vec3_subtract(T5Vec3 left, T5Vec3 right) { return (T5Vec3){left.x - right.x, left.y - right.y, left.z - right.z}; }
[[nodiscard]] static inline T5Vec3 vec3_scale(T5Vec3 left, float factor) { return (T5Vec3){left.x * factor, left.y * factor, left.z * factor}; }
[[nodiscard]] static inline float vec3_dot(T5Vec3 left, T5Vec3 right) { return fmaf(left.z, right.z, fmaf(left.x, right.x, left.y * right.y)); }
[[nodiscard]] static inline T5Vec3 vec3_cross(T5Vec3 left, T5Vec3 right) {
    return (T5Vec3){fmaf(left.y, right.z, -(right.y * left.z)), fmaf(left.z, right.x, -(right.z * left.x)), fmaf(right.y, left.x, -(left.y * right.x))};
}

[[nodiscard]] static inline T5Vec3 vec3_of(T5Vec4 vector) { return (T5Vec3){vector.x, vector.y, vector.z}; }  // w dropped
[[nodiscard]] static inline T5Vec4 vec4_of(T5Vec3 vector, float w) { return (T5Vec4){{vector.x, vector.y, vector.z, w}}; }

[[nodiscard]] static inline T5Vec4 vec4_add(T5Vec4 left, T5Vec4 right) {
    return (T5Vec4){{left.x + right.x, left.y + right.y, left.z + right.z, left.w + right.w}};
}
[[nodiscard]] static inline T5Vec4 vec4_subtract(T5Vec4 left, T5Vec4 right) {
    return (T5Vec4){{left.x - right.x, left.y - right.y, left.z - right.z, left.w - right.w}};
}
[[nodiscard]] static inline T5Vec4 vec4_scale(T5Vec4 left, float factor) {
    return (T5Vec4){{left.x * factor, left.y * factor, left.z * factor, left.w * factor}};
}

void t5_mat_identity(T5Mat4 *stack);
void t5_mat_set(T5Mat4 *stack, const T5Mat4 *matrix);
void t5_mat_get(const T5Mat4 *stack, T5Mat4 *out);
void t5_mat_multiply(T5Mat4 *stack, const T5Mat4 *matrix);  // stack = matrix * stack (VMX)
void t5_mat_rotate_x(T5Mat4 *stack, int32_t angle);  // binary angle: 65536 = one turn
void t5_mat_rotate_y(T5Mat4 *stack, int32_t angle);
void t5_mat_rotate_z(T5Mat4 *stack, int32_t angle);
void t5_mat_inverse(T5Mat4 *stack);                    // affine inverse (VMX, vrefp)
void t5_mat_transpose(T5Mat4 *stack);                  // all 16 lanes

// Patterns of the skeleton code (inline in the game, built from the helpers above).
void t5_vec_normalize(T5Vec4 *out, const T5Vec4 *vector);  // vector / |vector| (0 for a zero vector), w = 0
[[nodiscard]] static inline T5Vec4 vec4_normalized(T5Vec4 vector) {
    t5_vec_normalize(&vector, &vector);
    return vector;
}
// rows 0..2: x along `x`, y toward `y` (made orthogonal), z = x * y
void t5_mat_frame_xy(T5Mat4 *matrix, const T5Vec4 *x, const T5Vec4 *y);
// rows 0..2: x turned onto `x`, z kept as near as it can be, y = z * x
void t5_mat_frame_turn_x(T5Mat4 *matrix, const T5Vec4 *x);
// matrix rows 0..2 = left rows 0..2 * right rows 0..2 on the matrix stack (row 3 taken as 0,0,0,1); matrix row 3 stays
void t5_mat_rotation_product(T5Mat4 *matrix, const T5Mat4 *left, const T5Mat4 *right);
// rotation of `rotation` relative to `base`: rotation_product(rotation, inverse(base))
void t5_mat_relative_rotation(T5Mat4 *matrix, const T5Mat4 *rotation, const T5Mat4 *base);

// matrix = rotation about z by a radian angle (identity, then rotate_z by the rounded binary angle)
void t5_mat_z_turn(T5Mat4 *matrix, float angle);

// matrix = Rz * Ry * Rx (row vectors: z turns first) or Rx * Ry * Rz, from radians; the matrix translation stays
void t5_mat_euler_zyx(T5Mat4 *matrix, const float angles[3]);
void t5_mat_euler_xyz(T5Mat4 *matrix, const float angles[3]);

#endif
