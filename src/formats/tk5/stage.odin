// Stages: 21-section file at entry 2132 + 3*id. Wall quads from MHO (section 15), floor zones from
// UNDN (section 17), start points from sections 14 and 13, period and radius from the header (section 0, part 0).
// Little endian, file units (mm). tk5decomp docs/stages.md.
package tk5_formats


STAGE_FIRST :: 2132
STAGE_COUNT :: 38
STAGE_SECTIONS :: 21
STAGE_HEADER :: 0
STAGE_HEADER_VERSION :: 0x20050905
STAGE_MESHES :: 2  // container of NDP3, one MIF record each in STAGE_NODES
STAGE_LAYERS :: 6  // the NDP3s of STAGE_MESHES: sky, far scene, props (floor tiles when infinite), arena, extra, shadow
STAGE_NODES :: 3
STAGE_MHO :: 15
STAGE_UNDN :: 17
@(rodata)
STAGE_START_SECTIONS := [2]int{14, 13}  // the game's object slots 0 and 1

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
	link:    i32,  // stage object id (breakable prop), -1 = none
	corners: [4][3]f32,
	normal:  [3]f32,  // a wall normal points into the arena
}

// A start point: position and rotation vec4 of a record.
Start_Point :: [8]f32

Start_Group :: struct {
	id:         int,  // TKPD entry id, or the pair index of a POS section
	count:      int,  // records
	per_record: int,  // 1, or 2 for a double record
	points:     []Start_Point,
}

Start_Slot :: struct {
	pos_format: bool,  // "POS " (four pairs) or "TKPD" (entries by id)
	groups:     []Start_Group,
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
	quads:    []Stage_Quad,  // of object kinds 3 and 9, in object order
	floors:   []Floor_Zone,
	start:    [2]Start_Slot,
	period:   f32,  // the floor tile cell of an infinite stage
	radius:   f32,  // the floor patch kept around the focus; 0: a walled stage
}

read_stage :: proc(data: []byte, allocator := context.allocator) -> (s: Stage, ok: bool) {
	s.sections = sections(data, allocator) or_return
	if len(s.sections) != STAGE_SECTIONS do return {}, false
	read_mho(&s, s.sections[STAGE_MHO], allocator) or_return
	s.floors = read_undn(s.sections[STAGE_UNDN], allocator) or_return
	for &slot, k in s.start do slot = read_start(s.sections[STAGE_START_SECTIONS[k]], k, allocator) or_return
	header, _ := sections(s.sections[STAGE_HEADER], allocator)
	if len(header) > 0 && len(header[0]) >= 0x10 && le_u32(header[0], 0) == STAGE_HEADER_VERSION {
		s.period, s.radius = le_f32(header[0], 0x04), le_f32(header[0], 0x0c)
	}
	return s, true
}

@(private = "file")
vec3_le :: proc(d: []byte, off: int) -> [3]f32 {
	return {le_f32(d, off), le_f32(d, off + 4), le_f32(d, off + 8)}
}

// Object types 3 and 9 hold quads, the only types the wall solve (FUN_00039964) tests.
@(private = "file")
read_mho :: proc(s: ^Stage, d: []byte, allocator := context.allocator) -> (ok: bool) {
	if len(d) < 0x98 do return true
	out := make([dynamic]Stage_Quad, allocator)
	obj_count, obj_off := int(le_u32(d, 0x34)), int(le_u32(d, 0x38))
	for i in 0 ..< obj_count {
		o := obj_off + 0x60 * i
		if o + 0x60 > len(d) do return false
		kind, data, link := le_u32(d, o + 0x40), int(le_u32(d, o + 0x44)), le_i32(d, o + 0x58)
		if kind != 3 && kind != 9 do continue
		head := kind == 3 ? 0x10 : 0  // 3: {.., +0x10 count, +0x20 quads}; 9: {+0 count, +0x10 quads}
		if data + head + 4 > len(d) do return false
		n := int(le_u32(d, data + head))
		for k in 0 ..< n {
			q := data + head + 0x10 + 0x50 * k
			if q + 0x50 > len(d) do return false
			quad := Stage_Quad{link = link, normal = vec3_le(d, q + 0x40)}
			for &c, j in quad.corners do c = vec3_le(d, q + 0x10 * j)
			append(&out, quad)
		}
	}
	s.quads = out[:]
	return true
}

START_POINT_AT :: 0x30
START_SECOND_AT :: 0x90
TKPD_DOUBLE :: 0xe0  // entry size of a double record; the others are 0x80
TKPD_SINGLE :: 0x80
POS_PAIRS :: 4
POS_DOUBLE :: 0xd0   // record size of pair 0; the other pairs hold 0x70 and one point
POS_SINGLE :: 0x70
@(rodata)
TKPD_IDS := [2][]u32{{0, 1, 2, 12}, {3}}  // the entry ids the game reads, per slot

// Start points (tk5decomp tools/stage_start.py, docs/stages.md 5.6).
@(private = "file")
read_start :: proc(d: []byte, slot: int, allocator := context.allocator) -> (s: Start_Slot, ok: bool) {
	if len(d) < 4 do return
	groups := make([dynamic]Start_Group, allocator)
	switch string(d[:4]) {
	case "TKPD":
		if len(d) < 0x10 do return
		entries := int(le_u32(d, 0xc))
		if 0x20 + 16 * entries > len(d) do return
		for id in TKPD_IDS[slot] {
			for k in 0 ..< entries {
				e := 0x20 + 16 * k
				if le_u32(d, e) != id do continue
				size, count, offset := int(le_u32(d, e + 4)), int(le_u32(d, e + 8)), int(le_u32(d, e + 12))
				if size != TKPD_DOUBLE && size != TKPD_SINGLE do return
				g := Start_Group{int(id), count, size == TKPD_DOUBLE ? 2 : 1, nil}
				g.points = start_points(d, offset, size, g, allocator) or_return
				append(&groups, g)
				break  // the game takes the first entry with the id
			}
		}
	case "POS ":
		s.pos_format = true
		if 0x30 + 8 * POS_PAIRS > len(d) do return
		for k in 0 ..< POS_PAIRS {
			count, offset := int(le_u32(d, 0x30 + 8 * k)), int(le_u32(d, 0x34 + 8 * k))
			record := k == 0 ? POS_DOUBLE : POS_SINGLE
			g := Start_Group{k, count, k == 0 ? 2 : 1, nil}
			if offset != 0 do g.points = start_points(d, offset, record, g, allocator) or_return
			append(&groups, g)
		}
	case: return
	}
	s.groups = groups[:]
	return s, true
}

@(private = "file")
start_points :: proc(d: []byte, at, record: int, g: Start_Group, allocator := context.allocator) -> (points: []Start_Point, ok: bool) {
	points = make([]Start_Point, g.count * g.per_record, allocator)
	for i in 0 ..< g.count {
		for k in 0 ..< g.per_record {
			o := at + record * i + START_POINT_AT + (START_SECOND_AT - START_POINT_AT) * k
			if o + 32 > len(d) do return nil, false
			for &v, c in points[i * g.per_record + k] do v = le_f32(d, o + 4 * c)
		}
	}
	return points, true
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
