// Stages: a run of DATA202 files. Six layers of three files each (meshes, textures, nodes), then the effect list, the
// wall file ("hitd"), wall names, the floor file ("flor") and more. Big endian, mm, Y up. tk6decomp docs/data.md "Stages".
package tk6_formats

import "core:math"
import tk5 "../tk5"

Stage :: struct {
	id:    string,
	first: int,  // global index of the first layer's mesh file
}

// The stage list comes later.
// (hole tk6-stages :tags (tk6 importer) :sev gap) only stage_00, name unknown; the next one starts at file 2166 if the +42 spacing holds per stage.
STAGES :: [?]Stage{{"stage_00", 2124}}

STAGE_LAYERS :: 6
STAGE_LAYER_FILES :: 3  // meshes, textures, nodes
STAGE_WALLS :: 19       // from the first file
NODE_RECORD :: 0x10      // efhd: u32 node count, {u32 offset, u32 size}[count] from here
NODE_TRANSLATION :: 0x10  // node record: f32 translation[3], euler[3], scale[3]

Stage_Layer :: struct {
	meshes:   []tk5.Mesh,
	matrices: []Maybe([16]f32),  // per mesh, row vectors, mm; nil: the mesh is in world space
	textures: []tk5.Texture,
}

// A layer's meshes, each placed by the node of its name.
read_stage_layer :: proc(game: Game_Files, stage: Stage, layer: int, allocator := context.allocator) -> (out: Stage_Layer, ok: bool) {
	context.allocator = allocator
	first := stage.first + STAGE_LAYER_FILES * layer
	mesh_file := read_file(game, first, allocator = context.temp_allocator) or_return
	texture_file := read_file(game, first + 1, allocator = context.temp_allocator) or_return
	node_file := read_file(game, first + 2, allocator = context.temp_allocator) or_return
	out.textures = tk5.read_ntp3(texture_file) or_return
	places := node_places(node_file) or_return

	meshes := make([dynamic]tk5.Mesh)
	matrices := make([dynamic]Maybe([16]f32))
	objects := nested(mesh_file, 2) or_return
	for object in objects {
		group := tk5.read_ndp3(object, material_slots = MATERIAL_SLOTS) or_return
		for mesh in group {
			placed: Maybe([16]f32)
			if place, named := places[mesh.name]; named && mesh.single_bind >= 0 do placed = place
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

// Node file: section 0 holds an "efhd" per element with its node records, section 1 per element its node names
// (records of 32 or more bytes, a C string first), in the same order.
@(private = "file")
node_places :: proc(data: []byte) -> (places: map[string][16]f32, ok: bool) {
	places = make(map[string][16]f32, context.temp_allocator)
	files := sections(data, context.temp_allocator) or_return
	if len(files) < 2 do return
	headers := sections(files[0], context.temp_allocator) or_return
	name_lists := sections(files[1], context.temp_allocator) or_return
	for header, element in headers {
		if element >= len(name_lists) || len(header) < NODE_RECORD + 4 || string(header[:4]) != "efhd" do continue
		names := sections(name_lists[element], context.temp_allocator) or_return
		count := int(tk5.be_u32(header, 0x30))
		for node in 0 ..< min(count, len(names)) {
			at := 0x30 + int(tk5.be_u32(header, 0x34 + 8 * node))
			if at + NODE_TRANSLATION + 36 > len(header) do return
			places[tk5.cstring_at(names[node], 0)] = node_matrix(header[at + NODE_TRANSLATION:])
		}
	}
	return places, true
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

WALL_COUNT :: 0x24
WALL_TABLE :: 0x28
WALL_RECORD :: 0x90  // u32 size, u32 material, f32 centre x, z, radius², i32 link, 2 x u32, f32 normal[4], corner[4][4]

// The wall quads of the "hitd" file, and the floor as one flat polygon over them [guess: the "flor" file is not read].
read_stage_collision :: proc(game: Game_Files, stage: Stage, allocator := context.allocator) -> (out: tk5.Stage, ok: bool) {
	context.allocator = allocator
	file := read_file(game, stage.first + STAGE_WALLS, allocator = context.temp_allocator) or_return
	parts := sections(file, context.temp_allocator) or_return
	if len(parts) == 0 || len(parts[0]) < WALL_TABLE + 4 || string(parts[0][:4]) != "hitd" do return
	walls := parts[0]
	count, table := int(tk5.be_u32(walls, WALL_COUNT)), int(tk5.be_u32(walls, WALL_TABLE))
	if table + 4 * count > len(walls) do return
	out.quads = make([]tk5.Stage_Quad, count)
	low, high := [3]f32{max(f32), 0, max(f32)}, [3]f32{min(f32), 0, min(f32)}
	for &quad, index in out.quads {
		at := int(tk5.be_u32(walls, table + 4 * index))
		if at + WALL_RECORD > len(walls) do return
		quad.link = tk5.be_i32(walls, at + 0x14)
		quad.normal = vector(walls, at + 0x20)
		for &corner, number in quad.corners {
			corner = vector(walls, at + 0x30 + 0x10 * number)
			low, high = {min(low.x, corner.x), 0, min(low.z, corner.z)}, {max(high.x, corner.x), 0, max(high.z, corner.z)}
		}
	}
	if count == 0 do return
	centre := (low + high) / 2
	corners := [][3]f32{{high.x, 0, high.z}, {high.x, 0, low.z}, {low.x, 0, low.z}, {low.x, 0, high.z}}
	half := (high - low) / 2
	polygon := tk5.Floor_Polygon{centre, half.x * half.x + half.z * half.z, {0, 1, 0}, corners}
	FLOOR_UNDER_FIGHTERS :: 1
	out.floors = make([]tk5.Floor_Zone, 1)
	out.floors[0] = {polygon.centre, polygon.radius_sq, FLOOR_UNDER_FIGHTERS, make([]tk5.Floor_Polygon, 1)}
	out.floors[0].polygons[0] = polygon
	out.floors[0].polygons[0].points = make([][3]f32, len(corners))
	copy(out.floors[0].polygons[0].points, corners)
	return out, true
}

@(private = "file")
vector :: proc(data: []byte, at: int) -> [3]f32 {return {tk5.be_f32(data, at), tk5.be_f32(data, at + 4), tk5.be_f32(data, at + 8)}}
