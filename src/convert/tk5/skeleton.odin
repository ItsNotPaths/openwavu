// The sim's two skeletons in body slot order, from the bon (tk5decomp src/sim/skel.c t5_skeleton_load_a, _b).
package tk5_convert

import "../../db"
import formats "../../formats/tk5"

// Skeleton A slots (sim bones.h): 0..21 body bones, 22..26 end points, then helpers.
BONE_HIPS :: 0
BONE_SPINE :: 1
BONE_HEAD :: 4
BONE_PELVIS :: 13
BONE_R_FOOT :: 16
BONE_R_TOE :: 17
BONE_L_FOOT :: 20
BONE_L_TOE :: 21
BONE_HEAD_END :: 22

BON_BONES_A :: 111
BON_BONES_B :: 23  // the first records of A

// bon record -> body slot; records 29, 30 land on 15, 19 again (A only)
@(rodata)
SLOT_A := [BON_BONES_A]i8{
	-1, 0, 1, 2, 13, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 18, 19, 20, 17, 21, -1, -1, -1, -1, -1, -1, 15, 19,
	27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 46, 45, 47, 48, 50, 49, 51, 52, 53, 54,
	55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82,
	83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106,
}

// End points 22..26: parent slot, axis and bon ends[] entry of their offset (times the bon scale).
End_Point :: struct {parent, axis, end: i8}
@(rodata)
END_POINTS := [5]End_Point{{BONE_HEAD, 2, 0}, {BONE_R_FOOT, 0, 1}, {BONE_R_TOE, 1, 3}, {BONE_L_FOOT, 0, 2}, {BONE_L_TOE, 1, 4}}

// Parent -1: the root. B keeps its own translations and takes its turns from A.
Sim_Skeleton :: struct {
	scale:         f32,
	parent_a:      [BONES_A]i8,
	euler:         [BONES_A][3]f32,  // radians, m = Rx Ry Rz
	translation:   [BONES_A][3]f32,
	parent_b:      [BONES_B]i8,
	translation_b: [BONES_B][3]f32,
}

sim_skeleton :: proc(bon: formats.Skeleton) -> (s: Sim_Skeleton, ok: bool) {
	if len(bon.bones) < BON_BONES_A || len(bon.ends) < len(END_POINTS) do return
	s.scale = bon.scale
	for e, i in END_POINTS {
		slot := BONE_HEAD_END + i
		s.parent_a[slot], s.parent_b[slot] = e.parent, e.parent
		s.translation[slot][e.axis] = bon.scale * bon.ends[e.end]
		s.translation_b[slot] = s.translation[slot]
	}
	for record in 1 ..< BON_BONES_A {
		slot, parent := SLOT_A[record], bon.bones[record].parent
		if parent < 0 || int(parent) >= BON_BONES_A do return {}, false
		if slot < 0 do continue
		s.parent_a[slot] = SLOT_A[parent]
		s.translation[slot] = bon.bones[record].translation
		s.euler[slot] = bon.bones[record].euler
		if record < BON_BONES_B {
			s.parent_b[slot] = SLOT_A[parent]
			s.translation_b[slot] = bon.bones[record].translation
		}
	}
	s.parent_a[BONE_HIPS] = -1
	s.parent_b[BONE_SPINE], s.parent_b[BONE_PELVIS] = BONE_HIPS, BONE_HIPS
	return s, true
}

write_skeleton_rows :: proc(w: ^db.Writer, char: string, s: Sim_Skeleton) {
	db.insert(w, "skeleton", char, f64(s.scale))
	for t, slot in s.translation {
		e := s.euler[slot]
		db.insert(w, "skeleton_a", char, i64(slot), i64(s.parent_a[slot]), f64(t.x), f64(t.y), f64(t.z), f64(e.x), f64(e.y), f64(e.z))
	}
	for t, slot in s.translation_b {
		db.insert(w, "skeleton_b", char, i64(slot), i64(s.parent_b[slot]), f64(t.x), f64(t.y), f64(t.z))
	}
}
