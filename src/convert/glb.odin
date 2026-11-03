// glTF 2.0 binary reader and writer. Build a Gltf with the add_* procs, then write_glb. Metres, Y up.
package convert

import "core:encoding/endian"
import "core:encoding/json"
import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:os"
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
	extras:      json.Object `json:",omitempty"`,
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
	pbrMetallicRoughness: struct {metallicFactor: f32},
	doubleSided:          bool,
	extras:               json.Object `json:",omitempty"`,  // raw game material data
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
	byteStride: int `json:",omitempty"`,
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

read_glb :: proc(data: []byte, allocator := context.allocator) -> (g: Gltf, ok: bool) {
	context.allocator = allocator
	defer if !ok do destroy_gltf(&g)  // the caller drops g
	if len(data) < 20 || string(data[:4]) != "glTF" do return
	version, _ := endian.get_u32(data[4:], .Little)
	length, _ := endian.get_u32(data[8:], .Little)
	if version != 2 || int(length) != len(data) do return
	json_seen, bin_seen := false, false
	for off := 12; off < len(data); {
		if len(data) - off < 8 do return
		size, _ := endian.get_u32(data[off:], .Little)
		type := string(data[off + 4:off + 8])
		off += 8
		if size % 4 != 0 || int(size) > len(data) - off do return
		chunk := data[off:off + int(size)]
		if !json_seen && type != "JSON" do return
		switch type {
		case "JSON":
			if json_seen || json.unmarshal(chunk, &g, allocator = allocator) != nil do return
			json_seen = true
		case "BIN\x00":
			if bin_seen do return
			append(&g.bin, ..chunk)
			bin_seen = true
		}
		off += int(size)
	}
	if g.asset.version != "2.0" || len(g.buffers) > 1 do return
	if len(g.buffers) == 1 {
		size := g.buffers[0].byteLength
		if size < 0 || size > len(g.bin) || len(g.bin) - size > 3 do return
	} else if len(g.bin) != 0 do return
	for view in g.bufferViews {
		if view.buffer != 0 || len(g.buffers) == 0 || view.byteOffset < 0 || view.byteLength < 0 do return
		if view.byteOffset > g.buffers[0].byteLength || view.byteLength > g.buffers[0].byteLength - view.byteOffset do return
	}
	ok = json_seen
	return
}

// Accessor values are copied without normalization; the caller owns the slice.
read_accessor :: proc(g: ^Gltf, index: int, $T: typeid, allocator := context.allocator) -> (values: []T, ok: bool) {
	if index < 0 || index >= len(g.accessors) do return nil, false
	a := g.accessors[index]
	if a.componentType != accessor_component(T) || a.count < 0 || a.byteOffset < 0 do return nil, false
	if a.bufferView < 0 || a.bufferView >= len(g.bufferViews) do return nil, false
	components: int
	switch a.type {
	case "SCALAR": components = 1
	case "VEC2": components = 2
	case "VEC3": components = 3
	case "VEC4", "MAT2": components = 4
	case "MAT3": components = 9
	case "MAT4": components = 16
	case: return nil, false
	}
	E :: type_of(([^]T)(nil)[0][0]) when intrinsics.type_is_array(T) else T
	if components * size_of(E) != size_of(T) do return nil, false
	view := g.bufferViews[a.bufferView]
	if view.buffer != 0 || view.byteOffset < 0 || view.byteLength < 0 || view.byteOffset > len(g.bin) || view.byteLength > len(g.bin) - view.byteOffset do return nil, false
	stride := view.byteStride == 0 ? size_of(T) : view.byteStride
	if stride < size_of(T) || stride % size_of(E) != 0 || a.byteOffset % size_of(E) != 0 do return nil, false
	if a.byteOffset > view.byteLength do return nil, false
	available := view.byteLength - a.byteOffset
	if a.count > 0 && (available < size_of(T) || a.count - 1 > (available - size_of(T)) / stride) do return nil, false
	values = make([]T, a.count, allocator)
	for &v, i in values {
		off := view.byteOffset + a.byteOffset + i * stride
		copy((cast([^]byte)&v)[:size_of(T)], g.bin[off:off + size_of(T)])
	}
	return values, true
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

// Releases a Gltf whose strings and arrays are owned, as returned by read_glb.
destroy_gltf :: proc(g: ^Gltf, allocator := context.allocator) {
	context.allocator = allocator
	delete(g.asset.version)
	delete(g.asset.generator)
	for scene in g.scenes do delete(scene.nodes)
	for node in g.nodes {
		delete(node.name)
		delete(node.children)
		delete(node.transform)
		delete(node.translation)
		delete(node.rotation)
		delete(node.scale)
		json.destroy_value(node.extras)
	}
	for mesh in g.meshes {
		delete(mesh.name)
		for primitive in mesh.primitives {
			for key in primitive.attributes do delete(key)
			delete(primitive.attributes)
		}
		delete(mesh.primitives)
	}
	for material in g.materials {
		delete(material.name)
		json.destroy_value(material.extras)
	}
	for skin in g.skins do delete(skin.joints)
	for animation in g.animations {
		delete(animation.name)
		for channel in animation.channels do delete(channel.target.path)
		for sampler in animation.samplers do delete(sampler.interpolation)
		delete(animation.channels)
		delete(animation.samplers)
	}
	for accessor in g.accessors {
		delete(accessor.type)
		delete(accessor.min)
		delete(accessor.max)
	}
	delete(g.scenes)
	delete(g.nodes)
	delete(g.meshes)
	delete(g.materials)
	delete(g.skins)
	delete(g.animations)
	delete(g.accessors)
	delete(g.bufferViews)
	delete(g.buffers)
	delete(g.bin)
	g^ = {}
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
