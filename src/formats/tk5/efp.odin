// Effects (tk5decomp docs/effects.md): EFP record tables and element packages, little endian.
// Shared: entry 0025 (sparks), 0026 (dust), elements in 0024. A character's group slot +2 holds the hit table, its EFP and
// its own element package.
package tk5_formats

EFFECT_ELEMENTS :: 24
EFFECT_SPARKS :: 25
EFFECT_DUST :: 26
GROUP_EFFECTS :: 2
EFP_RECORD_SIZE :: 128
SHARED_ELEMENTS :: 0x61  // element ids below are the shared package's blocks

Efp_Record :: struct {
	kind:             u32,
	color:            [3]u8,  // 128 = 1.0
	element:          int,
	blend:            u8,
	flags:            u8,     // 1 baked tracks, 2 random start, 4 sphere direction, 0x40 no hit direction
	spread:           [3]i16,  // times 0.01
	opacity:          i16,    // 128 = 1.0
	size:             u16,    // quad half side, mm
	depth_bias:       i16,
	count, life:      i16,    // life: ticks
	box:              [3]u8,
	end_opacity:      i16,
	end_size:         u16,
	speed:            i16,    // times 0.1
	speed_jitter:     u8,     // times 0.02 of speed
	cone:             u8,     // times tau / 100
	life_jitter:      u8,     // ticks
	size_jitter:      u8,     // times 0.02 of size
	follow_disabled:  u8,     // kind 15: nonzero keeps the spawn point
}

EFP_TRACKS :: 1
EFP_RANDOM_START :: 2
EFP_SPHERE :: 4

Element_Block :: struct {
	textures: []u32,  // NTP3 hash per flipbook frame
	mesh:     int,    // offset in the keyframe section, -1 = none
}

Element_Package :: struct {
	blocks:    []Element_Block,
	keyframes: []byte,
	textures:  []byte,  // NTP3
}

// One particle of a baked mesh, one key per tick: position offset, scale, alpha.
Efp_Track :: struct {
	positions: [][3]i16,
	scales:    []f32,
	alphas:    []f32,
}

// One row of a character's hit table (section 0 of its effect file).
Effect_Row :: struct {
	records:   u32,  // bit n: record n
	sound_row: i32,  // -1: none
	light:     bool, // record 0's colour lights the hit point
}

EFFECT_ROWS :: 16

read_effect_rows :: proc(data: []byte) -> (rows: [EFFECT_ROWS]Effect_Row, ok: bool) {
	if len(data) < EFFECT_ROWS * 16 do return
	for &row, index in rows {
		at := index * 16
		row = {records = le_u32(data, at), sound_row = le_i32(data, at + 4), light = le_u32(data, at + 12) & 1 == 0}
	}
	return rows, true
}

read_efp :: proc(data: []byte, allocator := context.allocator) -> (records: []Efp_Record, ok: bool) {
	if len(data) < 16 || string(data[:4]) != "EFP\x00" || le_u16(data, 12) != EFP_RECORD_SIZE do return
	count := min(int(le_u16(data, 14)), (len(data) - 16) / EFP_RECORD_SIZE)
	records = make([]Efp_Record, count, allocator)
	for &record, index in records {
		bytes := data[16 + index * EFP_RECORD_SIZE:][:EFP_RECORD_SIZE]
		element := int(le_i16(bytes, 0x08))
		record = {
			kind = le_u32(bytes, 0),
			color = {bytes[4], bytes[5], bytes[6]},
			element = element > 0x80 ? 0 : element,
			blend = bytes[0x0a],
			flags = bytes[0x0b],
			spread = {le_i16(bytes, 0x0c), le_i16(bytes, 0x0e), le_i16(bytes, 0x10)},
			opacity = le_i16(bytes, 0x12),
			size = le_u16(bytes, 0x16),
			depth_bias = le_i16(bytes, 0x18),
			count = le_i16(bytes, 0x1c),
			life = le_i16(bytes, 0x1e),
			box = {bytes[0x20], bytes[0x21], bytes[0x22]},
			end_opacity = le_i16(bytes, 0x24),
			end_size = le_u16(bytes, 0x26),
			speed = le_i16(bytes, 0x28),
			speed_jitter = bytes[0x2a],
			cone = bytes[0x2d],
			life_jitter = bytes[0x2e],
			size_jitter = bytes[0x30],
			follow_disabled = bytes[0x34],
		}
	}
	return records, true
}

// Header: block count, texture count, keyframe section offset, NTP3 offset; blocks from 0x10: frame count, mesh offset,
// then per frame a texture hash and its width and height.
read_element_package :: proc(data: []byte, allocator := context.allocator) -> (package_: Element_Package, ok: bool) {
	if len(data) < 16 do return
	block_count, keyframes, textures := int(le_u32(data, 0)), int(le_u32(data, 8)), int(le_u32(data, 12))
	if keyframes > len(data) || textures > len(data) || keyframes > textures do return
	package_ = {
		blocks = make([]Element_Block, block_count, allocator),
		keyframes = data[keyframes:textures],
		textures = data[textures:],
	}
	at := 16
	for &block in package_.blocks {
		if at + 8 > len(data) do return package_, false
		frames := int(le_u32(data, at))
		if at + 8 + frames * 8 > len(data) do return package_, false
		block.mesh = int(le_i32(data, at + 4))
		block.textures = make([]u32, frames, allocator)
		for &hash, frame in block.textures do hash = le_u32(data, at + 8 + frame * 8)
		at += 8 + frames * 8
	}
	return package_, true
}

// The baked particles of a mesh: version 2, animation 0, 3 entries per particle (4 for kinds 12, 13, whose roll is unused).
read_efp_tracks :: proc(keyframes: []byte, mesh: int, allocator := context.allocator) -> (tracks: []Efp_Track, ok: bool) {
	if mesh < 0 || mesh + 12 > len(keyframes) || le_u16(keyframes, mesh) != 2 do return
	entries, particles := int(le_u16(keyframes, mesh + 4)), int(le_u16(keyframes, mesh + 6))
	if particles == 0 || entries % particles != 0 do return
	per_particle := entries / particles
	animation_count := int(le_u16(keyframes, mesh + 2))
	animation := mesh + int(le_u32(keyframes, mesh + 8) &~ 1)
	if animation_count == 0 || animation + 2 > len(keyframes) do return
	frames := int(le_u16(keyframes, animation))
	if animation + 2 + frames * entries * 6 > len(keyframes) do return
	tracks = make([]Efp_Track, particles, allocator)
	for &track, particle in tracks {
		track.positions = make([][3]i16, frames, allocator)
		track.scales = make([]f32, frames, allocator)
		track.alphas = make([]f32, frames, allocator)
		for frame in 0 ..< frames {
			at := animation + 2 + (frame * entries + particle * per_particle) * 6
			track.positions[frame] = {le_i16(keyframes, at), le_i16(keyframes, at + 2), le_i16(keyframes, at + 4)}
			track.scales[frame] = f32(le_i16(keyframes, at + 8)) * 0.01
			track.alphas[frame] = f32(le_i16(keyframes, at + 12)) * 0.001
		}
	}
	return tracks, true
}
