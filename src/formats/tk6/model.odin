// Character models: big endian section containers, sections TEXTURES (NTP3), MESHES (NDP3), BONES ("BONE"), the same
// NTP3 and NDP3 as TK5. tk6decomp docs/data.md "Character models".
package tk6_formats

import tk5 "../tk5"

MODEL_TEXTURES :: 0
MODEL_MESHES :: 1
MODEL_BONES :: 2
// Poly material slots that hold materials; the fourth points at other data in TK6 models.
MATERIAL_SLOTS :: 3

// u32 count, {u32 offset, u32 size}[count], big endian (TK5's containers are little endian).
sections :: proc(data: []byte, allocator := context.allocator) -> (out: [][]byte, ok: bool) {
	if len(data) < 4 do return
	count := int(tk5.be_u32(data, 0))
	if count > len(data) / 8 do return
	out = make([][]byte, count, allocator)
	for &section, index in out {
		offset, size := int(tk5.be_u32(data, 4 + 8 * index)), int(tk5.be_u32(data, 8 + 8 * index))
		if offset + size > len(data) do return nil, false
		section = data[offset:][:size]
	}
	return out, true
}

BONE_HEADER :: 0x40
BONE_END_POINTS :: 5  // head, right foot, left foot, right toe, left toe, as the TK5 bon's ends

// "BONE", u32 1, u32 0x64, u32, then the TK5 bon fields in little endian: u32 count, f32 scale, u32 offsets (from the
// BONE start) of parent, translation, euler, list, end points, then two tables not read.
read_bone :: proc(section: []byte, allocator := context.allocator) -> (skeleton: tk5.Skeleton, ok: bool) {
	if len(section) < BONE_HEADER || string(section[:4]) != "BONE" do return
	count := int(tk5.le_u32(section, 0x10))
	parents, translations, eulers := int(tk5.le_u32(section, 0x18)), int(tk5.le_u32(section, 0x1c)), int(tk5.le_u32(section, 0x20))
	ends := int(tk5.le_u32(section, 0x28))
	if max(parents + 4 * count, translations + 12 * count, eulers + 12 * count, ends + 4 * BONE_END_POINTS) > len(section) do return
	skeleton.scale = tk5.le_f32(section, 0x14)
	skeleton.bones = make([]tk5.Bone, count, allocator)
	for &bone, index in skeleton.bones {
		bone.parent = tk5.le_i32(section, parents + 4 * index)
		for axis in 0 ..< 3 {
			bone.translation[axis] = tk5.le_f32(section, translations + 12 * index + 4 * axis)
			bone.euler[axis] = tk5.le_f32(section, eulers + 12 * index + 4 * axis)
		}
	}
	skeleton.ends = make([]f32, BONE_END_POINTS, allocator)
	for &end, index in skeleton.ends do end = tk5.le_f32(section, ends + 4 * index)
	return skeleton, true
}
