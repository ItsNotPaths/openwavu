// The draws of a scene's glb nodes: the whole glb or one part of it, placed by the node's transform and posed by its
// bones.
package render

import "core:math/linalg"
import "core:strings"

// Every shown glb node's meshes; models load on first use. Lives in allocator.
// (hole render-quad :tags (render look)) image assets and pack texture quads are not drawn, and billboard nodes do not face the camera.
// (hole material-override :tags (render look)) a node's material texture, shader and params are not applied; only its tint is.
// (hole node-clip :tags (render look)) a node's glb animation clip is not played at its clip time.
scene_draws :: proc(scene: ^Scene, assets: ^Assets, gpu: ^Gpu, allocator := context.temp_allocator) -> []Draw {
	draws := make([dynamic]Draw, allocator)
	for &node in scene.nodes {
		if .Hidden in node.flags do continue
		model := asset_model(assets, gpu, node.asset)
		if model == nil do continue
		left_out := node.part == 0 ? whole_glb_left_out(model, scene.nodes[:], node.asset, allocator) : nil
		node_draws(&draws, model, &node, left_out, allocator)
	}
	return draws[:]
}

// What the whole glb leaves out, by glb node: its _DRWOFF_ nodes and the parts the scene hides.
whole_glb_left_out :: proc(model: ^Model, scene_nodes: []Node, asset: u32, allocator := context.temp_allocator) -> []bool {
	left_out := make([]bool, len(model.nodes), allocator)
	for model_node, index in model.nodes do left_out[index] = strings.contains(model_node.name, "_DRWOFF_")
	for node in scene_nodes {
		if node.asset != asset || .Hidden not_in node.flags || node.part == 0 || int(node.part) > len(model.nodes) do continue
		left_out[node.part - 1] = true
	}
	return left_out
}

// The meshes of one scene node: the glb's roots, or its part, each skipping what left_out marks (nil: none).
node_draws :: proc(draws: ^[dynamic]Draw, model: ^Model, node: ^Node, left_out: []bool, allocator := context.temp_allocator) {
	if int(node.part) > len(model.nodes) do return
	placed := posed_world(model, node.bones, allocator)
	place := transform_matrix(node.transform)
	for &world in placed do world = place * world
	shared := Draw{tint = node.material.tint == 0 ? 1 : node.material.tint, scenery = node.class == .Scenery}
	if node.part > 0 {
		subtree_draws(draws, model, placed, int(node.part) - 1, left_out, shared, allocator)
		return
	}
	for root in model.roots do subtree_draws(draws, model, placed, root, left_out, shared, allocator)
}

// Model space per glb node: its rest pose under its parent, or the bone the scene gives its joint. A bone with a zero
// rotation, and a joint past the bones given, keeps its rest pose under its parent.
posed_world :: proc(model: ^Model, bones: []Transform, allocator := context.temp_allocator) -> []matrix[4, 4]f32 {
	world := make([]matrix[4, 4]f32, len(model.nodes), allocator)
	pose :: proc(model: ^Model, bones: []Transform, world: []matrix[4, 4]f32, index: int, parent: matrix[4, 4]f32) {
		model_node := model.nodes[index]
		world[index] = parent * model_node.local
		if model_node.bone >= 0 && model_node.bone < len(bones) && bones[model_node.bone].rotation != 0 {
			world[index] = transform_matrix(bones[model_node.bone])
		}
		for child in model_node.children do pose(model, bones, world, child, world[index])
	}
	for model_node, index in model.nodes do if model_node.parent < 0 do pose(model, bones, world, index, 1)
	return world
}

transform_matrix :: proc(transform: Transform) -> matrix[4, 4]f32 {
	return linalg.matrix4_from_trs_f32(transform.position, transform.rotation, transform.scale)
}

// shared: the node's fields of every draw (tint, scenery).
@(private = "file")
subtree_draws :: proc(draws: ^[dynamic]Draw, model: ^Model, world: []matrix[4, 4]f32, index: int, left_out: []bool, shared: Draw, allocator := context.temp_allocator) {
	if left_out != nil && left_out[index] do return
	model_node := model.nodes[index]
	if model_node.mesh >= 0 {
		joints := mesh_joints(model, world, index, allocator)
		for primitive in model.meshes[model_node.mesh] {
			draw := shared
			draw.mesh, draw.joints, draw.texture, draw.cutoff = primitive.mesh, joints, primitive.texture, primitive.cutoff
			append(draws, draw)
		}
	}
	for child in model_node.children do subtree_draws(draws, model, world, child, left_out, shared, allocator)
}

// A mesh's joints to world: its own node for one with no skin; for a skinned one, as glTF says, its skin's joints
// times their inverse binds, and the mesh node's own place does not count.
@(private = "file")
mesh_joints :: proc(model: ^Model, world: []matrix[4, 4]f32, index: int, allocator := context.temp_allocator) -> []matrix[4, 4]f32 {
	skin_index := model.nodes[index].skin
	if skin_index < 0 {
		joints := make([]matrix[4, 4]f32, 1, allocator)
		joints[0] = world[index]
		return joints
	}
	skin := model.skins[skin_index]
	joints := make([]matrix[4, 4]f32, len(skin.joints), allocator)
	for joint, at in skin.joints do joints[at] = world[joint] * skin.inverse_binds[at]
	return joints
}
