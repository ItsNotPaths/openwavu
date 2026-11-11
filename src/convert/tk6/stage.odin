// Stage collision: stages/<id>.collision.glb (floor triangles, wall quads) and stages/<id>.surfaces (JSON), the files
// modules/tk6/sim/stage_file.c reads. Mesh data in file units (mm) under a root node that scales to metres.
package tk6_convert

import "core:encoding/json"
import "core:os"
import "core:slice"
import "../../gltf"
import formats "../../formats/tk6"

Surface_Row :: struct {
	layers:      []string,
	material:    int,
	hit_event:   int,  // 0: none
	break_power: int,
}

// Every floor triangle is the floor under the fighters; walls have no events.
// (hole tk6-wall-objects :tags (tk6 importer) :sev gap) a wall's stage object (breakable walls and balconies) is read, not written: no wall event.
FLOOR_SURFACE :: 0
WALL_SURFACE :: 1
@(rodata)
SURFACES := [?]Surface_Row{{layers = {"floor"}}, {}}

write_stage_collision :: proc(collision_path, surfaces_path: string, stage: formats.Stage_Collision) -> (ok: bool) {
	context.allocator = context.temp_allocator
	model: gltf.Gltf
	root := gltf.Node{name = "stage", scale = floats(1 / MM, 1 / MM, 1 / MM)}

	positions, normals: [dynamic][3]f32
	surface, polygon: [dynamic]u16
	indices: [dynamic]u32
	if len(stage.floors) > int(max(u16)) do return false
	for floor, number in stage.floors {
		base := u32(len(positions))
		for corner in floor.corners {
			append(&positions, corner)
			append(&normals, floor.normal)
			append(&surface, FLOOR_SURFACE)
			append(&polygon, u16(number))
		}
		append(&indices, base, base + 1, base + 2)
	}
	add_collision_mesh(&model, &root, "floors", positions[:], normals[:], surface[:], polygon[:], indices[:])

	clear(&positions); clear(&normals); clear(&surface); clear(&indices)
	for wall in stage.walls {
		base := u32(len(positions))
		for corner in wall.corners {
			append(&positions, corner)
			append(&normals, wall.normal)
			append(&surface, WALL_SURFACE)
		}
		append(&indices, base, base + 1, base + 2, base, base + 2, base + 3)
	}
	if len(stage.walls) > 0 do add_collision_mesh(&model, &root, "walls", positions[:], normals[:], surface[:], nil, indices[:])

	append(&model.nodes, root)
	scene: gltf.Scene
	append(&scene.nodes, len(model.nodes) - 1)
	append(&model.scenes, scene)
	gltf.write_glb(&model, collision_path) or_return
	text, failed := json.marshal(SURFACES, {pretty = true})
	return failed == nil && os.write_entire_file(surfaces_path, text) == nil
}

// A slice literal points at the stack: the glb is written after this frame ends.
@(private = "file")
floats :: proc(values: ..f32) -> []f32 {return slice.clone(values)}

@(private = "file")
add_collision_mesh :: proc(model: ^gltf.Gltf, root: ^gltf.Node, name: string, positions, normals: [][3]f32, surface, polygon: []u16, indices: []u32) {
	primitive := gltf.Primitive{attributes = make(map[string]int)}
	primitive.attributes["POSITION"] = gltf.add_accessor(model, positions, "VEC3", gltf.ARRAY_BUFFER, with_bounds = true)
	primitive.attributes["_NORMAL"] = gltf.add_accessor(model, normals, "VEC3", gltf.ARRAY_BUFFER)
	primitive.attributes["_SURFACE"] = gltf.add_accessor(model, surface, "SCALAR", gltf.ARRAY_BUFFER)
	if polygon != nil do primitive.attributes["_POLYGON"] = gltf.add_accessor(model, polygon, "SCALAR", gltf.ARRAY_BUFFER)
	primitive.indices = gltf.add_accessor(model, indices, "SCALAR", gltf.ELEMENT_ARRAY_BUFFER)
	mesh := gltf.Mesh{name = name}
	append(&mesh.primitives, primitive)
	append(&model.meshes, mesh)
	append(&model.nodes, gltf.Node{name = name, mesh = len(model.meshes) - 1})
	append(&root.children, len(model.nodes) - 1)
}
