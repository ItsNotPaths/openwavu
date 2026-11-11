#include "sim/vec.h"

#include <float.h>
#include <math.h>
#include <string.h>

#include "sim/math.h"

void t6_vec_add(T6Vec4 *out, const T6Vec4 *left, const T6Vec4 *right) {
    *out = vec4_add(*left, *right);
}

void t6_vec_add_xyz(T6Vec4 *out, const T6Vec4 *left, const T6Vec4 *right) {
    float w = left->w;  // keep the w of the left vector
    t6_vec_add(out, left, right);
    out->w = w;  // put that w back
}

void t6_vec_subtract(T6Vec4 *out, const T6Vec4 *left, const T6Vec4 *right) {
    *out = vec4_subtract(*left, *right);
}

void t6_vec_scale(T6Vec4 *out, const T6Vec4 *left, float factor) {
    *out = vec4_scale(*left, factor);
}

float t6_vec_dot3(const T6Vec4 *left, const T6Vec4 *right) {
    return fmaf(left->z, right->z, fmaf(left->x, right->x, left->y * right->y));  // sum of the three products
}

void t6_vec_cross(T6Vec4 *out, const T6Vec4 *left, const T6Vec4 *right) {
    float x = fmaf(left->y, right->z, -(right->y * left->z));  // each axis: two products of the other two axes, subtracted
    float y = fmaf(left->z, right->x, -(right->z * left->x));
    float z = fmaf(right->y, left->x, -(left->y * right->x));
    out->x = x;
    out->y = y;
    out->z = z;
}

float t6_vec_dot4(const T6Vec4 *left, const T6Vec4 *right) {
    return fmaf(left->w, right->w,  // the three-part sum plus the w product
                fmaf(left->z, right->z, fmaf(left->x, right->x, left->y * right->y)));
}

void t6_vec_times_mat(T6Vec4 *out, const T6Vec4 *vector, const T6Mat4 *stack) {
    const float (*rows)[4] = stack->m;
    float x = vector->x, y = vector->y, z = vector->z, w = vector->w;  // read all four parts first
    for (int column = 0; column < 4; column++)  // each output part is the vector against one matrix column
        out->v[column] = fmaf(w, rows[3][column], fmaf(z, rows[2][column], fmaf(x, rows[0][column], y * rows[1][column])));
}

// --- VMX lanes. VSCR[NJ] = 1 (reset value): denormal inputs and results become signed zero.

static float ftz(float x) {  // a tiny denormal value becomes zero with the same sign
    return fabsf(x) < FLT_MIN ? copysignf(0.0f, x) : x;
}
static float vfma(float left, float right, float addend) {  // multiply and add, denormals flushed going in and out
    return ftz(fmaf(ftz(left), ftz(right), ftz(addend)));
}
static float vmul(float left, float right) { return vfma(left, right, 0.0f); }  // vmaddfp with a +0 addend
static float vadd(float left, float right) {  // add, denormals flushed going in and out
    return ftz(ftz(left) + ftz(right));
}
static float vsub(float left, float right) {  // subtract, denormals flushed going in and out
    return ftz(ftz(left) - ftz(right));
}

float t6_vmx_subtract(float left, float right) { return vsub(left, right); }

void t6_mat_identity(T6Mat4 *stack) {
    static const T6Mat4 identity = {{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}}};
    *stack = identity;
}

void t6_mat_set(T6Mat4 *stack, const T6Mat4 *matrix) { *stack = *matrix; }

void t6_mat_get(const T6Mat4 *stack, T6Mat4 *out) { *out = *stack; }

void t6_mat_multiply(T6Mat4 *stack, const T6Mat4 *matrix) {
    const float (*stack_rows)[4] = stack->m;
    T6Mat4 result;
    for (int row_index = 0; row_index < 4; row_index++) {  // build the result row by row
        const float *factor_row = matrix->m[row_index];
        for (int column = 0; column < 4; column++)  // each cell adds four products
            result.m[row_index][column] = vadd(vfma(stack_rows[2][column], factor_row[2],
                                                    vmul(stack_rows[0][column], factor_row[0])),
                                               vfma(stack_rows[3][column], factor_row[3],
                                                    vmul(stack_rows[1][column], factor_row[1])));
    }
    *stack = result;
}

// first' = first*cosine + second*sine, second' = second*cosine - first*sine
static void rotate(T6Mat4 *stack, int first_row, int second_row, int32_t angle) {
    float sine = t6_angle_sin(angle);
    float cosine = t6_angle_cos(angle);
    float *first = stack->m[first_row], *second = stack->m[second_row];
    for (int column = 0; column < 4; column++) {  // turn the two rows against each other, column by column
        float new_first = vfma(first[column], cosine, vmul(second[column], sine));
        float new_second = vsub(vmul(second[column], cosine), vmul(first[column], sine));
        first[column] = new_first;
        second[column] = new_second;
    }
}

void t6_mat_rotate_x(T6Mat4 *stack, int32_t angle) { rotate(stack, 1, 2, angle); }  // turn about the x axis
void t6_mat_rotate_y(T6Mat4 *stack, int32_t angle) { rotate(stack, 2, 0, angle); }  // turn about the y axis (up)
void t6_mat_rotate_z(T6Mat4 *stack, int32_t angle) { rotate(stack, 0, 1, angle); }  // turn about the z axis

// QEMU computes vrefp exactly. The Cell gives a 12-bit estimate whose table is not known,
// so results that go through this can differ on hardware.
static float vrefp(float x) { return ftz(1.0f / ftz(x)); }

// word permutes of the code's vperm masks
static const int P1[3] = {1, 2, 0}, P2[3] = {2, 0, 1};
static const int Q0[3] = {2, 1, 0}, Q1[3] = {1, 0, 2}, Q2[3] = {0, 2, 1};

static void cross(float out[3], const float left[4], const float right[4]) {
    for (int lane = 0; lane < 3; lane++)  // each lane: one product minus the swapped product
        out[lane] = vsub(vmul(left[P1[lane]], right[P2[lane]]), vmul(left[P2[lane]], right[P1[lane]]));
}

void t6_mat_transpose(T6Mat4 *stack) {
    T6Mat4 transposed;
    for (int row_index = 0; row_index < 4; row_index++)  // swap rows and columns
        for (int column = 0; column < 4; column++) transposed.m[row_index][column] = stack->m[column][row_index];
    *stack = transposed;
}

void t6_mat_z_turn(T6Mat4 *matrix, float angle) {
    t6_mat_identity(matrix);
    t6_mat_rotate_z(matrix, t6_rad_to_angle_round(angle));  // then turn about z by the angle, given in radians
}

// rows 0..2 = inverse of the 3x3 part, row 3 = (0,0,0,1) - translation * that inverse
void t6_mat_inverse(T6Mat4 *stack) {
    const float (*rows)[4] = stack->m;
    float positive_terms[3], negative_terms[3];  // the six terms of the determinant
    for (int row_index = 0; row_index < 3; row_index++) {  // the products that add and subtract in the determinant
        positive_terms[row_index] = vmul(rows[2][P2[row_index]], vmul(rows[1][P1[row_index]], rows[0][row_index]));
        negative_terms[row_index] = vmul(rows[2][Q2[row_index]], vmul(rows[0][Q0[row_index]], rows[1][Q1[row_index]]));
    }
    float negative_determinant = vsub(vadd(negative_terms[0], vadd(negative_terms[1], negative_terms[2])),  // negated determinant
                                      vadd(positive_terms[0], vadd(positive_terms[2], positive_terms[1])));
    float inverse_determinant = vrefp(negative_determinant);  // one over the determinant, only an estimate
    float negated_columns[3][3];  // columns of the inverse, negated
    cross(negated_columns[0], rows[1], rows[2]);  // cross products of row pairs give the inverse columns
    cross(negated_columns[1], rows[2], rows[0]);
    cross(negated_columns[2], rows[0], rows[1]);
    T6Mat4 inverse;
    for (int row_index = 0; row_index < 3; row_index++) {  // fill the 3x3 part of the inverse
        for (int column = 0; column < 3; column++)  // transpose the columns and divide by the determinant
            inverse.m[row_index][column] = vmul(negated_columns[column][row_index], inverse_determinant);
        inverse.m[row_index][3] = 0.0f;  // no w in the rotation rows
    }
    static const float W[4] = {0, 0, 0, 1};
    for (int column = 0; column < 4; column++)  // last row: (0,0,0,1) plus the old translation through the inverse
        inverse.m[3][column] = vadd(W[column], vfma(inverse.m[2][column], rows[3][2],
                                                    vfma(inverse.m[1][column], rows[3][1],
                                                         vmul(inverse.m[0][column], rows[3][0]))));
    for (int row_index = 0; row_index < 3; row_index++)  // flip the sign of the rows, which were built negated
        for (int column = 0; column < 4; column++) inverse.m[row_index][column] = vsub(0.0f, inverse.m[row_index][column]);
    *stack = inverse;
}

// --- skeleton patterns

void t6_vec_normalize(T6Vec4 *out, const T6Vec4 *vector) {
    float length = t6_length3(vector->x, vector->y, vector->z);
    t6_vec_scale(out, vector, length == 0.0f ? 0.0f : 1.0f / length);  // a zero length vector stays zero
    out->w = 0.0f;  // a direction has no w
}

// vector without its part along the unit vector, normalized
static void ortho(T6Vec4 *out, const T6Vec4 *vector, const T6Vec4 *unit) {
    T6Vec4 along;
    t6_vec_scale(&along, unit, t6_vec_dot3(vector, unit));  // the part of the vector along the unit
    t6_vec_subtract(&along, vector, &along);  // take that part away
    t6_vec_normalize(out, &along);  // back to length one
}

static T6Vec4 *row(T6Mat4 *matrix, int index) { return (T6Vec4 *)matrix->m[index]; }

void t6_mat_frame_xy(T6Mat4 *matrix, const T6Vec4 *x, const T6Vec4 *y) {
    T6Vec4 hint = *y;
    t6_vec_normalize(row(matrix, 0), x);  // first axis: the given x direction
    ortho(row(matrix, 1), &hint, row(matrix, 0));  // second axis: the given y with its part along x removed
    t6_vec_cross(row(matrix, 2), row(matrix, 0), row(matrix, 1));  // third axis: square to both
    matrix->m[2][3] = matrix->m[0][3];
}

void t6_mat_frame_turn_x(T6Mat4 *matrix, const T6Vec4 *x) {
    t6_vec_normalize(row(matrix, 0), x);  // first axis: the given x direction
    ortho(row(matrix, 2), row(matrix, 2), row(matrix, 0));  // third axis turned square to x
    t6_vec_cross(row(matrix, 1), row(matrix, 2), row(matrix, 0));  // second axis: square to both
    matrix->m[1][3] = matrix->m[2][3];
}

void t6_mat_rotation_product(T6Mat4 *matrix, const T6Mat4 *left, const T6Mat4 *right) {
    static const float W[4] = {0, 0, 0, 1};
    T6Mat4 product = *right, left_rotation = *left;
    memcpy(product.m[3], W, sizeof W);  // clear the translation of both, only the turns multiply
    memcpy(left_rotation.m[3], W, sizeof W);
    t6_mat_multiply(&product, &left_rotation);  // right turn first, then the left
    memcpy(product.m[3], matrix->m[3], sizeof W);  // keep the translation the output already has
    *matrix = product;
}

void t6_mat_relative_rotation(T6Mat4 *matrix, const T6Mat4 *rotation, const T6Mat4 *base) {
    T6Mat4 inverse = *base;
    t6_mat_inverse(&inverse);  // undo the base
    t6_mat_rotation_product(matrix, rotation, &inverse);  // the rotation measured from the base
}

typedef void Rotate(T6Mat4 *, int32_t);

// matrix = R0 * R1 * R2 on the matrix stack, keeping the matrix translation
static void euler(T6Mat4 *matrix, Rotate *const rotations[3], const float angles[3]) {
    float translation[3] = {matrix->m[3][0], matrix->m[3][1], matrix->m[3][2]};  // remember the translation
    t6_mat_identity(matrix);
    for (int step = 0; step < 3; step++) {  // apply the three turns in order
        T6Mat4 turn;
        t6_mat_identity(&turn);
        rotations[step](&turn, t6_rad_to_angle_round(angles[step]));
        t6_mat_multiply(&turn, matrix);
        *matrix = turn;
    }
    memcpy(matrix->m[3], translation, sizeof translation);  // put the translation back
}

void t6_mat_euler_zyx(T6Mat4 *matrix, const float angles[3]) {
    euler(matrix, (Rotate *const[3]){t6_mat_rotate_z, t6_mat_rotate_y, t6_mat_rotate_x},  // z first, then y, then x
          (const float[3]){angles[2], angles[1], angles[0]});
}

void t6_mat_euler_xyz(T6Mat4 *matrix, const float angles[3]) {
    euler(matrix, (Rotate *const[3]){t6_mat_rotate_x, t6_mat_rotate_y, t6_mat_rotate_z}, angles);  // x first, then y, then z
}
