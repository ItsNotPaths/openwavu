package tests

import "core:bytes"
import "core:encoding/endian"
import "core:encoding/json"
import "core:image/png"
import "core:os"
import "core:slice"
import "core:testing"
import "../src/convert"
import "../src/gltf"

@(test)
png_round_trips :: proc(t: ^testing.T) {
	w, h := 5, 3
	rgba := make([]byte, w * h * 4, context.temp_allocator)
	for &b, i in rgba do b = u8(i * 7)
	data := convert.encode_png(rgba, w, h, context.temp_allocator)
	img, err := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	testing.expect_value(t, err, nil)
	if err != nil do return
	testing.expect(t, img.width == w && img.height == h && bytes.equal(img.pixels.buf[:], rgba), "PNG pixels differ")
}

// DXT blocks go in as stored, behind a header any DDS reader takes: size, four cc, linear size.
@(test)
dds_keeps_blocks :: proc(t: ^testing.T) {
	blocks := make([]byte, 2 * 1 * 16, context.temp_allocator)  // 8x4 texels of DXT5
	for &b, i in blocks do b = u8(i)
	data := convert.encode_dds(.BC3, 8, 4, blocks, context.temp_allocator)
	u32_at :: proc(d: []byte, offset: int) -> u32 {v, _ := endian.get_u32(d[offset:], .Little); return v}
	testing.expect_value(t, string(data[:4]), "DDS ")
	testing.expect_value(t, u32_at(data, 12), 4)  // height
	testing.expect_value(t, u32_at(data, 16), 8)  // width
	testing.expect_value(t, u32_at(data, 20), 32)  // linear size
	testing.expect_value(t, string(data[84:][:4]), "DXT5")
	testing.expect(t, bytes.equal(data[128:], blocks), "DDS blocks differ")
}

// One triangle; the chunks and the JSON must follow the glb layout.
@(test)
glb_layout_is_valid :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	g: gltf.Gltf
	positions := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}
	uvs := [][2]f32{{0, 0}, {1, 0}, {0, 1}}
	indices := []u16{0, 1, 2}
	prim := gltf.Primitive{attributes = make(map[string]int, context.temp_allocator), material = 0}
	prim.attributes["POSITION"] = gltf.add_accessor(&g, positions, "VEC3", gltf.ARRAY_BUFFER, with_bounds = true)
	prim.attributes["TEXCOORD_0"] = gltf.add_accessor(&g, uvs, "VEC2", gltf.ARRAY_BUFFER)
	prim.indices = gltf.add_accessor(&g, indices, "SCALAR", gltf.ELEMENT_ARRAY_BUFFER)
	append(&g.materials, gltf.Material{})
	mesh := gltf.Mesh{name = "tri"}
	append(&mesh.primitives, prim)
	append(&g.meshes, mesh)
	append(&g.nodes, gltf.Node{name = "tri", mesh = 0})
	scene: gltf.Scene
	append(&scene.nodes, 0)
	append(&g.scenes, scene)
	testing.expect(t, gltf.write_glb(&g, "build/test.glb"))

	data, err := os.read_entire_file("build/test.glb", context.temp_allocator)
	if !testing.expect_value(t, err, nil) do return
	os.remove("build/test.glb")
	u32le :: proc(b: []byte, off: int) -> int {v, _ := endian.get_u32(b[off:], .Little); return int(v)}
	testing.expect_value(t, string(data[:4]), "glTF")
	testing.expect_value(t, u32le(data, 8), len(data))
	json_len := u32le(data, 12)
	testing.expect(t, json_len % 4 == 0 && string(data[16:20]) == "JSON")
	bin := 20 + json_len
	testing.expect(t, string(data[bin + 4:bin + 8]) == "BIN\x00" && u32le(data, bin) % 4 == 0)
	_, perr := json.parse(data[20:bin], allocator = context.temp_allocator)
	testing.expect_value(t, perr, nil)
}

@(test)
anim_round_trips :: proc(t: ^testing.T) {
	channels := []convert.Anim_Channel{{.Position, 3, 0}, {.Quaternion, 4, 3}}
	values := []f32{1, 2, 3, 0, 0, 0, 1, 4, 5, 6, 0, 1, 0, 0}
	a := convert.Anim{layout = "test", frames = 2, fps = 60, position_unit = 0.001, channels = channels, values = values}
	testing.expect(t, convert.write_anim("build/test.anim", a))
	data, err := os.read_entire_file("build/test.anim", context.temp_allocator)
	os.remove("build/test.anim")
	if !testing.expect_value(t, err, nil) do return
	b, ok := convert.read_anim(data, context.temp_allocator)
	testing.expect(t, ok && b.layout == "test" && b.frames == 2 && b.fps == 60 && b.position_unit == 0.001)
	testing.expect(t, slice.equal(b.channels, channels) && slice.equal(b.values, values), "anim changed in the round trip")
}
