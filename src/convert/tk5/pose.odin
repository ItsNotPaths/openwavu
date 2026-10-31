// DUPLICATE of the sim's pose path (tk5decomp src/sim/skel.c, vec.c, quat.c, math.c, the anim.c sampler), kept only to
// measure body.head_top at import. Copied line for line; when the sim changes, change this too.
package tk5_convert

import "base:intrinsics"
import "core:math"
import formats "../../formats/tk5"

@(private = "file")
Mat4 :: [4][4]f32  // m[row][column], row vectors: world = local * parent world
@(private = "file")
Vec4 :: [4]f32

IDLE_STAND_ALIAS :: 1

// Skeleton A slots (sim bones.h): 0..21 body bones, 22 the head end point.
@(private = "file")
BONE_SPINE :: 1
@(private = "file")
BONE_CHEST :: 2
@(private = "file")
BONE_HEAD :: 4
@(private = "file")
BONE_PELVIS :: 13
@(private = "file")
BONE_R_TOE :: 17
@(private = "file")
BONE_L_TOE :: 21
@(private = "file")
BONE_HEAD_END :: 22
@(private = "file")
POSE_BONES :: 22
@(private = "file")
CHANNEL_TRUNK_POINT :: 6

// bon record -> body slot (skel.c SLOT_A, first 23 records; the rest are helpers past the head end)
@(private = "file", rodata)
SLOT_A := [23]i8{-1, 0, 1, 2, 13, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 18, 19, 20, 17, 21}
// body slot of channels 3..22 (skel.c CHANNEL_SLOT)
@(private = "file", rodata)
CHANNEL_SLOT := [formats.CHANNELS]i8{-1, -1, -1, 0, 1, 13, -1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 18, 19, 20}

@(private = "file")
TRUNK_SIDE :: f32(130)
@(private = "file")
TRUNK_UP :: f32(400)

@(private = "file")
Skeleton_A :: struct {
	parent:      [BONE_HEAD_END + 1]i8,
	euler:       [BONE_HEAD_END + 1][3]f32,
	translation: [BONE_HEAD_END + 1][3]f32,
}

// Height of the head end point in the standing idle, mm: the mean over the loop of the sim's pose without the look-at
// (tk5decomp tools/body.py head_top). The root takes the root and hip channels times the bon scale, as body.py does.
head_top :: proc(bon: formats.Skeleton, idle: formats.Anim) -> f32 {
	skeleton := skeleton_a(bon)
	sum: f64
	for keys in idle.values do sum += f64(head_end_height(&skeleton, bon.scale, keys))
	return f32(sum / f64(len(idle.values)))
}

// skel.c t5_skeleton_load_a, the slots up to the head end.
@(private = "file")
skeleton_a :: proc(bon: formats.Skeleton) -> (s: Skeleton_A) {
	s.parent[BONE_HEAD_END] = BONE_HEAD
	s.translation[BONE_HEAD_END][2] = bon.scale * bon.ends[0]
	for record in 1 ..< min(len(SLOT_A), len(bon.bones)) {
		slot := SLOT_A[record]
		s.parent[slot] = SLOT_A[bon.bones[record].parent]
		s.translation[slot] = bon.bones[record].translation
		s.euler[slot] = bon.bones[record].euler
	}
	s.parent[0] = -1
	return
}

@(private = "file")
head_end_height :: proc(s: ^Skeleton_A, scale: f32, keys: [formats.CHANNELS][3]f32) -> f32 {
	locals: [BONE_HEAD_END + 1]Mat4
	for &local, bone in locals {  // t5_rig_bind
		local = euler_xyz(identity(), s.euler[bone])
		local[3] = {s.translation[bone][0], s.translation[bone][1], s.translation[bone][2], 1}
	}
	pose := sample(keys)
	skel_pose(&locals, s, pose)
	root := identity()
	root[3][1] = (keys[0][1] + keys[1][1]) * scale
	worlds: [BONE_HEAD_END + 1]Mat4
	for bone in 0 ..= BONE_HEAD_END {  // t5_skel_world_a, then the head end
		parent := s.parent[bone] >= 0 ? worlds[s.parent[bone]] : root
		worlds[bone] = multiply(parent, locals[bone])
	}
	return worlds[BONE_HEAD_END][3][1]
}

// anim.c t5_anim_sample on a whole frame, keep_hips true (body.py does not level the hips).
@(private = "file")
sample :: proc(keys: [formats.CHANNELS][3]f32) -> (pose: [formats.CHANNELS]Vec4) {
	for channel in 0 ..< formats.CHANNELS {
		key := keys[channel]
		if formats.channel_is_rot(channel) do pose[channel] = key_quat({key[0], key[1], key[2], 0})
		else do pose[channel] = {key[0], key[1], key[2], 0}
	}
	pose[0][2] = -pose[0][2]
	pose[1][2] = -pose[1][2]
	return
}

// axis = row 2 of RotY(yaw) then RotX(pitch) on the matrix stack, angle = key z
@(private = "file")
key_quat :: proc(key: Vec4) -> Vec4 {
	m := identity()
	rotate(&m, 2, 0, rad_to_angle_round(key[1]))
	rotate(&m, 1, 2, rad_to_angle_round(key[0]))
	sine := sin(key[2] * 0.5)  // quat.c t5_quat_axis_angle
	turn := m[2] * sine
	turn[3] = math.sqrt(1 - sine * sine)
	return turn
}

// skel.c t5_skel_pose
@(private = "file")
skel_pose :: proc(locals: ^[BONE_HEAD_END + 1]Mat4, s: ^Skeleton_A, pose: [formats.CHANNELS]Vec4) {
	for channel in 3 ..< formats.CHANNELS do if CHANNEL_SLOT[channel] >= 0 do quat_to_mat(&locals[CHANNEL_SLOT[channel]], pose[channel])
	locals[BONE_CHEST] = euler_xyz(locals[BONE_CHEST], s.euler[BONE_CHEST])
	spine_and_chest(locals, pose[CHANNEL_TRUNK_POINT][0])
	locals[BONE_R_TOE] = euler_xyz(locals[BONE_R_TOE], s.euler[BONE_R_TOE])
	locals[BONE_L_TOE] = euler_xyz(locals[BONE_L_TOE], s.euler[BONE_L_TOE])
}

// skel.c spine_and_chest
@(private = "file")
spine_and_chest :: proc(locals: ^[BONE_HEAD_END + 1]Mat4, trunk_point: f32) {
	spine_before, pelvis := locals[BONE_SPINE], locals[BONE_PELVIS]
	pelvis_1 := point(pelvis, -TRUNK_SIDE, TRUNK_UP)
	pelvis_2 := point(pelvis, trunk_point, 0)
	spine_1 := point(spine_before, TRUNK_SIDE, -TRUNK_UP)
	spine_2 := point(spine_before, TRUNK_UP, 0)
	frame: Mat4
	frame_xy(&frame, spine_1 + pelvis_1, spine_2)
	frame_turn_x(&frame, pelvis_2 + spine_2)
	for row in 0 ..< 3 do locals[BONE_SPINE][row] = frame[row]

	base := point(locals[BONE_SPINE], TRUNK_SIDE, 0)
	x, y := spine_1 - base, spine_2 - base
	frame_xy(&frame, x, y)
	frame_turn_x(&frame, y)
	frame_xy(&locals[BONE_CHEST], frame[0], frame[1])
	locals[BONE_CHEST] = relative_rotation(locals[BONE_CHEST], locals[BONE_CHEST], locals[BONE_SPINE])
}

// --- vec.c

@(private = "file")
identity :: proc() -> Mat4 {return {{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}}}

@(private = "file")
point :: proc(frame: Mat4, x, y: f32) -> Vec4 {return times_mat({x, y, 0, 1}, frame)}

@(private = "file")
times_mat :: proc(v: Vec4, m: Mat4) -> (out: Vec4) {
	for column in 0 ..< 4 {
		out[column] = fmaf(v[3], m[3][column], fmaf(v[2], m[2][column], fmaf(v[0], m[0][column], v[1] * m[1][column])))
	}
	return
}

// VMX lanes: denormal inputs and results become signed zero.
@(private = "file")
ftz :: proc(x: f32) -> f32 {return abs(x) < math.F32_MIN ? math.copy_sign(f32(0), x) : x}
@(private = "file")
vfma :: proc(left, right, addend: f32) -> f32 {return ftz(fmaf(ftz(left), ftz(right), ftz(addend)))}
@(private = "file")
vmul :: proc(left, right: f32) -> f32 {return vfma(left, right, 0)}
@(private = "file")
vadd :: proc(left, right: f32) -> f32 {return ftz(ftz(left) + ftz(right))}
@(private = "file")
vsub :: proc(left, right: f32) -> f32 {return ftz(ftz(left) - ftz(right))}
@(private = "file")
vrefp :: proc(x: f32) -> f32 {return ftz(1 / ftz(x))}

// t5_mat_multiply(stack, factor): returns factor * stack.
@(private = "file")
multiply :: proc(stack, factor: Mat4) -> (result: Mat4) {
	for row in 0 ..< 4 {
		f := factor[row]
		for column in 0 ..< 4 {
			result[row][column] = vadd(vfma(stack[2][column], f[2], vmul(stack[0][column], f[0])),
			                           vfma(stack[3][column], f[3], vmul(stack[1][column], f[1])))
		}
	}
	return
}

// first' = first*cosine + second*sine, second' = second*cosine - first*sine
@(private = "file")
rotate :: proc(m: ^Mat4, first_row, second_row: int, angle: i32) {
	sine, cosine := fsin(angle_rad(angle), 0), fsin(angle_rad(angle), 1)
	for column in 0 ..< 4 {
		first, second := m[first_row][column], m[second_row][column]
		m[first_row][column] = vfma(first, cosine, vmul(second, sine))
		m[second_row][column] = vsub(vmul(second, cosine), vmul(first, sine))
	}
}

// t5_mat_euler_xyz: R0 * R1 * R2 on the stack, keeping the translation.
@(private = "file")
euler_xyz :: proc(m: Mat4, angles: [3]f32) -> Mat4 {
	translation := m[3]
	out := identity()
	for step in 0 ..< 3 {
		turn := identity()
		switch step {
		case 0: rotate(&turn, 1, 2, rad_to_angle_round(angles[0]))
		case 1: rotate(&turn, 2, 0, rad_to_angle_round(angles[1]))
		case 2: rotate(&turn, 0, 1, rad_to_angle_round(angles[2]))
		}
		out = multiply(turn, out)
	}
	out[3][0], out[3][1], out[3][2] = translation[0], translation[1], translation[2]
	return out
}

@(private = "file", rodata)
P1 := [3]int{1, 2, 0}
@(private = "file", rodata)
P2 := [3]int{2, 0, 1}
@(private = "file", rodata)
Q0 := [3]int{2, 1, 0}
@(private = "file", rodata)
Q1 := [3]int{1, 0, 2}
@(private = "file", rodata)
Q2 := [3]int{0, 2, 1}

@(private = "file")
cross_vmx :: proc(left, right: Vec4) -> (out: [3]f32) {
	for lane in 0 ..< 3 do out[lane] = vsub(vmul(left[P1[lane]], right[P2[lane]]), vmul(left[P2[lane]], right[P1[lane]]))
	return
}

// t5_mat_inverse: rows 0..2 the inverse of the 3x3 part, row 3 = (0,0,0,1) - translation * that inverse
@(private = "file")
inverse :: proc(rows: Mat4) -> (inv: Mat4) {
	positive, negative: [3]f32
	for r in 0 ..< 3 {
		positive[r] = vmul(rows[2][P2[r]], vmul(rows[1][P1[r]], rows[0][r]))
		negative[r] = vmul(rows[2][Q2[r]], vmul(rows[0][Q0[r]], rows[1][Q1[r]]))
	}
	negative_determinant := vsub(vadd(negative[0], vadd(negative[1], negative[2])), vadd(positive[0], vadd(positive[2], positive[1])))
	inverse_determinant := vrefp(negative_determinant)
	columns := [3][3]f32{cross_vmx(rows[1], rows[2]), cross_vmx(rows[2], rows[0]), cross_vmx(rows[0], rows[1])}
	for r in 0 ..< 3 {
		for c in 0 ..< 3 do inv[r][c] = vmul(columns[c][r], inverse_determinant)
		inv[r][3] = 0
	}
	W := [4]f32{0, 0, 0, 1}
	for c in 0 ..< 4 {
		inv[3][c] = vadd(W[c], vfma(inv[2][c], rows[3][2], vfma(inv[1][c], rows[3][1], vmul(inv[0][c], rows[3][0]))))
	}
	for r in 0 ..< 3 do for c in 0 ..< 4 do inv[r][c] = vsub(0, inv[r][c])
	return
}

// t5_mat_relative_rotation: the rotation measured from the base, keeping m's translation.
@(private = "file")
relative_rotation :: proc(m, rotation, base: Mat4) -> Mat4 {
	W := Vec4{0, 0, 0, 1}
	product, left := inverse(base), rotation
	product[3], left[3] = W, W
	product = multiply(product, left)
	product[3] = m[3]
	return product
}

@(private = "file")
dot3 :: proc(a, b: Vec4) -> f32 {return fmaf(a[2], b[2], fmaf(a[0], b[0], a[1] * b[1]))}

// t5_vec_cross: xyz only, w kept
@(private = "file")
cross :: proc(out: ^Vec4, a, b: Vec4) {
	x := fmaf(a[1], b[2], -(b[1] * a[2]))
	y := fmaf(a[2], b[0], -(b[2] * a[0]))
	z := fmaf(b[1], a[0], -(a[1] * b[0]))
	out[0], out[1], out[2] = x, y, z
}

@(private = "file")
normalize :: proc(v: Vec4) -> Vec4 {
	length := math.sqrt(fmaf(v[2], v[2], fmaf(v[0], v[0], v[1] * v[1])))
	out := v * (length == 0 ? 0 : 1 / length)
	out[3] = 0
	return out
}

@(private = "file")
ortho :: proc(v, unit: Vec4) -> Vec4 {return normalize(v - unit * dot3(v, unit))}

@(private = "file")
frame_xy :: proc(m: ^Mat4, x, y: Vec4) {
	m[0] = normalize(x)
	m[1] = ortho(y, m[0])
	cross(&m[2], m[0], m[1])
	m[2][3] = m[0][3]
}

@(private = "file")
frame_turn_x :: proc(m: ^Mat4, x: Vec4) {
	m[0] = normalize(x)
	m[2] = ortho(m[2], m[0])
	cross(&m[1], m[2], m[0])
	m[1][3] = m[2][3]
}

// --- quat.c t5_quat_to_mat: rows 0..2 and m[3][3]

@(private = "file")
quat_to_mat :: proc(m: ^Mat4, q: Vec4) {
	x, y, z, w := q[0], q[1], q[2], q[3]
	xx, yy, zz := x * x, y * y, z * z
	xy, xz, yz := x * y, x * z, y * z
	wx, wy, wz := w * x, w * y, w * z
	m[0] = {(1 - (yy + zz)) - (yy + zz), 2 * (xy - wz), 2 * (xz + wy), 0}
	m[1] = {2 * (xy + wz), (1 - (xx + zz)) - (xx + zz), 2 * (yz - wx), 0}
	m[2] = {2 * (xz - wy), 2 * (yz + wx), (1 - (xx + yy)) - (xx + yy), 0}
	m[3][3] = 1
}

// --- math.c

@(private = "file")
TWO_PI :: f32(6.28318548)

@(private = "file")
fmaf :: proc(a, b, c: f32) -> f32 {return intrinsics.fused_mul_add(a, b, c)}

@(private = "file")
fctiwz :: proc(v: f32) -> i32 {
	if v != v || v <= -2147483648.0 do return min(i32)
	if v >= 2147483648.0 do return max(i32)
	return i32(v)
}

@(private = "file")
rad_to_angle_round :: proc(radians: f32) -> i32 {return fctiwz((radians < 0 ? f32(-0.5) : 0.5) + radians * 65536 / TWO_PI)}

@(private = "file")
angle_rad :: proc(angle: i32) -> f32 {return f32(angle) * TWO_PI * (1.0 / 65536)}

@(private = "file")
sign_bit :: proc(v: f32) -> bool {return transmute(u32)v >> 31 != 0}

@(private = "file", rodata)
SINE_POLY := [4]f32{-3.59504375e-05, 0.00249000103, -0.0807454363, 0.785398185}
@(private = "file", rodata)
COSINE_POLY := [4]f32{-0.000318727834, 0.0158496834, -0.308424175, 0.99999994}

// t5_sin: octant reduction by 4/pi, two short polynomials
@(private = "file")
sin :: proc(angle: f32) -> f32 {
	if sign_bit(angle) do return -sin(-angle)
	scaled := angle * f32(1.27323949)
	index := fctiwz(scaled)
	fraction := scaled - f32(index)
	if index & 1 != 0 do fraction = 1 - fraction
	result: f32
	if (index + 1) & 2 == 0 {
		sum := fraction * SINE_POLY[0]
		sum = fmaf(fraction, sum, SINE_POLY[1])
		sum = fraction * sum
		sum = fmaf(fraction, sum, SINE_POLY[2])
		sum = fraction * sum
		sum = fmaf(fraction, sum, SINE_POLY[3])
		result = fraction * sum
	} else {
		sum := fraction * COSINE_POLY[0]
		sum = fmaf(fraction, sum, COSINE_POLY[1])
		sum = fraction * sum
		sum = fmaf(fraction, sum, COSINE_POLY[2])
		sum = fraction * sum
		result = fmaf(fraction, sum, COSINE_POLY[3])
	}
	return index & 7 > 3 ? -result : result
}

@(private = "file", rodata)
COSINE_TAIL := [3]f32{-0.00136022491, 0.0416566953, -0.499999017}
@(private = "file", rodata)
SINE_TAIL := [3]f32{-0.000195072702, 0.00833207555, -0.166666523}

// t5_fsin (Dinkumware _FSin): cosine_flag 0 sin, 1 cos
@(private = "file")
fsin :: proc(angle: f32, cosine_flag: i32) -> f32 {
	angle := angle
	word := transmute(u32)angle
	switch {
	case word & 0x7f800000 == 0x7f800000: return word & 0x007fffff != 0 ? angle : math.nan_f32()
	case word & 0x7fffffff == 0: return cosine_flag != 0 ? 1 : angle
	}
	if f64(angle) < -40.7 || f64(angle) > 40.7 do angle = math.mod(angle, TWO_PI)
	turns := angle * f32(0.636619747)
	quarter := fctiwz(turns > 0 ? turns + 0.5 : turns - 0.5)
	quadrant := (quarter & 3) + cosine_flag
	quarter_float := f32(quarter)
	angle = fmaf(quarter_float, -f32(1.57079625), angle)
	angle = fmaf(quarter_float, -f32(7.54979013e-08), angle)
	result: f32
	if angle > -f32(0.000244140625) && angle < f32(0.000244140625) {
		result = quadrant & 1 != 0 ? 1 : angle
	} else {
		squared := angle * angle
		if quadrant & 1 != 0 {
			result = fmaf(squared, fmaf(squared, fmaf(squared, COSINE_TAIL[0], COSINE_TAIL[1]), COSINE_TAIL[2]), 1)
		} else {
			result = fmaf(angle * squared, fmaf(squared, fmaf(squared, SINE_TAIL[0], SINE_TAIL[1]), SINE_TAIL[2]), angle)
		}
	}
	return quadrant & 2 != 0 ? -result : result
}
