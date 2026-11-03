package tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:testing"
import "../src/dds"
import "../src/gltf"
import "../src/render"
import "../src/titlepack"

// A pack folder with models/quad.glb: a root with a child holding a quad, whose cut-out material uses textures/red.dds
// (one red DXT1 block) and whose vertices are half grey; no normals. Also models/loop.glb, whose node is its own
// child, models/outside.glb, whose texture uri leaves the pack, and models/joint_<n>.glb: a triangle skinned to joint n
// of a one-joint skin, next to an empty primitive. models/bad_index.glb: a good triangle, then one whose index is past
// its vertices. The caller removes the folder.
@(private = "file")
write_model_pack :: proc(t: ^testing.T, dir: string) {
	context.allocator = context.temp_allocator
	os.make_directory(dir)
	os.make_directory(fmt.tprintf("%s/models", dir))
	os.make_directory(fmt.tprintf("%s/textures", dir))
	red_block := []byte{0x00, 0xf8, 0x00, 0xf8, 0, 0, 0, 0}  // both colors 565 red, every texel color 0
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/textures/red.dds", dir), dds.encode(.BC1, 4, 4, red_block)) == nil)

	quad :: proc(t: ^testing.T, path, uri: string, nodes: []gltf.Node) {
		g: gltf.Gltf
		positions := [][3]f32{{-1, -1, 0}, {1, -1, 0}, {1, 1, 0}, {-1, 1, 0}}
		uvs := [][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}
		colors := [][4]f32{0.5, 0.5, 0.5, 0.5}
		indices := []u16{0, 1, 2, 0, 2, 3}
		p := gltf.Primitive{attributes = make(map[string]int), material = 0}
		p.attributes["POSITION"] = gltf.add_accessor(&g, positions, "VEC3")
		p.attributes["TEXCOORD_0"] = gltf.add_accessor(&g, uvs, "VEC2")
		p.attributes["COLOR_0"] = gltf.add_accessor(&g, colors, "VEC4")
		p.indices = gltf.add_accessor(&g, indices, "SCALAR")
		mesh: gltf.Mesh
		append(&mesh.primitives, p)
		append(&g.meshes, mesh)
		material := gltf.Material{alphaMode = "MASK"}
		material.pbrMetallicRoughness.baseColorTexture = gltf.Texture_Info{gltf.add_dds_texture(&g, uri)}
		append(&g.materials, material)
		append(&g.nodes, ..nodes)
		scene: gltf.Scene
		append(&scene.nodes, 0)
		append(&g.scenes, scene)
		testing.expect(t, gltf.write_glb(&g, path))
	}
	root := gltf.Node{name = "root"}
	append(&root.children, 1)
	child := gltf.Node{name = "quad", mesh = 0, translation = {0.5, 0, 0}}
	quad(t, fmt.tprintf("%s/models/quad.glb", dir), "../textures/red.dds", {root, child})
	quad(t, fmt.tprintf("%s/models/outside.glb", dir), "../../red.dds", {child})
	looped := gltf.Node{name = "loop", mesh = 0}
	append(&looped.children, 0)
	quad(t, fmt.tprintf("%s/models/loop.glb", dir), "../textures/red.dds", {looped})

	for joint in ([]u16{0, 1}) {
		g: gltf.Gltf
		p := gltf.Primitive{attributes = make(map[string]int)}
		p.attributes["POSITION"] = gltf.add_accessor(&g, [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}, "VEC3")
		p.attributes["JOINTS_0"] = gltf.add_accessor(&g, [][4]u16{joint, joint, joint}, "VEC4")
		p.attributes["WEIGHTS_0"] = gltf.add_accessor(&g, [][4]f32{{1, 0, 0, 0}, {1, 0, 0, 0}, {1, 0, 0, 0}}, "VEC4")
		empty := gltf.Primitive{attributes = make(map[string]int)}
		empty.attributes["POSITION"] = gltf.add_accessor(&g, [][3]f32{}, "VEC3")
		mesh: gltf.Mesh
		append(&mesh.primitives, p, empty)
		append(&g.meshes, mesh)
		skin: gltf.Skin
		append(&skin.joints, 0)
		append(&g.skins, skin)
		append(&g.nodes, gltf.Node{name = "bone"}, gltf.Node{name = "body", mesh = 0, skin = 0})
		scene: gltf.Scene
		append(&scene.nodes, 0, 1)
		append(&g.scenes, scene)
		testing.expect(t, gltf.write_glb(&g, fmt.tprintf("%s/models/joint_%d.glb", dir, joint)))
	}

	g: gltf.Gltf
	triangle := gltf.add_accessor(&g, [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}, "VEC3")
	good := gltf.Primitive{attributes = make(map[string]int)}
	good.attributes["POSITION"] = triangle
	bad := gltf.Primitive{attributes = make(map[string]int), indices = gltf.add_accessor(&g, []u16{0, 1, 3}, "SCALAR")}
	bad.attributes["POSITION"] = triangle
	mesh: gltf.Mesh
	append(&mesh.primitives, good, bad)
	append(&g.meshes, mesh)
	append(&g.nodes, gltf.Node{name = "body", mesh = 0})
	testing.expect(t, gltf.write_glb(&g, fmt.tprintf("%s/models/bad_index.glb", dir)))
}

// A glb loads with its node tree and draws in its DDS texture's color times its vertex color; a node tree that loops
// does not load; a texture outside the pack draws white; vertices naming a joint past their skin do not load, and an
// empty primitive is left out; a bad primitive after a good one fails the glb and leaks nothing.
@(test)
glb_loads_and_draws_in_its_texture :: proc(t: ^testing.T) {
	g, ok := test_gpu_create(t)
	if !ok do return
	defer test_gpu_destroy(&g)
	DIR :: "build/model_pack"
	write_model_pack(t, DIR)
	defer os.remove_all(DIR)
	files, opened := titlepack.open_files(DIR)
	if !testing.expect(t, opened) do return
	defer titlepack.close_files(&files)
	assets := render.assets_create(files)
	defer render.assets_destroy(&assets, &g)

	m := render.asset_model(&assets, &g, render.asset_id(&assets, "models/quad.glb"))
	if !testing.expect(t, m != nil) do return
	testing.expect_value(t, len(m.roots), 1)
	child := m.nodes[1]
	testing.expect_value(t, child.parent, 0)
	testing.expect_value(t, child.local[0, 3], 0.5)
	primitive := m.meshes[child.mesh][0]
	testing.expect(t, primitive.cutout)
	testing.expect(t, primitive.texture != nil)

	testing.expect(t, render.asset_model(&assets, &g, render.asset_id(&assets, "models/loop.glb")) == nil)
	outside := render.asset_model(&assets, &g, render.asset_id(&assets, "models/outside.glb"))
	if testing.expect(t, outside != nil) do testing.expect(t, outside.meshes[0][0].texture == nil)
	skinned := render.asset_model(&assets, &g, render.asset_id(&assets, "models/joint_0.glb"))
	if testing.expect(t, skinned != nil) do testing.expect_value(t, len(skinned.meshes[0]), 1)
	testing.expect(t, render.asset_model(&assets, &g, render.asset_id(&assets, "models/joint_1.glb")) == nil)
	testing.expect(t, render.asset_model(&assets, &g, render.asset_id(&assets, "models/bad_index.glb")) == nil)

	scene := render.scene_create()
	defer render.scene_destroy(&scene)
	scene.camera = {position = {0, 0, 5}, target = {0, 0, 0}, fov = math.PI / 3}
	scene.ambient = {1, 1, 1, 1}
	draws := []render.Draw{{mesh = primitive.mesh, joints = {1}, texture = primitive.texture, tint = 1, cutout = primitive.cutout}}
	SIZE :: 16
	pixels, drawn := test_draw(t, &g, &scene, draws, SIZE)
	if !drawn do return
	center := pixels[SIZE / 2 * SIZE + SIZE / 2]
	testing.expectf(t, center.r >= 126 && center.r <= 129 && center.g == 0 && center.b == 0, "half red, got %v", center)
}

// Stock part and stage glbs load, and every texture their materials name loads too.
@(test)
stock_models_load_with_their_textures :: proc(t: ^testing.T) {
	if !os.exists(STOCK_PACK) do return
	g, ok := test_gpu_create(t)
	if !ok do return
	defer test_gpu_destroy(&g)
	files, opened := titlepack.open_files(STOCK_PACK)
	if !testing.expect(t, opened) do return
	defer titlepack.close_files(&files)
	assets := render.assets_create(files)
	defer render.assets_destroy(&assets, &g)

	for path in ([]string{"parts/steve/steve_1.glb", "parts/king/king_1.glb", "stages/acid_rain.glb"}) {
		m := render.asset_model(&assets, &g, render.asset_id(&assets, path))
		if !testing.expectf(t, m != nil, "%s does not load", path) do continue
		data, _ := titlepack.read_file(files, path)
		file, read := gltf.read_glb(data, context.temp_allocator)
		if !testing.expect(t, read) do continue
		for mesh, i in file.meshes {
			for p, k in mesh.primitives {
				material := p.material.? or_else -1
				textured := material >= 0 && file.materials[material].pbrMetallicRoughness.baseColorTexture != nil
				testing.expectf(t, !textured || m.meshes[i][k].texture != nil, "%s mesh %d: texture does not load", path, i)
			}
		}
	}
}
