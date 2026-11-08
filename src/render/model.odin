// A glb on the GPU: its node tree, its skins, and each mesh primitive as a GPU mesh with its base color texture.
package render

import "core:c"
import "core:encoding/json"
import "core:math/linalg"
import "core:strings"
import sdl "vendor:sdl3"
import "../../vendor/cgltf"
import "../gltf"

Model :: struct {
	nodes:           []Model_Node,      // glTF order
	roots:           []int,             // the default scene's
	meshes:          [][]Primitive,     // glTF order; nodes share them
	skins:           []Model_Skin,
	swings:          []Swing_Joint,     // a joint before the joints under it
	colliders:       []Swing_Collider,
	swing_colliders: []int,             // the joints' collider lists, into colliders
}

Model_Node :: struct {
	name:     string,
	parent:   int,  // -1 for a root
	children: []int,
	local:    matrix[4, 4]f32,
	mesh:     int,  // -1: none
	skin:     int,  // -1: not skinned
	bone:     int,  // its joint in the first skin, which a scene node's bones pose; -1: none
}

Primitive :: struct {
	mesh:    Mesh,
	joints:  int,              // how many the vertices name: 1 unskinned, else the highest + 1
	texture: ^sdl.GPUTexture,  // nil: white; owned by Assets
	cutoff:  f32,              // alpha MASK: drop alpha below it; 0 keeps all
	blend:   bool,             // alpha BLEND: drawn over what is behind, after the opaque draws
	unlit:   bool,             // KHR_materials_unlit: base color only, no scene lights
}

Model_Skin :: struct {
	joints:        []int,  // nodes
	inverse_binds: []matrix[4, 4]f32,
}

// Reads the glb at path from data. Its textures come through assets; one that does not load draws white.
// Fails on a glb cgltf does not take (an index outside it, a node tree that loops, a buffer outside the glb), also a
// vertex joint past its node's skin; only triangle lists are drawn.
model_load :: proc(gpu: ^Gpu, assets: ^Assets, path: string, data: []byte) -> (model: ^Model, ok: bool) {
	file, parsed := cgltf.parse({type = .glb}, raw_data(data), uint(len(data)))
	if parsed != .success do return nil, false
	defer cgltf.free(file)
	if !glb_buffers(file) || cgltf.validate(file) != .success do return nil, false
	upload := upload_begin(gpu) or_return
	model = new(Model)
	ok = model_fill(gpu, upload, assets, model, file, path)
	ok = upload_end(upload) && ok
	if !ok {
		model_destroy(gpu, model)
		return nil, false
	}
	return model, true
}

model_destroy :: proc(gpu: ^Gpu, model: ^Model) {
	for node in model.nodes {
		delete(node.name)
		delete(node.children)
	}
	for primitives in model.meshes {
		for primitive in primitives do mesh_destroy(gpu, primitive.mesh)
		delete(primitives)
	}
	for skin in model.skins {
		delete(skin.joints)
		delete(skin.inverse_binds)
	}
	delete(model.nodes)
	delete(model.roots)
	delete(model.meshes)
	delete(model.skins)
	delete(model.swings)
	delete(model.colliders)
	delete(model.swing_colliders)
	free(model)
}

// The glb's BIN chunk is its only buffer: a pack's glb reads no other file.
@(private = "file")
glb_buffers :: proc(file: ^cgltf.data) -> bool {
	for &buffer in file.buffers {
		if buffer.uri != nil || buffer.size > uint(len(file.bin)) do return false
		buffer.data = raw_data(file.bin)
	}
	return true
}

@(private = "file")
model_fill :: proc(gpu: ^Gpu, upload: Upload, assets: ^Assets, model: ^Model, file: ^cgltf.data, path: string) -> (ok: bool) {
	model.nodes = make([]Model_Node, len(file.nodes))
	for &file_node, index in file.nodes {
		model.nodes[index] = {
			name = strings.clone_from_cstring(file_node.name),
			parent = file_node.parent != nil ? int(cgltf.node_index(file, file_node.parent)) : -1,
			children = node_indices(file, file_node.children),
			mesh = file_node.mesh != nil ? int(cgltf.mesh_index(file, file_node.mesh)) : -1,
			skin = file_node.skin != nil ? int(cgltf.skin_index(file, file_node.skin)) : -1,
			bone = -1,
		}
		cgltf.node_transform_local(&file_node, cast([^]f32)&model.nodes[index].local)
	}
	scene := file.scene
	if scene == nil && len(file.scenes) > 0 do scene = &file.scenes[0]
	if scene != nil do model.roots = node_indices(file, scene.nodes)

	model.meshes = make([][]Primitive, len(file.meshes))
	for mesh, index in file.meshes {
		primitives := make([dynamic]Primitive, 0, len(mesh.primitives))
		defer model.meshes[index] = primitives[:]  // also on a failed upload, so model_destroy frees the ones before it
		for &primitive in mesh.primitives {
			if primitive.type != .triangles do continue
			uploaded := primitive_upload(gpu, upload, assets, file, &primitive, path) or_return
			append(&primitives, uploaded)
		}
	}
	model.skins = make([]Model_Skin, len(file.skins))
	for skin, index in file.skins {
		model.skins[index].joints = node_indices(file, skin.joints)
		binds := make([]matrix[4, 4]f32, len(skin.joints))
		model.skins[index].inverse_binds = binds
		for &bind in binds do bind = 1
		accessor := skin.inverse_bind_matrices
		if accessor == nil do continue
		floats := uint(16 * len(binds))
		if accessor.type != .mat4 || cgltf.accessor_unpack_floats(accessor, cast([^]f32)raw_data(binds), floats) != floats do return false
	}
	if len(model.skins) > 0 do for joint, bone in model.skins[0].joints do model.nodes[joint].bone = bone
	swings_read(model, file) or_return
	for node in model.nodes {
		if node.mesh < 0 do continue
		joints := node.skin < 0 ? 1 : len(model.skins[node.skin].joints)
		for primitive in model.meshes[node.mesh] do if primitive.joints > joints do return false
	}
	return true
}

@(private = "file")
node_indices :: proc(file: ^cgltf.data, nodes: []^cgltf.node) -> []int {
	indices := make([]int, len(nodes))
	for node, index in nodes do indices[index] = int(cgltf.node_index(file, node))
	return indices
}

// The primitive's first attribute of the type; nil when it has none.
@(private = "file")
attribute :: proc(primitive: ^cgltf.primitive, type: cgltf.attribute_type) -> ^cgltf.accessor {
	for entry in primitive.attributes do if entry.type == type && entry.index == 0 do return entry.data
	return nil
}

// A glTF texture's image, the MSFT_texture_dds one when it names one, loaded once per pack path; nil when it does not load.
@(private = "file")
texture_of :: proc(gpu: ^Gpu, upload: Upload, assets: ^Assets, file: ^cgltf.data, texture: ^cgltf.texture, glb_path: string) -> ^sdl.GPUTexture {
	if texture == nil do return nil
	image := texture.image_
	for extension in texture.extensions[:texture.extensions_count] {
		if extension.name != "MSFT_texture_dds" do continue
		dds: struct {
			source: int,
		}
		if json.unmarshal_string(string(cstring(extension.data)), &dds, allocator = context.temp_allocator) != nil do return nil
		if dds.source < 0 || dds.source >= len(file.images) do return nil
		image = &file.images[dds.source]
	}
	if image == nil || image.uri == nil do return nil
	path, inside := gltf.uri_path(glb_path, string(image.uri), context.temp_allocator)
	if !inside do return nil
	return asset_texture(gpu, upload, assets, path)
}

// Each vertex reads its attributes as floats (normalized integers too); joints need weights, weights need joints.
@(private = "file")
primitive_upload :: proc(gpu: ^Gpu, upload: Upload, assets: ^Assets, file: ^cgltf.data, source: ^cgltf.primitive, path: string) -> (out: Primitive, ok: bool) {
	context.allocator = context.temp_allocator
	position := attribute(source, .position)
	if position == nil do return
	normal, uv, color := attribute(source, .normal), attribute(source, .texcoord), attribute(source, .color)
	joints, weights := attribute(source, .joints), attribute(source, .weights)
	if (joints == nil) != (weights == nil) do return
	for accessor in ([]^cgltf.accessor{normal, uv, color, joints, weights}) do if accessor != nil && accessor.count != position.count do return
	vertices := make([]Vertex, position.count)
	out.joints = 1
	for &vertex, index in vertices {
		element := uint(index)
		vertex.weights, vertex.color = {1, 0, 0, 0}, 1
		joint_indices: [4]c.uint
		read_all := read(position, element, vertex.position[:]) && read(normal, element, vertex.normal[:]) && read(uv, element, vertex.uv[:]) && read(color, element, vertex.color[:]) && read(weights, element, vertex.weights[:])
		if joints != nil do read_all = read_all && bool(cgltf.accessor_read_uint(joints, element, &joint_indices[0], len(joint_indices)))
		if !read_all do return
		for joint, slot in joint_indices {
			vertex.joints[slot] = u16(joint)
			out.joints = max(out.joints, int(joint) + 1)  // the shader reads all four
		}
	}
	indices := index_list(source.indices, len(vertices)) or_return
	if normal == nil do smooth_normals(vertices, indices)
	if material := source.material; material != nil {
		out.texture = texture_of(gpu, upload, assets, file, material.pbr_metallic_roughness.base_color_texture.texture, path)
		if material.alpha_mode == .mask do out.cutoff = material.alpha_cutoff
		out.blend = material.alpha_mode == .blend
		out.unlit = bool(material.unlit)
	}
	out.mesh = mesh_upload(gpu, upload, vertices, indices) or_return
	return out, true
}

// One element of an optional accessor into out; a missing accessor leaves out as it is.
@(private = "file")
read :: proc(accessor: ^cgltf.accessor, element: uint, out: []f32) -> bool {
	return accessor == nil || bool(cgltf.accessor_read_float(accessor, element, raw_data(out), uint(len(out))))
}

// Triangles, every index below count; none given is the vertices in order.
@(private = "file")
index_list :: proc(accessor: ^cgltf.accessor, count: int) -> (indices: []u32, ok: bool) {
	if accessor == nil {
		indices = make([]u32, count)
		for &entry, vertex in indices do entry = u32(vertex)
	} else {
		indices = make([]u32, accessor.count)
		if cgltf.accessor_unpack_indices(accessor, raw_data(indices), size_of(u32), accessor.count) != accessor.count do return
	}
	for entry in indices do if int(entry) >= count do return
	return indices, len(indices) % 3 == 0
}

// glTF asks for normals when a mesh has none; area weighted per vertex, so shared vertices stay shared.
@(private = "file")
smooth_normals :: proc(vertices: []Vertex, indices: []u32) {
	for index := 0; index + 2 < len(indices); index += 3 {
		first, second, third := &vertices[indices[index]], &vertices[indices[index + 1]], &vertices[indices[index + 2]]
		face := linalg.cross(second.position - first.position, third.position - first.position)
		first.normal += face
		second.normal += face
		third.normal += face
	}
	for &vertex in vertices do if vertex.normal != 0 do vertex.normal = linalg.normalize(vertex.normal)
}
