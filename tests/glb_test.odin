package tests

import "core:bytes"
import "core:encoding/endian"
import "core:os"
import "core:slice"
import "core:testing"
import "../src/gltf"

@(test)
glb_round_trips_every_accessor :: proc(t: ^testing.T) {
	allocator := context.allocator
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
	times := []f32{0, 0.5, 1}
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
	prim := gltf.Primitive{attributes = make(map[string]int), indices = 6, material = 0}
	prim.attributes["POSITION"] = 0
	mesh := gltf.Mesh{name = "test"}
	append(&mesh.primitives, prim)
	append(&g.meshes, mesh)
	append(&g.skins, gltf.Skin{inverseBindMatrices = 3})
	append(&g.materials, gltf.Material{})
	animation := gltf.Animation{name = "test"}
	append(&animation.samplers, gltf.Sampler{input = 8, output = 0, interpolation = "LINEAR"})
	append(&animation.channels, gltf.Channel{target = {node = 0, path = "translation"}})
	append(&g.animations, animation)
	testing.expect(t, gltf.write_glb(&g, "build/roundtrip.glb"))
	defer os.remove("build/roundtrip.glb")
	data, err := os.read_entire_file("build/roundtrip.glb", context.temp_allocator)
	if !testing.expect_value(t, err, nil) do return
	context.allocator = allocator
	h, ok := gltf.read_glb(data, context.allocator)
	if !testing.expect(t, ok) do return
	defer gltf.destroy_gltf(&h, context.allocator)
	testing.expect_value(t, len(h.accessors), 9)
	compare :: proc(t: ^testing.T, h: ^gltf.Gltf, index: int, want: []$T) {
		got, ok := gltf.read_accessor(h, index, T, context.allocator)
		defer delete(got, context.allocator)
		testing.expect(t, ok && slice.equal(got, want))
	}
	compare(t, &h, 0, positions)
	compare(t, &h, 1, uvs)
	compare(t, &h, 2, weights)
	compare(t, &h, 3, matrices)
	compare(t, &h, 4, bytes_values)
	compare(t, &h, 5, joints)
	compare(t, &h, 6, indices)
	compare(t, &h, 7, long_indices)
	compare(t, &h, 8, times)
	for a, i in h.accessors {
		testing.expect_value(t, a.type, g.accessors[i].type)
		testing.expect_value(t, a.normalized, g.accessors[i].normalized)
		testing.expect(t, slice.equal(a.min, g.accessors[i].min) && slice.equal(a.max, g.accessors[i].max))
	}
	testing.expect(t, bytes.equal(h.bin[:], g.bin[:]))
	testing.expect_value(t, h.nodes[0].mesh, Maybe(int)(0))
	testing.expect_value(t, h.meshes[0].primitives[0].attributes["POSITION"], 0)
	testing.expect_value(t, h.skins[0].inverseBindMatrices, Maybe(int)(3))
	testing.expect_value(t, h.animations[0].channels[0].target.path, "translation")
}

@(test)
glb_accessor_checks_offsets_stride_and_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	g: gltf.Gltf
	values := [][4]f32{{9, 1, 2, 0}, {9, 3, 4, 0}}
	gltf.add_accessor(&g, values, "VEC4")
	g.accessors[0].type = "VEC2"
	g.accessors[0].byteOffset = 4
	g.bufferViews[0].byteStride = 16
	got, ok := gltf.read_accessor(&g, 0, [2]f32)
	testing.expect(t, ok && slice.equal(got, [][2]f32{{1, 2}, {3, 4}}))
	_, ok = gltf.read_accessor(&g, 0, [2]u32)
	testing.expect(t, !ok)
	g.accessors[0].count = 3
	_, ok = gltf.read_accessor(&g, 0, [2]f32)
	testing.expect(t, !ok)
}

@(test)
glb_refuses_bad_chunks_and_json :: proc(t: ^testing.T) {
	allocator := context.allocator
	context.allocator = context.temp_allocator
	g: gltf.Gltf
	gltf.add_accessor(&g, []u16{0, 1, 2}, "SCALAR")
	testing.expect(t, gltf.write_glb(&g, "build/bad.glb"))
	defer os.remove("build/bad.glb")
	data, err := os.read_entire_file("build/bad.glb", context.temp_allocator)
	if !testing.expect_value(t, err, nil) do return
	context.allocator = allocator
	for size in 0 ..< len(data) {
		h, ok := gltf.read_glb(data[:size], context.allocator)
		testing.expect(t, !ok && len(h.accessors) == 0)
	}
	data[20] = '!'
	_, ok := gltf.read_glb(data, context.allocator)
	testing.expect(t, !ok)
	data[20] = '{'
	endian.put_u32(data[12:], .Little, 0xffffffff)
	_, ok = gltf.read_glb(data, context.allocator)
	testing.expect(t, !ok)
}
