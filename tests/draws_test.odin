package tests

import "core:math/linalg"
import "core:testing"
import "../src/render"

// A model whose meshes are told apart by index_count; no GPU.
@(private = "file")
model_of :: proc(nodes: []render.Model_Node, meshes: int, skins: []render.Model_Skin = nil) -> render.Model {
	model := render.Model{nodes = nodes, skins = skins, meshes = make([][]render.Primitive, meshes, context.temp_allocator)}
	for &primitives, index in model.meshes {
		primitives = make([]render.Primitive, 1, context.temp_allocator)
		primitives[0].mesh.index_count = u32(index + 1)
	}
	roots := make([dynamic]int, context.temp_allocator)
	for node, index in nodes do if node.parent < 0 do append(&roots, index)
	model.roots = roots[:]
	return model
}

@(private = "file")
drawn_meshes :: proc(model: ^render.Model, scene_nodes: []render.Node) -> (meshes: [dynamic]u32) {
	meshes = make([dynamic]u32, context.temp_allocator)
	assets := render.assets_create({})
	defer render.assets_destroy(&assets, nil)
	assets.models[1] = model
	defer delete_key(&assets.models, 1)  // not the assets' to free
	scene := render.Scene{nodes = make([dynamic]render.Node, context.temp_allocator)}
	append(&scene.nodes, ..scene_nodes)
	for draw in render.scene_draws(&scene, &assets, nil) do append(&meshes, draw.mesh.index_count)
	return
}

@(private = "file")
mesh_draw :: proc(draws: []render.Draw, index_count: u32) -> render.Draw {
	for draw in draws do if draw.mesh.index_count == index_count do return draw
	return {}
}

@(private = "file")
position :: proc(world: matrix[4, 4]f32) -> [3]f32 {
	return {world[0, 3], world[1, 3], world[2, 3]}
}

// A stage glb: the whole glb leaves out its _DRWOFF_ props and the parts the scene sends hidden; a part draws only
// itself and what is under it, a broken prop too; a hidden node draws nothing.
@(test)
whole_glb_leaves_out_broken_props_and_hidden_parts :: proc(t: ^testing.T) {
	nodes := []render.Model_Node{
		{name = "stage", parent = -1, children = {1, 2, 3}, local = 1, mesh = -1, skin = -1, bone = -1},
		{name = "wall", parent = 0, children = {4}, local = 1, mesh = 0, skin = -1, bone = -1},
		{name = "wall_DRWOFF_", parent = 0, local = 1, mesh = 1, skin = -1, bone = -1},
		{name = "pillar", parent = 0, local = 1, mesh = 2, skin = -1, bone = -1},
		{name = "wall_trim", parent = 1, local = 1, mesh = 3, skin = -1, bone = -1},
	}
	model := model_of(nodes, 4)
	IDENTITY :: render.Transform{rotation = 1, scale = 1}
	whole := render.Node{asset = 1, transform = IDENTITY}
	testing.expect_value(t, len(drawn_meshes(&model, {whole})), 3)

	intact_hidden := render.Node{asset = 1, part = 2, transform = IDENTITY, flags = {.Hidden}}
	broken_shown := render.Node{asset = 1, part = 3, transform = IDENTITY}
	broken := drawn_meshes(&model, {whole, intact_hidden, broken_shown})
	testing.expect_value(t, len(broken), 2)
	testing.expect_value(t, broken[0], 3)  // the pillar
	testing.expect_value(t, broken[1], 2)  // the broken wall

	wall_part := drawn_meshes(&model, {{asset = 1, part = 2, transform = IDENTITY}})
	testing.expect_value(t, len(wall_part), 2)  // the wall and its trim
	testing.expect_value(t, len(drawn_meshes(&model, {{asset = 1, transform = IDENTITY, flags = {.Hidden}}})), 0)
	testing.expect_value(t, len(drawn_meshes(&model, {{asset = 1, part = 99, transform = IDENTITY}})), 0)
}

// Two fighters in one costume: a part hidden on one (its bone_offset) still draws on the other.
@(test)
hidden_parts_stay_with_their_fighter :: proc(t: ^testing.T) {
	nodes := []render.Model_Node{
		{name = "body", parent = -1, children = {1}, local = 1, mesh = 0, skin = -1, bone = -1},
		{name = "sword", parent = 0, local = 1, mesh = 1, skin = -1, bone = -1},
	}
	model := model_of(nodes, 2)
	IDENTITY :: render.Transform{rotation = 1, scale = 1}
	first := render.Node{asset = 1, transform = IDENTITY, bone_offset = 100}
	second := render.Node{asset = 1, transform = IDENTITY, bone_offset = 200}
	first_sword_hidden := render.Node{asset = 1, part = 2, transform = IDENTITY, bone_offset = 100, flags = {.Hidden}}
	testing.expect_value(t, len(drawn_meshes(&model, {first, second, first_sword_hidden})), 3)  // two bodies, one sword
}

// A fighter glb: posed joints sit where the bones say, in the node's space; a joint past the bones given, or with a zero
// rotation, keeps its rest offset under its parent; a skinned mesh's own node place does not move it; a mesh under a
// joint (a prop in the hand) follows the posed joint.
@(test)
bones_pose_the_first_skin_in_node_space :: proc(t: ^testing.T) {
	translate :: proc(x, y, z: f32) -> matrix[4, 4]f32 {
		return {1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1}
	}
	nodes := []render.Model_Node{
		{name = "root", parent = -1, children = {1}, local = translate(0, 1, 0), mesh = -1, skin = -1, bone = 0},
		{name = "hand", parent = 0, children = {3}, local = translate(1, 0, 0), mesh = -1, skin = -1, bone = 1},
		{name = "body", parent = -1, local = translate(100, 0, 0), mesh = 0, skin = 0, bone = -1},
		{name = "prop", parent = 1, local = translate(0, 0, 2), mesh = 1, skin = -1, bone = -1},
	}
	skins := []render.Model_Skin{{joints = {0, 1}, inverse_binds = {1, 1}}}
	model := model_of(nodes, 2, skins)
	place := render.Transform{position = {10, 0, 0}, rotation = 1, scale = 1}
	bones := []render.Transform{{position = {0, 5, 0}, rotation = 1, scale = 1}}

	assets := render.assets_create({})
	defer render.assets_destroy(&assets, nil)
	assets.models[1] = &model
	defer delete_key(&assets.models, 1)
	scene := render.Scene{nodes = make([dynamic]render.Node, context.temp_allocator)}
	append(&scene.nodes, render.Node{asset = 1, transform = place, bones = bones})
	draws := render.scene_draws(&scene, &assets, nil)
	if !testing.expect_value(t, len(draws), 2) do return
	body, prop := mesh_draw(draws, 1), mesh_draw(draws, 2)
	testing.expect_value(t, position(body.joints[0]), [3]f32{10, 5, 0})
	testing.expect_value(t, position(body.joints[1]), [3]f32{11, 5, 0})
	testing.expect_value(t, position(prop.joints[0]), [3]f32{11, 5, 2})

	unposed := []render.Transform{{position = {0, 5, 0}}, {position = {7, 7, 7}, scale = 1}}  // zero rotations
	scene.nodes[0].bones = unposed
	draws = render.scene_draws(&scene, &assets, nil)
	if !testing.expect_value(t, len(draws), 2) do return
	body = mesh_draw(draws, 1)
	testing.expect_value(t, position(body.joints[0]), [3]f32{10, 1, 0})
	testing.expect_value(t, position(body.joints[1]), [3]f32{11, 1, 0})
}

// A spring bone: when the bone it hangs from moves, its tail trails behind at the same length, then swings back to
// rest; a no-blend node (a cut) starts at rest.
@(test)
spring_bones_trail_and_settle :: proc(t: ^testing.T) {
	translate :: proc(x, y, z: f32) -> matrix[4, 4]f32 {
		return {1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1}
	}
	nodes := []render.Model_Node{
		{name = "hips", parent = -1, children = {1}, local = 1, mesh = -1, skin = -1, bone = 0},
		{name = "strap", parent = 0, children = {2}, local = translate(0, -0.1, 0), mesh = -1, skin = -1, bone = 1},
		{name = "strap_end", parent = 1, local = translate(0, -0.5, 0), mesh = -1, skin = -1, bone = 2},
		{name = "body", parent = -1, local = 1, mesh = 0, skin = 0, bone = -1},
	}
	skins := []render.Model_Skin{{joints = {0, 1, 2}, inverse_binds = {1, 1, 1}}}
	model := model_of(nodes, 1, skins)
	model.swings = {{node = 1, tail = 2, stiffness = 1, drag = 0.5}}

	assets := render.assets_create({})
	defer render.assets_destroy(&assets, nil)
	assets.models[1] = &model
	defer delete_key(&assets.models, 1)
	swings: render.Swings
	defer render.swings_destroy(&swings)
	swings.seconds = 1.0 / 60
	bones := []render.Transform{{rotation = 1, scale = 1}}
	scene := render.Scene{nodes = make([dynamic]render.Node, context.temp_allocator)}
	append(&scene.nodes, render.Node{asset = 1, transform = {rotation = 1, scale = 1}, bones = bones})
	strap_end :: proc(scene: ^render.Scene, assets: ^render.Assets, swings: ^render.Swings) -> (strap, end: [3]f32) {
		draws := render.scene_draws(scene, assets, nil, swings)
		return position(draws[0].joints[1]), position(draws[0].joints[2])
	}
	_, end := strap_end(&scene, &assets, &swings)
	testing.expect_value(t, end, [3]f32{0, -0.6, 0})

	bones[0].position = {1, 0, 0}
	strap: [3]f32
	strap, end = strap_end(&scene, &assets, &swings)
	testing.expect(t, end.x < 0.9, "the tail trails behind")
	testing.expect(t, abs(linalg.length(end - strap) - 0.5) < 1e-4, "the strap keeps its length")
	for _ in 0 ..< 600 do _, end = strap_end(&scene, &assets, &swings)
	testing.expect(t, linalg.length(end - [3]f32{1, -0.6, 0}) < 0.01, "the tail settles at rest")

	bones[0].position = {5, 0, 0}
	scene.nodes[0].flags = {.No_Blend}
	_, end = strap_end(&scene, &assets, &swings)
	testing.expect(t, linalg.length(end - [3]f32{5, -0.6, 0}) < 1e-5, "a cut starts at rest")
}
