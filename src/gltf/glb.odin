// glTF 2.0 binary writer: build a Gltf with the add_* procs, then write_glb. Metres, Y up. The game reads glbs with cgltf.
package gltf

import "core:encoding/endian"
import "core:encoding/json"
import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strconv"
import "core:strings"

FLOAT :: 5126
UNSIGNED_BYTE :: 5121
UNSIGNED_SHORT :: 5123
UNSIGNED_INT :: 5125
ARRAY_BUFFER :: 34962
ELEMENT_ARRAY_BUFFER :: 34963
TRIANGLES :: 4

Gltf :: struct {
	asset:              struct {version, generator: string},
	scene:              Maybe(int) `json:",omitempty"`,  // write_glb sets it when there are scenes
	scenes:             [dynamic]Scene `json:",omitempty"`,
	nodes:              [dynamic]Node `json:",omitempty"`,
	meshes:             [dynamic]Mesh `json:",omitempty"`,
	materials:          [dynamic]Material `json:",omitempty"`,
	textures:           [dynamic]Texture `json:",omitempty"`,
	images:             [dynamic]Image `json:",omitempty"`,
	skins:              [dynamic]Skin `json:",omitempty"`,
	animations:         [dynamic]Animation `json:",omitempty"`,
	accessors:          [dynamic]Accessor `json:",omitempty"`,
	bufferViews:        [dynamic]Buffer_View `json:",omitempty"`,
	buffers:            [dynamic]Buffer `json:",omitempty"`,
	extensionsUsed:     [dynamic]string `json:",omitempty"`,
	extensionsRequired: [dynamic]string `json:",omitempty"`,
	bin:                [dynamic]byte `json:"-"`,
}

Scene :: struct {nodes: [dynamic]int}
Node :: struct {
	name:        string `json:",omitempty"`,
	children:    [dynamic]int `json:",omitempty"`,
	mesh:        Maybe(int) `json:",omitempty"`,
	skin:        Maybe(int) `json:",omitempty"`,
	transform:   []f32 `json:"matrix,omitempty"`,  // column major
	translation: []f32 `json:",omitempty"`,
	rotation:    []f32 `json:",omitempty"`,  // quaternion xyzw
	scale:       []f32 `json:",omitempty"`,
	extras:      json.Object `json:",omitempty"`,
}
Mesh :: struct {
	name:       string `json:",omitempty"`,
	primitives: [dynamic]Primitive,
}
Primitive :: struct {
	attributes: map[string]int,
	mode:       Maybe(int) `json:",omitempty"`,  // TRIANGLES when none
	indices:    Maybe(int) `json:",omitempty"`,
	material:   Maybe(int) `json:",omitempty"`,
}
Material :: struct {
	name:                 string `json:",omitempty"`,
	pbrMetallicRoughness: struct {
		baseColorTexture: Maybe(Texture_Info) `json:",omitempty"`,
		metallicFactor:   f32,
	},
	alphaMode:            string `json:",omitempty"`,  // OPAQUE when empty; MASK cuts out below alphaCutoff
	alphaCutoff:          Maybe(f32) `json:",omitempty"`,  // 0.5 when none
	doubleSided:          bool,
	extensions:           Maybe(Material_Extensions) `json:",omitempty"`,
	extras:               json.Object `json:",omitempty"`,  // raw game material data
}
Material_Extensions :: struct {unlit: Maybe(struct {}) `json:"KHR_materials_unlit,omitempty"`}
UNLIT_EXTENSION :: "KHR_materials_unlit"

// Draws the material as its base color, with no scene lights (baked lighting).
set_unlit :: proc(g: ^Gltf, material: ^Material) {
	material.extensions = Material_Extensions{unlit = struct {}{}}
	if !slice.contains(g.extensionsUsed[:], UNLIT_EXTENSION) do append(&g.extensionsUsed, UNLIT_EXTENSION)
}
Texture_Info :: struct {index: int}
// source: a PNG or JPEG image; a DDS one comes through MSFT_texture_dds.
Texture :: struct {
	source:     Maybe(int) `json:",omitempty"`,
	extensions: Maybe(Texture_Extensions) `json:",omitempty"`,
}
Texture_Extensions :: struct {dds: Maybe(Texture_Source) `json:"MSFT_texture_dds,omitempty"`}
Texture_Source :: struct {source: int}

DDS_EXTENSION :: "MSFT_texture_dds"
Image :: struct {uri: string}  // relative to the glb
Skin :: struct {
	joints:              [dynamic]int,
	inverseBindMatrices: Maybe(int) `json:",omitempty"`,
	skeleton:            Maybe(int) `json:",omitempty"`,
}
Animation :: struct {
	name:     string `json:",omitempty"`,
	channels: [dynamic]Channel,
	samplers: [dynamic]Sampler,
}
Channel :: struct {
	sampler: int,
	target:  struct {node: int, path: string},
}
Sampler :: struct {
	input, output: int,
	interpolation: string,
}
Accessor :: struct {
	bufferView:    int,
	componentType: int,
	byteOffset:    int `json:",omitempty"`,
	normalized:    bool `json:",omitempty"`,
	count:         int,
	type:          string,
	min:           []f64 `json:",omitempty"`,  // f64: the JSON then reads back to the exact f32
	max:           []f64 `json:",omitempty"`,
}
Buffer_View :: struct {
	buffer:     int,
	byteOffset: int,
	byteLength: int,
	target:     Maybe(int) `json:",omitempty"`,
}
Buffer :: struct {byteLength: int}

// JSON floats in the shortest form that reads back exactly; json.marshal prints fixed point.
@(init, private = "file")
register_float_marshalers :: proc "contextless" () {
	context = runtime.default_context()
	json.set_user_marshalers(new(map[typeid]json.User_Marshaler))
	json.register_user_marshaler(f32, write_float)
	json.register_user_marshaler(f64, write_float)
}

@(private = "file")
write_float :: proc(w: io.Writer, v: any, _: ^json.Marshal_Options) -> json.Marshal_Error {
	buf: [32]byte
	text: string
	switch f in v {
	case f32: text = strconv.write_float(buf[:], f64(f), 'g', -1, 32)
	case f64: text = strconv.write_float(buf[:], f, 'g', -1, 64)
	}
	if text[0] == '+' do text = text[1:]
	_, err := io.write_string(w, text)
	return err
}

@(private = "file")
accessor_component :: proc($T: typeid) -> int {
	E :: type_of(([^]T)(nil)[0][0]) when intrinsics.type_is_array(T) else T
	when E == f32 do return FLOAT
	else when E == u8 do return UNSIGNED_BYTE
	else when E == u16 do return UNSIGNED_SHORT
	else when E == u32 do return UNSIGNED_INT
	else do #panic("unsupported accessor element")
}

// Appends data to the binary chunk, 4-byte aligned. Returns the buffer view index.
add_view :: proc(g: ^Gltf, data: []byte, target: Maybe(int) = nil) -> int {
	for len(g.bin) % 4 != 0 do append(&g.bin, 0)
	append(&g.bin, ..data)
	append(&g.bufferViews, Buffer_View{byteOffset = len(g.bin) - len(data), byteLength = len(data), target = target})
	return len(g.bufferViews) - 1
}

// One accessor over a new buffer view. T is f32, u8, u16, u32 or a fixed array of them.
add_accessor :: proc(g: ^Gltf, data: []$T, type: string, target: Maybe(int) = nil, normalized := false, with_bounds := false) -> int {
	E :: type_of(([^]T)(nil)[0][0]) when intrinsics.type_is_array(T) else T
	component := accessor_component(T)

	view := add_view(g, ([^]byte)(raw_data(data))[:len(data) * size_of(T)], target)
	a := Accessor{bufferView = view, componentType = component, normalized = normalized, count = len(data), type = type}
	when E == f32 {
		if with_bounds && len(data) > 0 {
			N :: size_of(T) / size_of(f32)
			lo, hi := make([]f64, N), make([]f64, N)
			for v, i in data {
				c := transmute([N]f32)v
				for k in 0 ..< N {
					if i == 0 || f64(c[k]) < lo[k] do lo[k] = f64(c[k])
					if i == 0 || f64(c[k]) > hi[k] do hi[k] = f64(c[k])
				}
			}
			a.min, a.max = lo, hi
		}
	}
	append(&g.accessors, a)
	return len(g.accessors) - 1
}

// A texture over a DDS file, which no viewer can read without the extension. uri: relative to the glb.
add_dds_texture :: proc(g: ^Gltf, uri: string) -> int {
	if !slice.contains(g.extensionsRequired[:], DDS_EXTENSION) {
		append(&g.extensionsUsed, DDS_EXTENSION)
		append(&g.extensionsRequired, DDS_EXTENSION)
	}
	append(&g.images, Image{uri = uri})
	append(&g.textures, Texture{extensions = Texture_Extensions{dds = Texture_Source{len(g.images) - 1}}})
	return len(g.textures) - 1
}

// The uri from the glb at glb_path to the file at path, both pack paths.
relative_uri :: proc(glb_path, path: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for _ in 0 ..< strings.count(glb_path, "/") do strings.write_string(&b, "../")
	strings.write_string(&b, path)
	return strings.to_string(b)
}

// The pack path of the file a uri in the glb at glb_path names; false for a uri that leaves the pack.
uri_path :: proc(glb_path, uri: string, allocator := context.allocator) -> (path: string, ok: bool) {
	dir := slashpath.dir(glb_path, context.temp_allocator)
	path = slashpath.join({dir, uri}, allocator)
	if path == ".." || strings.has_prefix(path, "../") || strings.has_prefix(path, "/") || strings.contains(uri, ":") {
		delete(path, allocator)
		return "", false
	}
	return path, true
}

write_glb :: proc(g: ^Gltf, path: string) -> (ok: bool) {
	g.asset = {version = "2.0", generator = "openwavu"}
	if len(g.scenes) > 0 && g.scene == nil do g.scene = 0
	for len(g.bin) % 4 != 0 do append(&g.bin, 0)
	clear(&g.buffers)
	append(&g.buffers, Buffer{byteLength = len(g.bin)})
	text, err := json.marshal(g^, {sort_maps_by_key = true}, context.temp_allocator)
	if err != nil do return false
	pad := (4 - len(text) % 4) % 4

	out := make([dynamic]byte, 0, 28 + len(text) + pad + len(g.bin), context.temp_allocator)
	put32 :: proc(out: ^[dynamic]byte, v: int) {
		b: [4]byte
		endian.put_u32(b[:], .Little, u32(v))
		append(out, ..b[:])
	}
	append(&out, "glTF")
	put32(&out, 2)
	put32(&out, 28 + len(text) + pad + len(g.bin))
	put32(&out, len(text) + pad)
	append(&out, "JSON")
	append(&out, ..text)
	for _ in 0 ..< pad do append(&out, ' ')
	put32(&out, len(g.bin))
	append(&out, "BIN\x00")
	append(&out, ..g.bin[:])
	return os.write_entire_file(path, out[:]) == nil
}
