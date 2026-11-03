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
assets_destroy :: proc(assets: ^Assets, gpu: ^Gpu) {
	for _, model in assets.models do if model != nil do model_destroy(gpu, model)
	for path, texture in assets.textures {
		if texture != nil do sdl.ReleaseGPUTexture(gpu.device, texture)
		delete(path)
	}
	for path in assets.paths do delete(path)
	delete(assets.paths)
	delete(assets.ids)
	delete(assets.models)
	delete(assets.textures)
}

// The id of a pack file, the same for the same path; 0 when the pack has no such file.
asset_id :: proc(assets: ^Assets, path: string) -> u32 {
	if id, known := assets.ids[path]; known do return id
	if _, found := titlepack.read_file(assets.files, path); !found do return 0
	append(&assets.paths, strings.clone(path, assets.paths.allocator))
	id := u32(len(assets.paths))
	assets.ids[assets.paths[id - 1]] = id
	return id
}

// The glb of an asset id, loaded on first use; nil when the id is unknown or the file is no model.
asset_model :: proc(assets: ^Assets, gpu: ^Gpu, id: u32) -> ^Model {
	if model, tried := assets.models[id]; tried do return model
	if id == 0 || int(id) > len(assets.paths) do return nil
	path := assets.paths[id - 1]
	model: ^Model
	if data, found := titlepack.read_file(assets.files, path); found do model, _ = model_load(gpu, assets, path, data)
	assets.models[id] = model
	return model
}

// A DDS, PNG or JPEG file as a texture, loaded once per path; nil when it does not load.
@(private = "package")
asset_texture :: proc(gpu: ^Gpu, upload: Upload, assets: ^Assets, path: string) -> ^sdl.GPUTexture {
	if texture, tried := assets.textures[path]; tried do return texture
	texture: ^sdl.GPUTexture
	if data, found := titlepack.read_file(assets.files, path); found {
		if strings.has_suffix(path, ".dds") {
			texture = dds_texture(gpu, upload, data)
		} else {
			texture = image_texture(gpu, upload, data)
		}
	}
	assets.textures[strings.clone(path, assets.textures.allocator)] = texture
	return texture
}

@(private = "file", rodata)
DDS_FORMATS := [dds.Format]sdl.GPUTextureFormat{.BC1 = .BC1_RGBA_UNORM, .BC2 = .BC2_RGBA_UNORM, .BC3 = .BC3_RGBA_UNORM, .RGBA8 = COLOR_FORMAT}

@(private = "file")
dds_texture :: proc(gpu: ^Gpu, upload: Upload, data: []byte) -> ^sdl.GPUTexture {
	image, ok := dds.read(data)
	format := DDS_FORMATS[image.format]
	if !ok || !sdl.GPUTextureSupportsFormat(gpu.device, format, .D2, {.SAMPLER}) do return nil
	pixels := image.data
	if image.bgra {
		pixels = make([]byte, len(image.data), context.temp_allocator)
		for index := 0; index < len(pixels); index += 4 do pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3] = image.data[index + 2], image.data[index + 1], image.data[index], image.data[index + 3]
	}
	texture, _ := texture_upload(gpu, upload, format, pixels, u32(image.width), u32(image.height))
	return texture
}

@(private = "file")
image_texture :: proc(gpu: ^Gpu, upload: Upload, data: []byte) -> ^sdl.GPUTexture {
	width, height, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 4)
	if pixels == nil do return nil
	defer stbi.image_free(pixels)
	texture, _ := texture_upload(gpu, upload, COLOR_FORMAT, pixels[:width * height * 4], u32(width), u32(height))
	return texture
}
