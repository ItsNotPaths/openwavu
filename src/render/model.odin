// A glb on the GPU: its node tree, its skins, and each mesh primitive as a GPU mesh with its base color texture.
package render

import "core:math/linalg"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"
import "../gltf"

Model :: struct {
	nodes:  []Model_Node,   // glTF order
	roots:  []int,          // the default scene's
	meshes: [][]Primitive,  // glTF order; nodes share them
	skins:  []Model_Skin,
}

Model_Node :: struct {
	name:     string,
	parent:   int,  // -1 for a root
	children: []int,
	local:    matrix[4, 4]f32,
	mesh:     int,  // -1: none
	skin:     int,  // -1: not skinned
}

Primitive :: struct {
	mesh:    Mesh,
	joints:  int,              // how many the vertices name: 1 unskinned, else the highest + 1
	texture: ^sdl.GPUTexture,  // nil: white; owned by Assets
	cutout:  bool,
}

Model_Skin :: struct {
	joints:        []int,  // nodes
	inverse_binds: []matrix[4, 4]f32,
}

// Reads the glb at path from data. Its textures come through a; one that does not load draws white.
// Fails on a glb that does not read or whose indices point outside it, also a vertex joint past its node's skin;
// only triangle lists with vertices are drawn.
model_load :: proc(g: ^Gpu, a: ^Assets, path: string, data: []byte) -> (m: ^Model, ok: bool) {
	file := gltf.read_glb(data) or_return
	defer gltf.destroy_gltf(&file)
	tree_valid(&file) or_return
	u := upload_begin(g) or_return
	m = new(Model)
	ok = model_fill(g, u, a, m, &file, path)
	ok = upload_end(u) && ok
	if !ok {
		model_destroy(g, m)
		return nil, false
	}
	return m, true
}

model_destroy :: proc(g: ^Gpu, m: ^Model) {
	for node in m.nodes {
		delete(node.name)
		delete(node.children)
	}
	for primitives in m.meshes {
		for p in primitives do mesh_destroy(g, p.mesh)
		delete(primitives)
	}
	for skin in m.skins {
		delete(skin.joints)
		delete(skin.inverse_binds)
	}
	delete(m.nodes)
	delete(m.roots)
	delete(m.meshes)
	delete(m.skins)
	free(m)
}

@(private = "file")
model_fill :: proc(g: ^Gpu, u: Upload, a: ^Assets, m: ^Model, file: ^gltf.Gltf, path: string) -> (ok: bool) {
	m.nodes = make([]Model_Node, len(file.nodes))
	for &node in m.nodes do node.parent = -1
	for n, i in file.nodes {
		m.nodes[i] = {
			name = strings.clone(n.name),
			children = slice.clone(n.children[:]),
			local = local_matrix(n),
			mesh = n.mesh.? or_else -1,
			skin = n.skin.? or_else -1,
		}
	}
	for n, i in file.nodes do for child in n.children do m.nodes[child].parent = i
	if len(file.scenes) > 0 do m.roots = slice.clone(file.scenes[file.scene].nodes[:])

	textures := make([]^sdl.GPUTexture, len(file.textures), context.temp_allocator)
	for _, i in file.textures do textures[i] = texture_of(g, u, a, file, i, path)
	m.meshes = make([][]Primitive, len(file.meshes))
	for mesh, i in file.meshes {
		primitives := make([dynamic]Primitive, 0, len(mesh.primitives))
		defer m.meshes[i] = primitives[:]  // also on a failed upload, so model_destroy frees the ones before it
		for p in mesh.primitives {
			if !drawn(file, p) do continue
			uploaded := primitive_upload(g, u, file, p, textures) or_return
			append(&primitives, uploaded)
		}
	}
	m.skins = make([]Model_Skin, len(file.skins))
	for skin, i in file.skins {
		m.skins[i].joints = slice.clone(skin.joints[:])
		m.skins[i].inverse_binds = make([]matrix[4, 4]f32, len(skin.joints))
		for &bind in m.skins[i].inverse_binds do bind = 1
		accessor, has := skin.inverseBindMatrices.?
		if !has do continue
		binds := gltf.read_accessor(file, accessor, [16]f32, context.temp_allocator) or_return
		if len(binds) < len(skin.joints) do return false
		for &bind, k in m.skins[i].inverse_binds do bind = transmute(matrix[4, 4]f32)binds[k]
	}
	for node in m.nodes {
		if node.mesh < 0 do continue
		joints := node.skin < 0 ? 1 : len(m.skins[node.skin].joints)
		for p in m.meshes[node.mesh] do if p.joints > joints do return false
	}
	return true
}

// A triangle list with vertices; other modes and empty primitives are left out.
@(private = "file")
drawn :: proc(file: ^gltf.Gltf, p: gltf.Primitive) -> bool {
	if mode, has := p.mode.?; has && mode != gltf.TRIANGLES do return false
	position, has := p.attributes["POSITION"]
	return !has || position < 0 || position >= len(file.accessors) || file.accessors[position].count > 0
}

// Every index in range, each node under at most one parent, no cycles, and scene roots under none.
@(private = "file")
tree_valid :: proc(file: ^gltf.Gltf) -> (ok: bool) {
	count := len(file.nodes)
	parent := make([]int, count, context.temp_allocator)
	for &p in parent do p = -1
	for n, i in file.nodes {
		for child in n.children {
			if child < 0 || child >= count || parent[child] >= 0 do return false
			parent[child] = i
		}
		if mesh, has := n.mesh.?; has && (mesh < 0 || mesh >= len(file.meshes)) do return false
		if skin, has := n.skin.?; has && (skin < 0 || skin >= len(file.skins)) do return false
		if !given(n.transform, 16) || !given(n.translation, 3) || !given(n.rotation, 4) || !given(n.scale, 3) do return false
	}
	for i in 0 ..< count {
		at := i
		for steps := 0; parent[at] >= 0; steps += 1 {
			if steps > count do return false
			at = parent[at]
		}
	}
	for skin in file.skins do for joint in skin.joints do if joint < 0 || joint >= count do return false
	if len(file.scenes) == 0 do return true
	if file.scene < 0 || file.scene >= len(file.scenes) do return false
	for root in file.scenes[file.scene].nodes do if root < 0 || root >= count || parent[root] >= 0 do return false
	return true
}

// An optional glTF number array: none, or exactly count.
@(private = "file")
given :: proc(values: []f32, count: int) -> bool {
	return len(values) == 0 || len(values) == count
}

@(private = "file")
local_matrix :: proc(n: gltf.Node) -> matrix[4, 4]f32 {
	if len(n.transform) == 16 {
		values: [16]f32
		copy(values[:], n.transform)
		return transmute(matrix[4, 4]f32)values  // column major, as glTF
	}
	t := len(n.translation) == 3 ? [3]f32{n.translation[0], n.translation[1], n.translation[2]} : 0
	r := len(n.rotation) == 4 ? quaternion(w = n.rotation[3], x = n.rotation[0], y = n.rotation[1], z = n.rotation[2]) : 1
	s := len(n.scale) == 3 ? [3]f32{n.scale[0], n.scale[1], n.scale[2]} : 1
	return linalg.matrix4_from_trs_f32(t, r, s)
}

// glTF texture i, loaded once per pack path; nil when it does not load.
@(private = "file")
texture_of :: proc(g: ^Gpu, u: Upload, a: ^Assets, file: ^gltf.Gltf, i: int, glb_path: string) -> ^sdl.GPUTexture {
	t := file.textures[i]
	image, has := t.source.?
	if extensions, extended := t.extensions.?; extended {
		if dds, is_dds := extensions.dds.?; is_dds do image, has = dds.source, true
	}
	if !has || image < 0 || image >= len(file.images) do return nil
	path, inside := gltf.uri_path(glb_path, file.images[image].uri, context.temp_allocator)
	if !inside do return nil
	return asset_texture(g, u, a, path)
}

@(private = "file")
primitive_upload :: proc(g: ^Gpu, u: Upload, file: ^gltf.Gltf, p: gltf.Primitive, textures: []^sdl.GPUTexture) -> (out: Primitive, ok: bool) {
	context.allocator = context.temp_allocator
	positions := gltf.read_accessor(file, p.attributes["POSITION"] or_else -1, [3]f32) or_return
	count := len(positions)
	vertices := make([]Vertex, count)
	for &v, i in vertices do v = {position = positions[i], weights = {1, 0, 0, 0}, color = 1}
	normals, has_normals := attribute(file, p, "NORMAL", [3]f32, count) or_return
	if has_normals {
		for &v, i in vertices do v.normal = normals[i]
	}
	if uvs, has := attribute(file, p, "TEXCOORD_0", [2]f32, count) or_return; has {
		for &v, i in vertices do v.uv = uvs[i]
	}
	if colors, has := colors_attribute(file, p, count) or_return; has {
		for &v, i in vertices do v.color = colors[i]
	}
	out.joints = 1
	if joints, has := joints_attribute(file, p, count) or_return; has {
		weights, weighted := attribute(file, p, "WEIGHTS_0", [4]f32, count) or_return
		if !weighted do return
		for &v, i in vertices {
			v.joints, v.weights = joints[i], weights[i]
			for joint in v.joints do out.joints = max(out.joints, int(joint) + 1)  // the shader reads all four
		}
	}
	indices := index_list(file, p.indices, count) or_return
	if !has_normals do smooth_normals(vertices, indices)
	if material, has := p.material.?; has {
		if material < 0 || material >= len(file.materials) do return
		mat := file.materials[material]
		if info, textured := mat.pbrMetallicRoughness.baseColorTexture.?; textured {
			if info.index < 0 || info.index >= len(textures) do return
			out.texture = textures[info.index]
		}
		// (hole material-blend :tags (render importer)) no alphaMode BLEND, and the importer does not write the TK5 passes' blend factors (additive glows, see-through parts); they draw opaque.
		out.cutout = mat.alphaMode == "MASK"
	}
	out.mesh = mesh_upload(g, u, vertices, indices) or_return
	return out, true
}

// An optional attribute: has is false when the primitive does not have it; ok is false when it does not read.
@(private = "file")
attribute :: proc(file: ^gltf.Gltf, p: gltf.Primitive, name: string, $T: typeid, count: int) -> (values: []T, has: bool, ok: bool) {
	accessor, present := p.attributes[name]
	if !present do return nil, false, true
	values = gltf.read_accessor(file, accessor, T) or_return
	return values, true, len(values) == count
}

// COLOR_0 as RGBA; RGB gets alpha 1.
@(private = "file")
colors_attribute :: proc(file: ^gltf.Gltf, p: gltf.Primitive, count: int) -> (colors: [][4]f32, has: bool, ok: bool) {
	accessor, present := p.attributes["COLOR_0"]
	if !present do return nil, false, true
	if accessor >= 0 && accessor < len(file.accessors) && file.accessors[accessor].type == "VEC3" {
		rgb := gltf.read_accessor(file, accessor, [3]f32) or_return
		colors = make([][4]f32, len(rgb))
		for c, i in rgb do colors[i] = {c.r, c.g, c.b, 1}
	} else {
		colors = gltf.read_accessor(file, accessor, [4]f32) or_return
	}
	return colors, true, len(colors) == count
}

@(private = "file")
joints_attribute :: proc(file: ^gltf.Gltf, p: gltf.Primitive, count: int) -> (joints: [][4]u16, has: bool, ok: bool) {
	accessor, present := p.attributes["JOINTS_0"]
	if !present do return nil, false, true
	if accessor >= 0 && accessor < len(file.accessors) && file.accessors[accessor].componentType == gltf.UNSIGNED_BYTE {
		bytes := gltf.read_accessor(file, accessor, [4]u8) or_return
		joints = make([][4]u16, len(bytes))
		for b, i in bytes do joints[i] = {u16(b[0]), u16(b[1]), u16(b[2]), u16(b[3])}
	} else {
		joints = gltf.read_accessor(file, accessor, [4]u16) or_return
	}
	return joints, true, len(joints) == count
}

// Triangles, every index below count; none given is the vertices in order.
@(private = "file")
index_list :: proc(file: ^gltf.Gltf, accessor: Maybe(int), count: int) -> (indices: []u32, ok: bool) {
	index, has := accessor.?
	if !has {
		indices = make([]u32, count)
		for &v, i in indices do v = u32(i)
	} else {
		if index < 0 || index >= len(file.accessors) do return
		switch file.accessors[index].componentType {
		case gltf.UNSIGNED_BYTE: indices = widen(gltf.read_accessor(file, index, u8) or_return)
		case gltf.UNSIGNED_SHORT: indices = widen(gltf.read_accessor(file, index, u16) or_return)
		case: indices = gltf.read_accessor(file, index, u32) or_return
		}
	}
	for v in indices do if int(v) >= count do return
	return indices, len(indices) % 3 == 0
}

@(private = "file")
widen :: proc(values: []$T) -> []u32 {
	out := make([]u32, len(values))
	for v, i in values do out[i] = u32(v)
	return out
}

// glTF asks for normals when a mesh has none; area weighted per vertex, so shared vertices stay shared.
@(private = "file")
smooth_normals :: proc(vertices: []Vertex, indices: []u32) {
	for i := 0; i + 2 < len(indices); i += 3 {
		a, b, c := &vertices[indices[i]], &vertices[indices[i + 1]], &vertices[indices[i + 2]]
		face := linalg.cross(b.position - a.position, c.position - a.position)
		a.normal += face
		b.normal += face
		c.normal += face
	}
	for &v in vertices do if v.normal != 0 do v.normal = linalg.normalize(v.normal)
}
