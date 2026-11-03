// A pack's assets for the scene: the files its scenes name by id, loaded on first use and kept until the pack closes.
package render

import "core:c"
import "core:encoding/endian"
import "core:strings"
import stbi "vendor:stb/image"
import sdl "vendor:sdl3"
import "../titlepack"

Assets :: struct {
	files:    titlepack.Pack_Files,
	paths:    [dynamic]string,              // an asset id is index + 1
	ids:      map[string]u32,
	models:   map[u32]^Model,               // nil: does not load
	textures: map[string]^sdl.GPUTexture,   // by pack path, shared by the models; nil: does not load
}

// The maps grow with the allocator they are made with here, also from import callbacks.
assets_create :: proc(files: titlepack.Pack_Files) -> Assets {
	return {
		files = files,
		paths = make([dynamic]string),
		ids = make(map[string]u32),
		models = make(map[u32]^Model),
		textures = make(map[string]^sdl.GPUTexture),
	}
}

// g: the GPU the models and textures were loaded on; nil when none were.
assets_destroy :: proc(a: ^Assets, g: ^Gpu) {
	for _, m in a.models do if m != nil do model_destroy(g, m)
	for path, t in a.textures {
		if t != nil do sdl.ReleaseGPUTexture(g.device, t)
		delete(path)
	}
	for path in a.paths do delete(path)
	delete(a.paths)
	delete(a.ids)
	delete(a.models)
	delete(a.textures)
}

// The id of a pack file, the same for the same path; 0 when the pack has no such file.
asset_id :: proc(a: ^Assets, path: string) -> u32 {
	if id, known := a.ids[path]; known do return id
	if _, found := titlepack.read_file(a.files, path); !found do return 0
	append(&a.paths, strings.clone(path, a.paths.allocator))
	id := u32(len(a.paths))
	a.ids[a.paths[id - 1]] = id
	return id
}

// The glb of an asset id, loaded on first use; nil when the id is unknown or the file is no model.
asset_model :: proc(a: ^Assets, g: ^Gpu, id: u32) -> ^Model {
	if m, tried := a.models[id]; tried do return m
	if id == 0 || int(id) > len(a.paths) do return nil
	path := a.paths[id - 1]
	m: ^Model
	if data, found := titlepack.read_file(a.files, path); found do m, _ = model_load(g, a, path, data)
	a.models[id] = m
	return m
}

// A DDS, PNG or JPEG file as a texture, loaded once per path; nil when it does not load.
@(private = "package")
asset_texture :: proc(g: ^Gpu, u: Upload, a: ^Assets, path: string) -> ^sdl.GPUTexture {
	if t, tried := a.textures[path]; tried do return t
	t: ^sdl.GPUTexture
	if data, found := titlepack.read_file(a.files, path); found {
		if strings.has_suffix(path, ".dds") {
			t = dds_texture(g, u, data)
		} else {
			t = image_texture(g, u, data)
		}
	}
	a.textures[strings.clone(path, a.paths.allocator)] = t
	return t
}

// The top mip of a DDS: DXT1, DXT3 or DXT5 blocks as stored, or 32-bit RGBA or BGRA pixels.
@(private = "file")
dds_texture :: proc(g: ^Gpu, u: Upload, data: []byte) -> ^sdl.GPUTexture {
	HEADER :: 4 + 124
	if len(data) < HEADER || string(data[:4]) != "DDS " do return nil
	field :: proc(data: []byte, offset: int) -> int {
		v, _ := endian.get_u32(data[4 + offset:], .Little)
		return int(v)
	}
	height, width := field(data, 8), field(data, 12)
	if width == 0 || height == 0 || width > 16384 || height > 16384 do return nil
	blocks := ((width + 3) / 4) * ((height + 3) / 4)
	format: sdl.GPUTextureFormat
	size: int
	pixels := data[HEADER:]
	if field(data, 76) & 0x4 != 0 {
		switch string(data[4 + 80:][:4]) {
		case "DXT1": format, size = .BC1_RGBA_UNORM, blocks * 8
		case "DXT3": format, size = .BC2_RGBA_UNORM, blocks * 16
		case "DXT5": format, size = .BC3_RGBA_UNORM, blocks * 16
		case: return nil
		}
	} else {
		if field(data, 84) != 32 do return nil
		format, size = COLOR_FORMAT, width * height * 4
		if len(pixels) < size do return nil
		red, blue := field(data, 88), field(data, 96)
		switch {
		case red == 0xff && blue == 0xff0000:
		case red == 0xff0000 && blue == 0xff:
			swapped := make([]byte, size, context.temp_allocator)
			for i := 0; i < size; i += 4 do swapped[i], swapped[i + 1], swapped[i + 2], swapped[i + 3] = pixels[i + 2], pixels[i + 1], pixels[i], pixels[i + 3]
			pixels = swapped
		case: return nil
		}
	}
	if len(pixels) < size || !sdl.GPUTextureSupportsFormat(g.device, format, .D2, {.SAMPLER}) do return nil
	t, _ := texture_upload(g, u, format, pixels[:size], u32(width), u32(height))
	return t
}

@(private = "file")
image_texture :: proc(g: ^Gpu, u: Upload, data: []byte) -> ^sdl.GPUTexture {
	w, h, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return nil
	defer stbi.image_free(pixels)
	t, _ := texture_upload(g, u, COLOR_FORMAT, pixels[:w * h * 4], u32(w), u32(h))
	return t
}
