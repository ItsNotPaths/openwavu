// glTF 2.0 binary writer. Build a Gltf with the add_* procs, then write_glb. Metres, Y up.
package convert

import "core:encoding/endian"
import "core:encoding/json"
import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:os"
import "core:slice"
import "core:strconv"

FLOAT :: 5126
UNSIGNED_BYTE :: 5121
UNSIGNED_SHORT :: 5123
UNSIGNED_INT :: 5125
ARRAY_BUFFER :: 34962
ELEMENT_ARRAY_BUFFER :: 34963

Gltf :: struct {
	asset:       struct {version, generator: string},
	scene:       int,
	scenes:      [dynamic]Scene `json:",omitempty"`,
	nodes:       [dynamic]Node `json:",omitempty"`,
	meshes:      [dynamic]Mesh `json:",omitempty"`,
	materials:   [dynamic]Material `json:",omitempty"`,
	textures:    [dynamic]Texture `json:",omitempty"`,
	images:      [dynamic]Image `json:",omitempty"`,
	skins:       [dynamic]Skin `json:",omitempty"`,
	animations:  [dynamic]Animation `json:",omitempty"`,
	accessors:   [dynamic]Accessor `json:",omitempty"`,
	bufferViews: [dynamic]Buffer_View `json:",omitempty"`,
	buffers:     [dynamic]Buffer `json:",omitempty"`,
	bin:         [dynamic]byte `json:"-"`,
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
}
Mesh :: struct {
	name:       string `json:",omitempty"`,
	primitives: [dynamic]Primitive,
}
Primitive :: struct {
	attributes: map[string]int,
	indices:    Maybe(int) `json:",omitempty"`,
	material:   Maybe(int) `json:",omitempty"`,
}
Material :: struct {
	name:                 string `json:",omitempty"`,
	pbrMetallicRoughness: struct {
		baseColorTexture: Maybe(Texture_Ref) `json:",omitempty"`,
		metallicFactor:   f32,
	},
	alphaMode:            string `json:",omitempty"`,
	doubleSided:          bool,
	extras:               json.Object `json:",omitempty"`,  // raw game material data
}
Texture_Ref :: struct {index: int}
Texture :: struct {source: int}
Image :: struct {
	name:       string `json:",omitempty"`,
	bufferView: int,
	mimeType:   string,
}
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
	component: int
	when E == f32 do component = FLOAT
	else when E == u8 do component = UNSIGNED_BYTE
	else when E == u16 do component = UNSIGNED_SHORT
	else when E == u32 do component = UNSIGNED_INT
	else do #panic("unsupported accessor element")

	view := add_view(g, slice.to_bytes(data), target)
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

add_png :: proc(g: ^Gltf, name: string, png: []byte) -> (texture: int) {
	append(&g.images, Image{name = name, bufferView = add_view(g, png), mimeType = "image/png"})
	append(&g.textures, Texture{source = len(g.images) - 1})
	return len(g.textures) - 1
}

write_glb :: proc(g: ^Gltf, path: string) -> (ok: bool) {
	g.asset = {version = "2.0", generator = "openwavu"}
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
