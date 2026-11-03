// A pack's assets for the scene: the files its scenes name by id, loaded on first use and kept until the pack closes.
package render

import "core:c"
import "core:strings"
import stbi "vendor:stb/image"
import sdl "vendor:sdl3"
import "../dds"
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
	a.textures[strings.clone(path, a.textures.allocator)] = t
	return t
}

@(private = "file", rodata)
DDS_FORMATS := [dds.Format]sdl.GPUTextureFormat{.BC1 = .BC1_RGBA_UNORM, .BC2 = .BC2_RGBA_UNORM, .BC3 = .BC3_RGBA_UNORM, .RGBA8 = COLOR_FORMAT}

@(private = "file")
dds_texture :: proc(g: ^Gpu, u: Upload, data: []byte) -> ^sdl.GPUTexture {
	image, ok := dds.read(data)
	format := DDS_FORMATS[image.format]
	if !ok || !sdl.GPUTextureSupportsFormat(g.device, format, .D2, {.SAMPLER}) do return nil
	pixels := image.data
	if image.bgra {
		pixels = make([]byte, len(image.data), context.temp_allocator)
		for i := 0; i < len(pixels); i += 4 do pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] = image.data[i + 2], image.data[i + 1], image.data[i], image.data[i + 3]
	}
	t, _ := texture_upload(g, u, format, pixels, u32(image.width), u32(image.height))
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
