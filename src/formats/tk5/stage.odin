// Stages: 21-section file at entry 2132 + 3*id. Walls from MHO (section 15), floor zones from
// UNDN (section 17). Little endian, file units (mm). tk5decomp docs/stages.md.
package tk5_formats

import "core:math"

STAGE_FIRST :: 2132
STAGE_COUNT :: 38
STAGE_SECTIONS :: 21
STAGE_MESHES :: 2  // container of NDP3, one MIF record each in STAGE_NODES
STAGE_NODES :: 3
STAGE_MHO :: 15
STAGE_UNDN :: 17
WALL_MIN_HEIGHT :: 50  // FUN_000384a8 drops lower quads

// stages.md §2. "": no name known.
STAGE_NAMES := [STAGE_COUNT]string{
	"dragons_nest", "burning_temple", "waterfall", "urban_jungle", "city_at_sunset", "moonlit_wilderness",
	"pirates_cove", "secret_garden", "cathedral", "acid_rain", "polar_paradise", "hells_gate",
	"the_final_frontier", "poolside", "", "", "", "western_gate", "autumn_temple",
	"meteor_shower", "ghetto_pit", "city_lights", "great_plains", "galleon", "all_hallows_eve", "winter_palace",
	"festival", "aurora_australis", "heavens_gate", "space_colony", "pool_party", "playroom", "wolves_den",
	"industrial_complex", "ominous_mist", "inferno", "ground_zero", "final_stage",
}

Stage_Quad :: struct {
	object:  int,  // MHO object index
	link:    i32,  // stage object id (breakable prop), -1 = none
	corners: [4][3]f32,
	normal:  [3]f32,  // a wall normal points into the arena
	is_wall: bool,    // not flat and at least WALL_MIN_HEIGHT high
}

Floor_Polygon :: struct {
	centre:    [3]f32,
	radius_sq: f32,
	normal:    [3]f32,
	points:    [][3]f32,
}

Floor_Zone :: struct {
	centre:    [3]f32,
	radius_sq: f32,
	flags:     u32,  // bit 0: floor height source, 0x4..0x800: ground kind
	polygons:  []Floor_Polygon,
}

Stage :: struct {
	sections: [][]byte,  // all 21, raw
	quads:    []Stage_Quad,
	floors:   []Floor_Zone,
}

read_stage :: proc(data: []byte, allocator := context.allocator) -> (s: Stage, ok: bool) {
	s.sections = sections(data, allocator) or_return
	if len(s.sections) != STAGE_SECTIONS do return {}, false
	s.quads = read_mho(s.sections[STAGE_MHO], allocator) or_return
	s.floors = read_undn(s.sections[STAGE_UNDN], allocator) or_return
	return s, true
}

@(private = "file")
vec3_le :: proc(d: []byte, off: int) -> [3]f32 {
	return {le_f32(d, off), le_f32(d, off + 4), le_f32(d, off + 8)}
}

// Object types 3 and 9 hold quads, the only types the wall solve (FUN_00039964) tests.
@(private = "file")
read_mho :: proc(d: []byte, allocator := context.allocator) -> (quads: []Stage_Quad, ok: bool) {
	if len(d) < 0x98 do return nil, true
	out := make([dynamic]Stage_Quad, allocator)
	obj_count, obj_off := int(le_u32(d, 0x34)), int(le_u32(d, 0x38))
	for i in 0 ..< obj_count {
		o := obj_off + 0x60 * i
		if o + 0x60 > len(d) do return nil, false
		kind, data, link := le_u32(d, o + 0x40), int(le_u32(d, o + 0x44)), le_i32(d, o + 0x58)
		if kind != 3 && kind != 9 do continue
		head := kind == 3 ? 0x10 : 0  // 3: {.., +0x10 count, +0x20 quads}; 9: {+0 count, +0x10 quads}
		if data + head + 4 > len(d) do return nil, false
		n := int(le_u32(d, data + head))
		for k in 0 ..< n {
			q := data + head + 0x10 + 0x50 * k
			if q + 0x50 > len(d) do return nil, false
			quad := Stage_Quad{object = i, link = link, normal = vec3_le(d, q + 0x40)}
			for &c, j in quad.corners do c = vec3_le(d, q + 0x10 * j)
			quad.is_wall = is_wall(quad)
			append(&out, quad)
		}
	}
	return out[:], true
}

@(private = "file")
is_wall :: proc(q: Stage_Quad) -> bool {
	lo, hi := q.corners[0].y, q.corners[0].y
	for c in q.corners {
		lo, hi = min(lo, c.y), max(hi, c.y)
	}
	return math.hypot(q.normal.x, q.normal.z) > 1e-3 && hi - lo >= WALL_MIN_HEIGHT
}

// Record: centre, r², flags, polygon count, record size, polygons.
// Polygon: centre, r², normal, n, n vec4 points.
@(private = "file")
read_undn :: proc(d: []byte, allocator := context.allocator) -> (zones: []Floor_Zone, ok: bool) {
	if len(d) < 0x38 do return nil, true
	count, off := int(le_u32(d, 0x30)), int(le_u32(d, 0x34))
	zones = make([]Floor_Zone, count, allocator)
	for &z in zones {
		if off + 0x20 > len(d) do return nil, false
		z.centre, z.radius_sq = vec3_le(d, off), le_f32(d, off + 0x0c)
		z.flags = le_u32(d, off + 0x10)
		z.polygons = make([]Floor_Polygon, le_u32(d, off + 0x14), allocator)
		p := off + 0x20
		for &poly in z.polygons {
			if p + 0x20 > len(d) do return nil, false
			poly.centre, poly.radius_sq, poly.normal = vec3_le(d, p), le_f32(d, p + 0x0c), vec3_le(d, p + 0x10)
			n := int(le_u32(d, p + 0x1c))
			if p + 0x20 + 0x10 * n > len(d) do return nil, false
			poly.points = make([][3]f32, n, allocator)
			for &pt, k in poly.points do pt = vec3_le(d, p + 0x20 + 0x10 * k)
			p += 0x20 + 0x10 * n
		}
		off += int(le_u32(d, off + 0x18))
	}
	return zones, true
}

// MIF node (stage sections 3, 5): one 0xc0 record per mesh of the matching NDP3.
Mif_Node :: struct {
	name:   string,
	transform: [16]f32,  // row vectors, file units
}

// u32 at 0x10 count, 0x14 record offset, 0x18 name table; record +0 name offset, +0x10 matrix.
read_mif_nodes :: proc(d: []byte, allocator := context.allocator) -> (nodes: []Mif_Node, ok: bool) {
	if len(d) < 0x1c do return nil, false
	count, off, names := int(le_u32(d, 0x10)), int(le_u32(d, 0x14)), int(le_u32(d, 0x18))
	if off + count * 0xc0 > len(d) do return nil, false
	nodes = make([]Mif_Node, count, allocator)
	for &n, i in nodes {
		r := off + i * 0xc0
		n.name = cstring_at(d, names + int(le_u32(d, r)))
		for &v, k in n.transform do v = le_f32(d, r + 0x10 + k * 4)
	}
	return nodes, true
}
