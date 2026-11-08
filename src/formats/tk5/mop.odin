// Swing joint values ("MOP", model section 13 block 0): one record per joint from bone 111 up, found by the id the
// costume bon lists for it, and the shapes the records keep out of. data.md §6.6.
package tk5_formats

MOP_SHAPES_END :: 0xffffffff
MOP_SHAPE_WORDS :: 15
MOP_RECORD_WORDS :: 14

Mop_Shape :: struct {
	kind:     u32,  // 1: ellipsoid on body bone target, 5: rope to record id target
	target:   i32,
	rotation: [3]f32,  // radians
	centre:   [3]f32,  // mm, in the target bone's frame
	size:     [3]f32,  // mm; rope: rest distance, strength
}

Mop_Record :: struct {
	gravity, drag, stiffness, reach: f32,  // reach in mm
	angle_a, angle_b:                [2]f32,  // high, low; radians
	flags:                           u16,
	shapes:                          []u32,  // indices into Mop.shapes
}

Mop :: struct {
	shapes:  []Mop_Shape,
	records: map[u32]Mop_Record,  // by id
}

// "MOP" + version, shape rows while word 0 is 0, 0xffffffff, record rows (14 words + shape indices) while word 0 is 0.
read_mop :: proc(block: []byte, allocator := context.allocator) -> (mop: Mop, ok: bool) {
	if len(block) < 8 || string(block[:3]) != "MOP" do return {}, false
	shapes := make([dynamic]Mop_Shape, allocator)
	mop.records = make(map[u32]Mop_Record, allocator = allocator)
	position := 4
	for position + 4 * MOP_SHAPE_WORDS <= len(block) && le_u32(block, position) == 0 {
		shape := Mop_Shape{kind = le_u32(block, position + 4), target = le_i32(block, position + 8)}
		for k in 0 ..< 3 {
			shape.rotation[k] = le_f32(block, position + 12 + 4 * k)
			shape.centre[k] = le_f32(block, position + 28 + 4 * k)
			shape.size[k] = le_f32(block, position + 44 + 4 * k)
		}
		append(&shapes, shape)
		position += 4 * MOP_SHAPE_WORDS
	}
	mop.shapes = shapes[:]
	if position + 4 > len(block) || le_u32(block, position) != MOP_SHAPES_END do return mop, len(block) == 16  // v1: a stub
	position += 4
	for position + 4 * MOP_RECORD_WORDS <= len(block) && le_u32(block, position) == 0 {
		word := le_u32(block, position + 0x30)
		count := int(le_u32(block, position + 0x34))
		if position + 4 * (MOP_RECORD_WORDS + count) > len(block) do return mop, false
		record := Mop_Record{
			gravity = le_f32(block, position + 4),
			drag = le_f32(block, position + 8),
			stiffness = le_f32(block, position + 12),
			reach = le_f32(block, position + 16),
			angle_a = {le_f32(block, position + 20), le_f32(block, position + 24)},
			angle_b = {le_f32(block, position + 28), le_f32(block, position + 32)},
			flags = u16(word),
			shapes = make([]u32, count, allocator),
		}
		for &shape, k in record.shapes do shape = le_u32(block, position + 4 * (MOP_RECORD_WORDS + k))
		mop.records[word >> 16] = record
		position += 4 * (MOP_RECORD_WORDS + count)
	}
	return mop, true
}
