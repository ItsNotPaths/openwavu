// Skeleton ("bon", model section 12): 141 bones, parent, translation, euler (R = Rz*Ry*Rx), scale.
// Bones 0..22 are the animated body; the rest are helpers. No bone names in the file. data.md §6.1.
package tk5_formats

BON_VERSION :: 0x32

Bone :: struct {
	parent:      i32,  // -1: root
	translation: [3]f32,  // already multiplied by scale
	euler:       [3]f32,
}

Skeleton :: struct {
	scale: f32,
	bones: []Bone,
	list:  []u32,  // per bone from 111 up, its MOP record id
	ends:  []f32,  // end point offsets (sim skel.c END_POINT), to the section end
}

// u16 version, u16 count, f32 scale, u32 offsets (from the bon start) of parent, trans, euler, list, ends.
read_skeleton :: proc(section: []byte, allocator := context.allocator) -> (s: Skeleton, ok: bool) {
	if len(section) < 0x1c || le_u16(section, 0) != BON_VERSION do return {}, false
	count := int(le_u16(section, 2))
	parents, trans, euler := int(le_u32(section, 0x08)), int(le_u32(section, 0x0c)), int(le_u32(section, 0x10))
	list, ends := int(le_u32(section, 0x14)), int(le_u32(section, 0x18))
	if max(parents + 4 * count, trans + 12 * count, euler + 12 * count, ends) > len(section) do return {}, false

	s.scale = le_f32(section, 4)
	s.bones = make([]Bone, count, allocator)
	for &b, i in s.bones {
		b.parent = le_i32(section, parents + 4 * i)
		for k in 0 ..< 3 {
			b.translation[k] = le_f32(section, trans + 12 * i + 4 * k)
			b.euler[k] = le_f32(section, euler + 12 * i + 4 * k)
		}
	}
	if list != 0 {
		n := int(le_u32(section, list))
		if list + 4 + 4 * n > len(section) do return {}, false
		s.list = make([]u32, n, allocator)
		for &v, i in s.list do v = le_u32(section, list + 4 + 4 * i)
	}
	if ends != 0 {
		s.ends = make([]f32, (len(section) - ends) / 4, allocator)
		for &v, i in s.ends do v = le_f32(section, ends + 4 * i)
	}
	return s, true
}
