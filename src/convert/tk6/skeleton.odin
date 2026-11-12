// The sim's skeletons and the glb skeleton from a TK6 "BONE" (formats/tk6 read_bone). Its records are TK5's bon records
// 1.. (the TK5 root record is gone), so record n is TK5 record n + 1 [likely: parents and bind values of the 22 body
// bones match TK5 Kazuya's; tk6decomp docs/data.md "Character models"].
package tk6_convert

import tk5_convert "../tk5"
import tk5 "../../formats/tk5"

BODY_RECORDS :: 22
HELPER_TIE_MARGIN :: 1  // mm; a helper halfway along a limb stays on its own bone
@(rodata)
BODY_SLOT := [BODY_RECORDS]i8{0, 1, 2, 13, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 18, 19, 20, 17, 21}

FIRST_FINGER_RECORD :: 75  // 75..89 the right fingers, 90..104 the left, in hand bank joint order
FIRST_FINGER_SLOT :: 51    // TK5's A slots 51..80, same order
FINGER_RECORDS :: 30

// Body and finger bones and end points; the other helper slots stay empty [open: face, twist, hair].
// The hips' bind translation is the standing hip height, which the anims carry: the sim's hips start at 0, as TK5's.
sim_skeleton :: proc(bone: tk5.Skeleton) -> (out: tk5_convert.Sim_Skeleton, ok: bool) {
	if len(bone.bones) < FIRST_FINGER_RECORD + FINGER_RECORDS || len(bone.ends) < len(tk5_convert.END_POINTS) do return
	out.scale = bone.scale
	for record in 0 ..< BODY_RECORDS {
		slot, parent := BODY_SLOT[record], bone.bones[record].parent
		if parent >= BODY_RECORDS do return
		parent_slot := parent < 0 ? -1 : BODY_SLOT[parent]
		translation := record == 0 ? [3]f32{} : bone.bones[record].translation
		out.parent_a[slot], out.parent_b[slot] = parent_slot, parent_slot
		out.translation[slot], out.translation_b[slot] = translation, translation
		out.euler[slot] = bone.bones[record].euler
	}
	for record in FIRST_FINGER_RECORD ..< FIRST_FINGER_RECORD + FINGER_RECORDS {
		slot := FIRST_FINGER_SLOT + record - FIRST_FINGER_RECORD
		out.parent_a[slot], out.translation[slot] = mapped_parent(bone, record) or_return
		out.euler[slot] = bone.bones[record].euler
	}
	for end, index in tk5_convert.END_POINTS {
		slot := tk5_convert.BONE_HEAD_END + index
		out.parent_a[slot], out.parent_b[slot] = end.parent, end.parent
		out.translation[slot][end.axis] = bone.scale * bone.ends[end.end]
		out.translation_b[slot] = out.translation[slot]
	}
	return out, true
}

// A slot of a body or finger record, else -1.
record_slot :: proc(record: int) -> i8 {
	if record >= 0 && record < BODY_RECORDS do return BODY_SLOT[record]
	if record >= FIRST_FINGER_RECORD && record < FIRST_FINGER_RECORD + FINGER_RECORDS {
		return i8(FIRST_FINGER_SLOT + record - FIRST_FINGER_RECORD)
	}
	return -1
}

// The nearest mapped parent's slot and the record's translation from it. Unmapped helpers between them (the little
// fingers' KO_*_BASE) must not turn, so their translations add up.
mapped_parent :: proc(bone: tk5.Skeleton, record: int) -> (slot: i8, translation: [3]f32, ok: bool) {
	translation = bone.bones[record].translation
	parent := int(bone.bones[record].parent)
	for parent >= 0 && record_slot(parent) < 0 {
		helper := bone.bones[parent]
		if helper.euler != {} do return
		translation += helper.translation
		parent = int(helper.parent)
	}
	if parent < 0 do return
	return record_slot(parent), translation, true
}

// The skeleton with a root joint in front, so glb joints 1..22 are the body bones as in a TK5 part (the presenter poses
// them by that order). Mesh joints move up by one to match.
glb_skeleton :: proc(bone: tk5.Skeleton, meshes: []tk5.Mesh, allocator := context.allocator) -> (out: tk5.Skeleton) {
	out = bone
	out.tie_margin = HELPER_TIE_MARGIN
	out.bones = make([]tk5.Bone, len(bone.bones) + 1, allocator)
	out.bones[0].parent = -1
	for record, index in bone.bones {
		out.bones[index + 1] = record
		out.bones[index + 1].parent = record.parent + 1
	}
	for &mesh in meshes {
		if mesh.single_bind >= 0 do mesh.single_bind += 1
		for poly in mesh.polys do for &joints in poly.joints do joints += 1
	}
	return
}
