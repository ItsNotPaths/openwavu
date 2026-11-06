// Stage collision: stages/<id>.collision.glb (floor polygons, wall quads, start nodes) and stages/<id>.surfaces
// (JSON). Mesh data in file units (mm) under a root node that scales to metres. modules/tk5/sim/stage_file.c reads both.
package tk5_convert

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "../../gltf"
import formats "../../formats/tk5"

// (hole stage-effects :tags (importer effects)) stage EFP records (section 8, spawned by stage objects 900 + k) are not converted: they are 3D debris objects (0xaf404), not sprites.

Surface :: struct {
	layers:      bit_set[0 ..< 7; u32],  // 0: the floor under the fighters, 1..6: the lists the special queries name
	material:    int,
	hit_event:   int,  // 0: none
	break_power: int,
}

Surface_Row :: struct {
	layers:      []string,
	material:    int,
	hit_event:   int,
	break_power: int,
	on_break:    []string,  // visual mesh nodes the break swaps
}

// The floor zone flags of each list (1..6).
@(rodata)
LIST_FLAGS := [7]u32{0, 1 << 12, 1 << 13, 1 << 15, 1 << 16, 1 << 1, 1 << 14}

// The first ground flag of a zone, in this order, gives its material; none: 11, or 12 without GROUND_ROOM.
@(rodata)
GROUND_KINDS := [?][2]u32{{1 << 2, 1}, {1 << 3 | 1 << 4, 2}, {1 << 5, 4}, {1 << 6, 5}, {1 << 7, 6}, {1 << 8, 7}, {1 << 9, 8}, {1 << 10, 9}, {1 << 11, 10}}
GROUND_ROOM :: 1 << 17

floor_surface :: proc(flags: u32) -> (s: Surface) {
	if flags & 1 != 0 do s.layers += {0}
	for list in 1 ..= 6 do if flags & LIST_FLAGS[list] != 0 do s.layers += {list}
	s.material = flags & GROUND_ROOM != 0 ? 11 : 12
	for kind in GROUND_KINDS {
		if flags & kind[0] == 0 do continue
		s.material = int(kind[1])
		break
	}
	return
}

// The start lists of object slot 0: side 1 and 2 are the two points of a record of group 0, the entrance group 1.
Start_List :: struct {name: string, group, point: int}
@(rodata)
START_LISTS := [?]Start_List{{"side_1", 0, 0}, {"side_2", 0, 1}, {"entrance", 1, 0}}

start_group :: proc(slot: formats.Start_Slot, group: int) -> (formats.Start_Group, bool) {
	for g, i in slot.groups do if (slot.pos_format ? i : g.id) == group do return g, true
	return {}, false
}

write_stage_collision :: proc(collision_path, surfaces_path: string, s: formats.Stage) -> (ok: bool) {
	context.allocator = context.temp_allocator
	surfaces: [dynamic]Surface
	surface_index :: proc(surfaces: ^[dynamic]Surface, s: Surface) -> u16 {
		for have, i in surfaces do if have == s do return u16(i)
		append(surfaces, s)
		return u16(len(surfaces) - 1)
	}

	g: gltf.Gltf
	root := gltf.Node{name = "stage", scale = floats(1 / f32(MM), 1 / f32(MM), 1 / f32(MM))}

	positions, normals: [dynamic][3]f32
	surface, polygon: [dynamic]u16
	indices: [dynamic]u32
	polygons := 0
	for zone in s.floors {
		for p in zone.polygons {
			at := surface_index(&surfaces, floor_surface(zone.flags))
			base := u32(len(positions))
			for point in p.points {
				append(&positions, point)
				append(&normals, p.normal)
				append(&surface, at)
				append(&polygon, u16(polygons))
			}
			for k in 1 ..< len(p.points) - 1 do append(&indices, base, base + u32(k), base + u32(k) + 1)
			polygons += 1
		}
	}
	if polygons > 0 do add_collision_mesh(&g, &root, "floors", positions[:], normals[:], surface[:], polygon[:], indices[:])

	clear(&positions); clear(&normals); clear(&surface); clear(&indices)
	for q in s.quads {
		if q.link == 0 do return false  // 0 means no event
		at := surface_index(&surfaces, Surface{hit_event = max(int(q.link), 0)})
		base := u32(len(positions))
		for corner in q.corners {
			append(&positions, corner)
			append(&normals, q.normal)
			append(&surface, at)
		}
		append(&indices, base, base + 1, base + 2, base, base + 2, base + 3)
	}
	if len(s.quads) > 0 do add_collision_mesh(&g, &root, "walls", positions[:], normals[:], surface[:], nil, indices[:])
	if polygons > int(max(u16)) || len(surfaces) > int(max(u16)) do return false

	slot := s.start[0]
	for list in START_LISTS {
		group := start_group(slot, list.group) or_continue
		if group.points == nil do continue
		for record in 0 ..< group.count {
			point := group.points[record * group.per_record + list.point]
			turn := point[5]  // rotation y
			extras := make(json.Object)
			extras["turn"] = json.Float(turn)
			append(&g.nodes, gltf.Node{
				name = fmt.tprintf("start.%s.%d", list.name, record), translation = floats(point[0], point[1], point[2]),
				rotation = floats(0, math.sin(turn / 2), 0, math.cos(turn / 2)), extras = extras})
			append(&root.children, len(g.nodes) - 1)
		}
	}

	append(&g.nodes, root)
	scene: gltf.Scene
	append(&scene.nodes, len(g.nodes) - 1)
	append(&g.scenes, scene)
	gltf.write_glb(&g, collision_path) or_return

	rows := make([]Surface_Row, len(surfaces))
	for surface, i in surfaces {
		layers: [dynamic]string
		for layer in surface.layers do append(&layers, LAYER_NAMES[layer])
		rows[i] = {layers[:], surface.material, surface.hit_event, surface.break_power, {}}
	}
	text, err := json.marshal(rows, {pretty = true})
	return err == nil && os.write_entire_file(surfaces_path, text) == nil
}

@(rodata)
LAYER_NAMES := [7]string{"floor", "list_1", "list_2", "list_3", "list_4", "list_5", "list_6"}

// A slice literal points at the stack: the glb is written after this frame ends.
@(private = "file")
floats :: proc(values: ..f32) -> []f32 {return slice.clone(values)}

@(private = "file")
add_collision_mesh :: proc(g: ^gltf.Gltf, root: ^gltf.Node, name: string, positions, normals: [][3]f32, surface, polygon: []u16, indices: []u32) {
	prim := gltf.Primitive{attributes = make(map[string]int)}
	prim.attributes["POSITION"] = gltf.add_accessor(g, positions, "VEC3", gltf.ARRAY_BUFFER, with_bounds = true)
	prim.attributes["_NORMAL"] = gltf.add_accessor(g, normals, "VEC3", gltf.ARRAY_BUFFER)  // as stored, not unit
	prim.attributes["_SURFACE"] = gltf.add_accessor(g, surface, "SCALAR", gltf.ARRAY_BUFFER)
	if polygon != nil do prim.attributes["_POLYGON"] = gltf.add_accessor(g, polygon, "SCALAR", gltf.ARRAY_BUFFER)
	prim.indices = gltf.add_accessor(g, indices, "SCALAR", gltf.ELEMENT_ARRAY_BUFFER)
	mesh := gltf.Mesh{name = name}
	append(&mesh.primitives, prim)
	append(&g.meshes, mesh)
	append(&g.nodes, gltf.Node{name = name, mesh = len(g.meshes) - 1})
	append(&root.children, len(g.nodes) - 1)
}
