// Stages: a run of DATA202 files. Six layers of three files each (meshes, textures, nodes), then the effect list, the
// wall file ("hitd"), wall names, the floor file ("flor") and more. Big endian, mm, Y up. tk6decomp docs/data.md "Stages".
package tk6_formats

import "core:math"
import "core:slice"
import tk5 "../tk5"

Stage :: struct {
	id:    string,
	first: int,  // global index of the first layer's mesh file
}

// Every stage, 42 files apart (each "elmt" at first + 18). Files 3132.. hold a stub with empty layers, not a stage.
// (hole tk6-stage-names :tags (tk6 importer) :sev polish) stages are named by number; the game's names are unread.
STAGES :: [?]Stage{
	{"stage_00", 2124}, {"stage_01", 2166}, {"stage_02", 2208}, {"stage_03", 2250}, {"stage_04", 2292}, {"stage_05", 2334},
	{"stage_06", 2376}, {"stage_07", 2418}, {"stage_08", 2460}, {"stage_09", 2502}, {"stage_10", 2544}, {"stage_11", 2586},
	{"stage_12", 2628}, {"stage_13", 2670}, {"stage_14", 2712}, {"stage_15", 2754}, {"stage_16", 2796}, {"stage_17", 2838},
	{"stage_18", 2880}, {"stage_19", 2922}, {"stage_20", 2964},
}

STAGE_LAYERS :: 6
STAGE_LAYER_FILES :: 3  // meshes, textures, nodes
STAGE_WALLS :: 19       // from the first file
SPAWNED_LAYER :: 0       // its elements (break pieces, effects, sound dummies) are only placed by break sequences
EFHD_FLAGS :: 0x10       // efhd: u32 flags
EFHD_NODES :: 0x30       // efhd: u32 node count, {u32 offset, u32 size}[count] from here
HIDDEN_AT_START :: 0x1   // efhd flag: shown only by a break sequence (FUN_001712ec)
GROUND_TILE :: 0x100     // efhd flag: one floor tile ("inf_gnd", stages 01, 07, 13, 20), a single node
NODE_RENDER_RECORD :: 0x0c  // node record: u32 node file section 3 record; NO_RENDER_RECORD: not drawn (roots "ANIM1_", "ANIMEFF_", "HIDEMODEL" helpers)
NODE_TRANSLATION :: 0x10    // node record: f32 translation[3], euler[3], scale[3], in the parent node's space
NODE_CHILDREN :: 0x40       // node record: u32 child count
NODE_STATES :: 0x48         // node record: u32 anim state count
NODE_LISTS :: 0x80          // node record: u32 child node[count], then the anim states {u32 mode, gyas, start frame, 0}, then -1
GYAS_FRAMES :: 0x08         // gyas: u16 frame count, u16 frame size, u32 offset of frame 0
GYAS_PLACE_SIZE :: 36       // gyas frame: f32 translation[3], euler[3], scale[3] like a node record; smaller frames hold no place
NO_RENDER_RECORD :: 0xffffffff

Stage_Layer :: struct {
	meshes:   []tk5.Mesh,
	matrices: []Maybe([16]f32),  // per mesh, row vectors, mm; nil: the mesh is in world space
	textures: []tk5.Texture,
}

// A layer's meshes. A mesh object's single_bind is a node of its element, counted past a root without a render record
// unless a mesh is named after that root (stages 16, 18, 19); the element is the one that names a mesh of the object,
// else the one before it (objects run element by element). Bind -1: world space. Meshes of nodes without a render
// record are not drawn.
// An object that names no element and has only world space meshes is base scenery, shown whatever the element before
// it (stage 02 ground, stage 09 floor). In a layer with ground tiles, an object that names no element holds tile
// meshes: bind k is the k-th tile element.
// (hole tk6-infinite-tiles :tags (tk6 importer sim) :sev gap) ground tiles stay at their homes, so the tile stages (01, 07, 13, 20; user: 01 is infinite) play walled; the game's tile pool (period, radius) and whether it drops their hitd walls are not read.
// Only meshes of elements shown at match start; stage 15 has no texture files: a bare stage. tk6decomp docs/data.md
// "Element visibility".
// (hole tk6-stage-states :tags (tk6 importer look) :sev gap) only the start state: the sqef break sequences (show, hide, spawn at a posf point) are not imported.
read_stage_layer :: proc(game: Game_Files, stage: Stage, layer: int, allocator := context.allocator) -> (out: Stage_Layer, ok: bool) {
	context.allocator = allocator
	first := stage.first + STAGE_LAYER_FILES * layer
	mesh_file := read_file(game, first, allocator = context.temp_allocator) or_return
	node_file := read_file(game, first + 2, allocator = context.temp_allocator) or_return
	if texture_file, has_textures := read_file(game, first + 1, allocator = context.temp_allocator); has_textures {
		out.textures = tk5.read_ntp3(texture_file) or_return
	}
	elements, element_of, tiles := node_elements(node_file) or_return

	meshes := make([dynamic]tk5.Mesh)
	matrices := make([dynamic]Maybe([16]f32))
	objects := nested(mesh_file, 2) or_return
	groups := make([][]tk5.Mesh, len(objects), context.temp_allocator)
	for object, number in objects {
		groups[number] = tk5.read_ndp3(object, material_slots = MATERIAL_SLOTS) or_return
		for mesh in groups[number] do if element, named := element_of[mesh.name]; named && mesh.name == elements[element].root_name do elements[element].first_bind = 0
	}
	current := -1
	for group in groups {
		names_element := false
		for mesh in group do if element, named := element_of[mesh.name]; named do current, names_element = element, true
		tile_object := !names_element && len(tiles) > 0
		bound := false
		for mesh in group do bound ||= mesh.single_bind >= 0
		owned := names_element || (bound && !tile_object)
		if owned && current >= 0 && elements[current].hidden do continue
		for mesh in group {
			placed: Maybe([16]f32)
			if tile_object {
				if mesh.single_bind >= 0 && int(mesh.single_bind) < len(tiles) do placed = tiles[mesh.single_bind]
			} else if mesh.single_bind >= 0 && current >= 0 {
				element := elements[current]
				node := int(mesh.single_bind) + element.first_bind
				if node < len(element.places) {
					if !element.drawn[node] do continue
					placed = element.places[node]
				}
			}
			append(&meshes, mesh)
			append(&matrices, placed)
		}
	}
	out.meshes, out.matrices = meshes[:], matrices[:]
	return out, true
}

// The sections `depth` containers down the first section of each.
@(private = "file")
nested :: proc(data: []byte, depth: int) -> (inner: [][]byte, ok: bool) {
	inner = sections(data, context.temp_allocator) or_return
	for _ in 0 ..< depth {
		if len(inner) == 0 do return
		inner = sections(inner[0], context.temp_allocator) or_return
	}
	return inner, true
}

// One element of a node file: per node its place in stage space and whether it has a render record, the node bind 0
// means (1 past a root node), and whether it starts hidden.
@(private = "file")
Element :: struct {
	places:     [][16]f32,
	drawn:      []bool,
	root_name:  string,
	first_bind: int,
	hidden:     bool,
}

// Node file: section 0 holds an "efhd" per element with its node records, section 1 per element its node names
// (records of 32 or more bytes, a C string first), in the same order, section 2 the node anims ("gyas"). An element's nodes are one tree, node 0 the
// top, each parent before its children (all 21 stages). element_of: node name -> element. tiles: the place of each
// ground tile element, in element order.
@(private = "file")
node_elements :: proc(data: []byte) -> (elements: []Element, element_of: map[string]int, tiles: [][16]f32, ok: bool) {
	tile_places := make([dynamic][16]f32, context.temp_allocator)
	element_of = make(map[string]int, context.temp_allocator)
	files := sections(data, context.temp_allocator) or_return
	if len(files) < 2 do return
	headers := sections(files[0], context.temp_allocator) or_return
	name_lists := sections(files[1], context.temp_allocator) or_return
	anims: [][]byte
	if len(files) > 2 do anims = sections(files[2], context.temp_allocator) or_return
	elements = make([]Element, len(headers), context.temp_allocator)
	for header, element in headers {
		if element >= len(name_lists) || len(header) < EFHD_NODES + 4 || string(header[:4]) != "efhd" do continue
		elements[element].hidden = tk5.be_u32(header, EFHD_FLAGS) & HIDDEN_AT_START != 0
		names := sections(name_lists[element], context.temp_allocator) or_return
		count := min(int(tk5.be_u32(header, EFHD_NODES)), len(names))
		places := make([][16]f32, count, context.temp_allocator)
		drawn := make([]bool, count, context.temp_allocator)
		parents := make([]int, count, context.temp_allocator)
		slice.fill(parents, -1)
		for &place, node in places {
			at := EFHD_NODES + int(tk5.be_u32(header, EFHD_NODES + 4 + 8 * node))
			if at + NODE_LISTS > len(header) do return
			name := tk5.cstring_at(names[node], 0)
			drawn[node] = tk5.be_u32(header, at + NODE_RENDER_RECORD) != NO_RENDER_RECORD
			if node == 0 && !drawn[node] do elements[element].first_bind, elements[element].root_name = 1, name
			children := int(tk5.be_u32(header, at + NODE_CHILDREN))
			states := at + NODE_LISTS + 4 * children
			if states + 16 > len(header) do return
			place = node_matrix(header[at + NODE_TRANSLATION:])
			if tk5.be_u32(header, at + NODE_STATES) > 0 {
				if frame, has_place := start_frame(anims, header[states:]); has_place do place = node_matrix(frame)
			}
			if parents[node] >= 0 do place = in_parent(place, places[parents[node]])
			element_of[name] = element
			for number in 0 ..< children {
				child := int(tk5.be_u32(header, at + NODE_LISTS + 4 * number))
				if child > node && child < count do parents[child] = node
			}
		}
		elements[element].places, elements[element].drawn = places, drawn
		if tk5.be_u32(header, EFHD_FLAGS) & GROUND_TILE != 0 && len(places) > 0 do append(&tile_places, places[0])
	}
	return elements, element_of, tile_places[:], true
}

// The frame state 0's anim starts on (frame 0 for a start of -1): the place of an animated node (stage 05 truck: the
// node record holds zeros). Anims are not played.
// (hole tk6-stage-node-anims :tags (tk6 importer look) :sev polish) gyas node anims are held on their start frame; mode words (once, loop, triggered) and the frame rate are not read.
@(private = "file")
start_frame :: proc(anims: [][]byte, state: []byte) -> (frame: []byte, ok: bool) {
	anim_number, start := int(tk5.be_u32(state, 4)), int(tk5.be_i32(state, 8))
	if anim_number >= len(anims) || len(anims[anim_number]) < GYAS_FRAMES + 8 do return
	anim := anims[anim_number]
	count, size, first := int(tk5.be_u16(anim, GYAS_FRAMES)), int(tk5.be_u16(anim, GYAS_FRAMES + 2)), int(tk5.be_u32(anim, GYAS_FRAMES + 4))
	if size < GYAS_PLACE_SIZE do return
	if start < 0 || start >= count do start = 0
	at := first + start * size
	if at + GYAS_PLACE_SIZE > len(anim) do return
	return anim[at:], true
}

// Scale, then the turns about x, y and z, then the move, for row vectors [guess: Maya's default order].
@(private = "file")
node_matrix :: proc(record: []byte) -> (out: [16]f32) {
	value :: proc(record: []byte, index: int) -> f32 {return tk5.be_f32(record, 4 * index)}
	sine, cosine: [3]f32
	for axis in 0 ..< 3 do sine[axis], cosine[axis] = math.sin(value(record, 3 + axis)), math.cos(value(record, 3 + axis))
	turn_x := matrix[3, 3]f32{1, 0, 0, 0, cosine.x, sine.x, 0, -sine.x, cosine.x}
	turn_y := matrix[3, 3]f32{cosine.y, 0, -sine.y, 0, 1, 0, sine.y, 0, cosine.y}
	turn_z := matrix[3, 3]f32{cosine.z, sine.z, 0, -sine.z, cosine.z, 0, 0, 0, 1}
	turn := turn_x * turn_y * turn_z
	for row in 0 ..< 3 do for column in 0 ..< 3 do out[4 * row + column] = turn[row, column] * value(record, 6 + row)
	for axis in 0 ..< 3 do out[12 + axis] = value(record, axis)
	out[15] = 1
	return
}

// Row vectors: the place times its parent's. Read as Odin's column-major matrices both are transposed, so the order flips.
@(private = "file")
in_parent :: proc(place, parent: [16]f32) -> [16]f32 {
	return transmute([16]f32)(transmute(matrix[4, 4]f32)parent * transmute(matrix[4, 4]f32)place)
}

WALL_COUNT :: 0x24
WALL_TABLE :: 0x28
WALL_RECORD :: 0x90  // u32 size, u32 material, f32 centre x, z, radius², i32 object, 2 x u32, f32 normal[4], corner[4][4]
STAGE_FLOOR :: 21     // from the first file
FLOOR_COUNT :: 0x20
FLOOR_TABLE :: 0x24
FLOOR_HEIGHT :: 0x14     // floor record: f32 y of the floor level
FLOOR_TRIANGLES :: 0x18  // floor record: u32 triangle count, 0 or 1
FLOOR_TRIANGLE :: 0x40   // floor record: the triangle, 0x38 bytes
FLOOR_NORMAL :: 0x10     // triangle: f32 normal[3]
FLOOR_CORNERS :: 0x20    // triangle: f32 (x, z)[3]

// A wall quad; object: the stage object it belongs to (breakable walls), -1 none.
Stage_Wall :: struct {
	object:  i32,
	normal:  [3]f32,
	corners: [4][3]f32,
}

// A floor triangle; every TK6 floor is flat (stages with a lower level start at 7000 mm).
Stage_Floor :: struct {
	normal:  [3]f32,
	corners: [3][3]f32,
}

Stage_Collision :: struct {
	walls:        []Stage_Wall,
	floors:       []Stage_Floor,
	floor_height: f32,  // the start level's: 7000 mm over the lower level on stages 03, 09, 12, 19, else 0
}

// The wall quads of the "hitd" file and the floor triangles of the "flor" file. A stage with no walls is open.
read_stage_collision :: proc(game: Game_Files, stage: Stage, allocator := context.allocator) -> (out: Stage_Collision, ok: bool) {
	context.allocator = allocator
	out.walls = read_walls(game, stage) or_return
	out.floors = read_floors(game, stage) or_return
	if len(out.floors) == 0 do return
	out.floor_height = out.floors[0].corners[0].y
	return out, true
}

@(private = "file")
read_walls :: proc(game: Game_Files, stage: Stage) -> (walls: []Stage_Wall, ok: bool) {
	file := read_file(game, stage.first + STAGE_WALLS, allocator = context.temp_allocator) or_return
	parts := sections(file, context.temp_allocator) or_return
	if len(parts) == 0 || len(parts[0]) < WALL_TABLE + 4 || string(parts[0][:4]) != "hitd" do return
	data := parts[0]
	count, table := int(tk5.be_u32(data, WALL_COUNT)), int(tk5.be_u32(data, WALL_TABLE))
	if table + 4 * count > len(data) do return
	walls = make([]Stage_Wall, count)
	for &wall, index in walls {
		at := int(tk5.be_u32(data, table + 4 * index))
		if at + WALL_RECORD > len(data) do return
		wall.object = tk5.be_i32(data, at + 0x14)
		wall.normal = vector(data, at + 0x20)
		for &corner, number in wall.corners do corner = vector(data, at + 0x30 + 0x10 * number)
	}
	return walls, true
}

// Floor file: one "flor" section per floor level, the start level first (hitd likewise); "flor", u32 record count,
// offset of u32 record offsets; a record holds one triangle or none.
// (hole tk6-floor-levels :tags (tk6 importer sim) :sev gap) only the start level: the lower level a floor break drops to (stages 03, 09, 12, 19: flor and hitd section 1) is not imported.
@(private = "file")
read_floors :: proc(game: Game_Files, stage: Stage) -> (floors: []Stage_Floor, ok: bool) {
	file := read_file(game, stage.first + STAGE_FLOOR, allocator = context.temp_allocator) or_return
	parts := sections(file, context.temp_allocator) or_return
	if len(parts) == 0 || len(parts[0]) < FLOOR_TABLE + 4 || string(parts[0][:4]) != "flor" do return
	data := parts[0]
	count, table := int(tk5.be_u32(data, FLOOR_COUNT)), int(tk5.be_u32(data, FLOOR_TABLE))
	if table + 4 * count > len(data) do return
	list := make([dynamic]Stage_Floor)
	for index in 0 ..< count {
		at := int(tk5.be_u32(data, table + 4 * index))
		if at + FLOOR_TRIANGLE > len(data) do return
		switch tk5.be_u32(data, at + FLOOR_TRIANGLES) {
		case 0: continue
		case 1:
		case: return  // never in the retail stages
		}
		triangle := at + FLOOR_TRIANGLE
		if triangle + FLOOR_CORNERS + 24 > len(data) do return
		floor := Stage_Floor{normal = vector(data, triangle + FLOOR_NORMAL)}
		for &corner, number in floor.corners {
			corner.x, corner.z = tk5.be_f32(data, triangle + FLOOR_CORNERS + 8 * number), tk5.be_f32(data, triangle + FLOOR_CORNERS + 8 * number + 4)
			corner.y = tk5.be_f32(data, at + FLOOR_HEIGHT)
		}
		append(&list, floor)
	}
	return list[:], true
}

@(private = "file")
vector :: proc(data: []byte, at: int) -> [3]f32 {return {tk5.be_f32(data, at), tk5.be_f32(data, at + 4), tk5.be_f32(data, at + 8)}}
