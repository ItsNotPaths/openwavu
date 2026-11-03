package tests

import "base:intrinsics"
import "core:os"
import "core:testing"
import "../src/gltf"
import "../vendor/cgltf"

// Every accessor kind the importer writes reads back through cgltf, the reader the game uses, as written.
@(test)
glb_round_trips_every_accessor :: proc(t: ^testing.T) {
	g: gltf.Gltf
	context.allocator = context.temp_allocator
	positions := [][3]f32{{-1.25, 2, 3}, {4, 5.5, -6}}
	uvs := [][2]f32{{0, 1}, {0.125, 0.5}}
	weights := [][4]f32{{0, 0.25, 0.5, 0.25}, {1, 0, 0, 0}}
	matrices := [][16]f32{{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2, 3, 4, 1}}
	bytes_values := []u8{0, 127, 255}
	joints := [][4]u16{{0, 1, 2, 3}, {4, 5, 6, 65535}}
	indices := []u16{0, 1, 65535}
	long_indices := []u32{0, 65536, 0xffffffff}
	times := []f32{0, 1}  // one per position: the animation moves the node along them
	gltf.add_accessor(&g, positions, "VEC3", with_bounds = true)
	gltf.add_accessor(&g, uvs, "VEC2")
	gltf.add_accessor(&g, weights, "VEC4")
	gltf.add_accessor(&g, matrices, "MAT4")
	gltf.add_accessor(&g, bytes_values, "SCALAR", normalized = true)
	gltf.add_accessor(&g, joints, "VEC4")
	gltf.add_accessor(&g, indices, "SCALAR")
	gltf.add_accessor(&g, long_indices, "SCALAR")
	gltf.add_accessor(&g, times, "SCALAR")
	append(&g.nodes, gltf.Node{name = "test", mesh = 0, skin = 0})
	prim := gltf.Primitive{attributes = make(map[string]int), material = 0}
	prim.attributes["POSITION"] = 0
	mesh := gltf.Mesh{name = "test"}
	append(&mesh.primitives, prim)
	append(&g.meshes, mesh)
	skin := gltf.Skin{inverseBindMatrices = 3}
	append(&skin.joints, 0)
	append(&g.skins, skin)
	append(&g.materials, gltf.Material{})
	animation := gltf.Animation{name = "test"}
	append(&animation.samplers, gltf.Sampler{input = 8, output = 0, interpolation = "LINEAR"})
	append(&animation.channels, gltf.Channel{target = {node = 0, path = "translation"}})
	append(&g.animations, animation)
	testing.expect(t, gltf.write_glb(&g, "build/roundtrip.glb"))
	defer os.remove("build/roundtrip.glb")
	data, err := os.read_entire_file("build/roundtrip.glb", context.temp_allocator)
	if !testing.expect_value(t, err, nil) do return
	file, parsed := cgltf.parse({type = .glb}, raw_data(data), uint(len(data)))
	if !testing.expect_value(t, parsed, cgltf.result.success) do return
	defer cgltf.free(file)
	for &buffer in file.buffers do buffer.data = raw_data(file.bin)
	testing.expect_value(t, cgltf.validate(file), cgltf.result.success)
	if !testing.expect_value(t, len(file.accessors), 9) do return
	compare :: proc(t: ^testing.T, accessor: ^cgltf.accessor, want: []$T) {
		E :: type_of(([^]T)(nil)[0][0]) when intrinsics.type_is_array(T) else T
		N :: size_of(T) / size_of(E)
		testing.expect_value(t, accessor.count, uint(len(want)))
		scale := accessor.normalized ? f32(max(E)) : 1
		for value, index in want {
			got: [N]f32
			ok := bool(cgltf.accessor_read_float(accessor, uint(index), &got[0], N))
			elements := transmute([N]E)value
			for component in 0 ..< N do ok = ok && got[component] * scale == f32(elements[component])
			testing.expectf(t, ok, "element %d: got %v", index, got)
		}
	}
	compare(t, &file.accessors[0], positions)
	compare(t, &file.accessors[1], uvs)
	compare(t, &file.accessors[2], weights)
	compare(t, &file.accessors[3], matrices)
	compare(t, &file.accessors[4], bytes_values)
	compare(t, &file.accessors[5], joints)
	compare(t, &file.accessors[6], indices)
	compare(t, &file.accessors[8], times)
	for index in 0 ..< len(long_indices) do testing.expect_value(t, cgltf.accessor_read_index(&file.accessors[7], uint(index)), uint(long_indices[index]))
	for &accessor, index in file.accessors {
		written := g.accessors[index]
		testing.expect_value(t, bool(accessor.normalized), written.normalized)
		testing.expect_value(t, bool(accessor.has_min), len(written.min) > 0)
		for value, component in written.min do testing.expect_value(t, f64(accessor.min[component]), value)
		for value, component in written.max do testing.expect_value(t, f64(accessor.max[component]), value)
	}
	testing.expect(t, file.nodes[0].mesh == &file.meshes[0])
	testing.expect(t, file.skins[0].inverse_bind_matrices == &file.accessors[3])
	testing.expect_value(t, file.animations[0].channels[0].target_path, cgltf.animation_path_type.translation)
}
