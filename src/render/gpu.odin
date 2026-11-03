// The host's 3D: one pipeline draws every scene mesh, skinned or not, into a color and depth target the size of the
// screen. A mesh with no skin draws with one joint, its model matrix. Shaders are src/render/shaders, SPIR-V only.
package render

import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

COLOR_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM
DEPTH_FORMAT :: sdl.GPUTextureFormat.D32_FLOAT
LIGHTS :: 4  // scene.frag
NEAR :: 0.05
FAR :: 1000.0  // metres

Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	uv:       [2]f32,
	joints:   [4]u16,  // into the draw's joints
	weights:  [4]f32,
	color:    [4]f32,  // 1 = the texture as is
}

Mesh :: struct {
	vertices, indices: ^sdl.GPUBuffer,
	index_count:       u32,
}

// One mesh to draw: joints are model space to world, one per joint the vertices name; texture nil is white.
Draw :: struct {
	mesh:    Mesh,
	joints:  []matrix[4, 4]f32,
	texture: ^sdl.GPUTexture,
	tint:    [4]f32,
	cutout:  bool,  // drop pixels below half alpha
}

// scene.frag's Material block.
@(private = "file")
Material :: struct {
	tint:   [4]f32,
	cutout: f32,
	_:      [3]f32,
}

Gpu :: struct {
	device:        ^sdl.GPUDevice,
	pipeline:      ^sdl.GPUGraphicsPipeline,
	sampler:       ^sdl.GPUSampler,
	white:         ^sdl.GPUTexture,
	color, depth:  ^sdl.GPUTexture,  // the targets, made at size
	size:          [2]u32,
	joints:        ^sdl.GPUBuffer,   // every draw's joints of this frame, in draw order
	joint_upload:  ^sdl.GPUTransferBuffer,
	joint_cap:     int,
}

gpu_create :: proc(device: ^sdl.GPUDevice) -> (gpu: Gpu, ok: bool) {
	gpu.device = device
	defer if !ok do gpu_destroy(&gpu)
	vertex_shader := shader(device, #load("../../build/shaders/scene.vert.spv"), .VERTEX, storage_buffers = 1, uniform_buffers = 2) or_return
	defer sdl.ReleaseGPUShader(device, vertex_shader)
	fragment_shader := shader(device, #load("../../build/shaders/scene.frag.spv"), .FRAGMENT, samplers = 1, uniform_buffers = 2) or_return
	defer sdl.ReleaseGPUShader(device, fragment_shader)
	buffers := []sdl.GPUVertexBufferDescription{{slot = 0, pitch = size_of(Vertex), input_rate = .VERTEX}}
	attributes := []sdl.GPUVertexAttribute {
		{0, 0, .FLOAT3, u32(offset_of(Vertex, position))},
		{1, 0, .FLOAT3, u32(offset_of(Vertex, normal))},
		{2, 0, .FLOAT2, u32(offset_of(Vertex, uv))},
		{3, 0, .USHORT4, u32(offset_of(Vertex, joints))},
		{4, 0, .FLOAT4, u32(offset_of(Vertex, weights))},
		{5, 0, .FLOAT4, u32(offset_of(Vertex, color))},
	}
	targets := []sdl.GPUColorTargetDescription{{format = COLOR_FORMAT}}
	gpu.pipeline = sdl.CreateGPUGraphicsPipeline(device, {
		vertex_shader = vertex_shader,
		fragment_shader = fragment_shader,
		vertex_input_state = {raw_data(buffers), u32(len(buffers)), raw_data(attributes), u32(len(attributes))},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},  // glTF double-sided materials; winding unchecked
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {color_target_descriptions = raw_data(targets), num_color_targets = 1, depth_stencil_format = DEPTH_FORMAT, has_depth_stencil_target = true},
	})
	if gpu.pipeline == nil do return
	gpu.sampler = sdl.CreateGPUSampler(device, {min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .LINEAR, address_mode_u = .REPEAT, address_mode_v = .REPEAT, address_mode_w = .REPEAT})
	if gpu.sampler == nil do return
	white := [4]u8{255, 255, 255, 255}
	upload := upload_begin(&gpu) or_return
	white_ok: bool
	gpu.white, white_ok = texture_upload(&gpu, upload, COLOR_FORMAT, white[:], 1, 1)
	if !upload_end(upload) || !white_ok do return gpu, false
	return gpu, true
}

gpu_destroy :: proc(gpu: ^Gpu) {
	release_targets(gpu)
	if gpu.joints != nil do sdl.ReleaseGPUBuffer(gpu.device, gpu.joints)
	if gpu.joint_upload != nil do sdl.ReleaseGPUTransferBuffer(gpu.device, gpu.joint_upload)
	if gpu.white != nil do sdl.ReleaseGPUTexture(gpu.device, gpu.white)
	if gpu.sampler != nil do sdl.ReleaseGPUSampler(gpu.device, gpu.sampler)
	if gpu.pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(gpu.device, gpu.pipeline)
	gpu^ = {device = gpu.device}
}

// Uploads that go in one copy pass and one submit: upload_begin, any mesh_upload and texture_upload, upload_end.
Upload :: struct {
	command: ^sdl.GPUCommandBuffer,
	pass:    ^sdl.GPUCopyPass,
}

upload_begin :: proc(gpu: ^Gpu) -> (upload: Upload, ok: bool) {
	upload.command = sdl.AcquireGPUCommandBuffer(gpu.device)
	if upload.command == nil do return {}, false
	upload.pass = sdl.BeginGPUCopyPass(upload.command)
	return upload, true
}

upload_end :: proc(upload: Upload) -> (ok: bool) {
	sdl.EndGPUCopyPass(upload.pass)
	return sdl.SubmitGPUCommandBuffer(upload.command)
}

mesh_upload :: proc(gpu: ^Gpu, upload: Upload, vertices: []Vertex, indices: []u32) -> (mesh: Mesh, ok: bool) {
	mesh.index_count = u32(len(indices))
	mesh.vertices = buffer_upload(gpu, upload, {.VERTEX}, raw_data(vertices), len(vertices) * size_of(Vertex)) or_return
	if mesh.indices, ok = buffer_upload(gpu, upload, {.INDEX}, raw_data(indices), len(indices) * size_of(u32)); !ok {
		sdl.ReleaseGPUBuffer(gpu.device, mesh.vertices)
		return {}, false
	}
	return mesh, true
}

mesh_destroy :: proc(gpu: ^Gpu, mesh: Mesh) {
	sdl.ReleaseGPUBuffer(gpu.device, mesh.vertices)
	sdl.ReleaseGPUBuffer(gpu.device, mesh.indices)
}

// One mip, rows top first, for a mesh's base color: RGBA8 pixels or BC blocks as stored.
texture_upload :: proc(gpu: ^Gpu, upload: Upload, format: sdl.GPUTextureFormat, data: []u8, width, height: u32) -> (texture: ^sdl.GPUTexture, ok: bool) {
	texture = sdl.CreateGPUTexture(gpu.device, {type = .D2, format = format, usage = {.SAMPLER}, width = width, height = height, layer_count_or_depth = 1, num_levels = 1})
	if texture == nil do return nil, false
	staging, staged_ok := staged(gpu, raw_data(data), len(data))
	if !staged_ok {
		sdl.ReleaseGPUTexture(gpu.device, texture)
		return nil, false
	}
	sdl.UploadToGPUTexture(upload.pass, {transfer_buffer = staging}, {texture = texture, w = width, h = height, d = 1}, false)
	sdl.ReleaseGPUTransferBuffer(gpu.device, staging)  // freed once the upload has run
	return texture, true
}

// Draws the draws, seen by the scene's camera and lit by its lights, into color, which then holds the frame's 3D.
// The targets follow size.
draw_3d :: proc(gpu: ^Gpu, command: ^sdl.GPUCommandBuffer, size: [2]u32, scene: ^Scene, draws: []Draw) -> (ok: bool) {
	gpu_targets(gpu, size) or_return
	joint_count := 0
	for draw in draws do joint_count += len(draw.joints)
	upload_joints(gpu, command, draws, joint_count) or_return

	clear := scene.fog.end > 0 ? scene.fog.color : [4]f32{0, 0, 0, 1}
	color := sdl.GPUColorTargetInfo{texture = gpu.color, clear_color = sdl.FColor(clear), load_op = .CLEAR, store_op = .STORE}
	depth := sdl.GPUDepthStencilTargetInfo{texture = gpu.depth, clear_depth = 1, load_op = .CLEAR, store_op = .DONT_CARE}
	pass := sdl.BeginGPURenderPass(command, &color, 1, &depth)
	sdl.BindGPUGraphicsPipeline(pass, gpu.pipeline)
	view_projection := camera_matrix(scene.camera, f32(size.x) / f32(size.y))
	sdl.PushGPUVertexUniformData(command, 0, &view_projection, size_of(view_projection))
	lighting := scene_lighting(scene)
	sdl.PushGPUFragmentUniformData(command, 0, &lighting, size_of(lighting))
	if joint_count > 0 do sdl.BindGPUVertexStorageBuffers(pass, 0, &gpu.joints, 1)
	joint_base: u32
	for draw in draws {
		material := Material{tint = draw.tint, cutout = draw.cutout ? 1 : 0}
		sdl.PushGPUVertexUniformData(command, 1, &joint_base, size_of(joint_base))
		sdl.PushGPUFragmentUniformData(command, 1, &material, size_of(material))
		binding := sdl.GPUTextureSamplerBinding{draw.texture != nil ? draw.texture : gpu.white, gpu.sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
		vertices := sdl.GPUBufferBinding{draw.mesh.vertices, 0}
		sdl.BindGPUVertexBuffers(pass, 0, &vertices, 1)
		sdl.BindGPUIndexBuffer(pass, {draw.mesh.indices, 0}, ._32BIT)
		sdl.DrawGPUIndexedPrimitives(pass, draw.mesh.index_count, 1, 0, 0, 0)
		joint_base += u32(len(draw.joints))
	}
	sdl.EndGPURenderPass(pass)
	return true
}

// Projection times view, Vulkan depth 0 to 1, right handed and Y up as glTF.
camera_matrix :: proc(camera: Camera, aspect: f32) -> matrix[4, 4]f32 {
	forward := linalg.normalize(camera.target - camera.position)
	up := linalg.quaternion128_mul_vector3(linalg.quaternion_angle_axis_f32(camera.roll, forward), [3]f32{0, 1, 0})
	view := linalg.matrix4_look_at_f32(camera.position, camera.target, up)
	focal_length := 1 / math.tan(camera.fov / 2)
	projection := matrix[4, 4]f32{
		focal_length / aspect, 0, 0, 0,
		0, focal_length, 0, 0,
		0, 0, FAR / (NEAR - FAR), NEAR * FAR / (NEAR - FAR),
		0, 0, -1, 0,
	}
	return projection * view
}

// scene.frag's Lighting block.
@(private = "file")
Lighting :: struct {
	ambient:         [4]f32,
	light_position:  [LIGHTS][4]f32,
	light_direction: [LIGHTS][4]f32,
	light_color:     [LIGHTS][4]f32,
	fog_color:       [4]f32,
	fog_range:       [4]f32,
	camera_position: [4]f32,
}

// The first LIGHTS lights; the rest are not drawn.
@(private = "file")
scene_lighting :: proc(scene: ^Scene) -> (lighting: Lighting) {
	lighting.ambient = scene.ambient
	for light, index in scene.lights[:min(len(scene.lights), LIGHTS)] {
		lighting.light_position[index] = {light.position.x, light.position.y, light.position.z, light.kind == .Point ? 1 : 0}
		lighting.light_direction[index] = {light.direction.x, light.direction.y, light.direction.z, light.range}
		lighting.light_color[index] = light.color
	}
	lighting.fog_color = scene.fog.color
	lighting.fog_range = {scene.fog.start, scene.fog.end, 0, 0}
	lighting.camera_position = {scene.camera.position.x, scene.camera.position.y, scene.camera.position.z, 1}
	return
}

@(private = "file")
shader :: proc(device: ^sdl.GPUDevice, code: []u8, stage: sdl.GPUShaderStage, samplers: u32 = 0, storage_buffers: u32 = 0, uniform_buffers: u32 = 0) -> (result: ^sdl.GPUShader, ok: bool) {
	result = sdl.CreateGPUShader(device, {
		code_size = len(code),
		code = raw_data(code),
		entrypoint = "main",
		format = {.SPIRV},
		stage = stage,
		num_samplers = samplers,
		num_storage_buffers = storage_buffers,
		num_uniform_buffers = uniform_buffers,
	})
	return result, result != nil
}

// The color and depth targets at size, made again when it changes.
gpu_targets :: proc(gpu: ^Gpu, size: [2]u32) -> (ok: bool) {
	if gpu.size == size && gpu.color != nil do return true
	release_targets(gpu)
	gpu.size = size
	gpu.color = sdl.CreateGPUTexture(gpu.device, {type = .D2, format = COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER}, width = size.x, height = size.y, layer_count_or_depth = 1, num_levels = 1})
	gpu.depth = sdl.CreateGPUTexture(gpu.device, {type = .D2, format = DEPTH_FORMAT, usage = {.DEPTH_STENCIL_TARGET}, width = size.x, height = size.y, layer_count_or_depth = 1, num_levels = 1})
	if gpu.color == nil || gpu.depth == nil {
		release_targets(gpu)  // half made would pass the size check next frame
		return false
	}
	return true
}

@(private = "file")
release_targets :: proc(gpu: ^Gpu) {
	if gpu.color != nil do sdl.ReleaseGPUTexture(gpu.device, gpu.color)
	if gpu.depth != nil do sdl.ReleaseGPUTexture(gpu.device, gpu.depth)
	gpu.color, gpu.depth = nil, nil
}

// All draws' joints into g.joints, in a copy pass before the render pass; the buffer grows to fit.
@(private = "file")
upload_joints :: proc(gpu: ^Gpu, command: ^sdl.GPUCommandBuffer, draws: []Draw, count: int) -> (ok: bool) {
	if count == 0 do return true
	if count > gpu.joint_cap {
		if gpu.joints != nil do sdl.ReleaseGPUBuffer(gpu.device, gpu.joints)
		if gpu.joint_upload != nil do sdl.ReleaseGPUTransferBuffer(gpu.device, gpu.joint_upload)
		gpu.joint_cap = max(count, 2 * gpu.joint_cap)
		bytes := u32(gpu.joint_cap * size_of(matrix[4, 4]f32))
		gpu.joints = sdl.CreateGPUBuffer(gpu.device, {usage = {.GRAPHICS_STORAGE_READ}, size = bytes})
		gpu.joint_upload = sdl.CreateGPUTransferBuffer(gpu.device, {usage = .UPLOAD, size = bytes})
		if gpu.joints == nil || gpu.joint_upload == nil {
			gpu.joint_cap = 0
			return false
		}
	}
	mapped := ([^]matrix[4, 4]f32)(sdl.MapGPUTransferBuffer(gpu.device, gpu.joint_upload, true))
	if mapped == nil do return false
	at := 0
	for draw in draws {
		copy(mapped[at:][:len(draw.joints)], draw.joints)
		at += len(draw.joints)
	}
	sdl.UnmapGPUTransferBuffer(gpu.device, gpu.joint_upload)
	pass := sdl.BeginGPUCopyPass(command)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = gpu.joint_upload}, {gpu.joints, 0, u32(count * size_of(matrix[4, 4]f32))}, true)
	sdl.EndGPUCopyPass(pass)
	return true
}

@(private = "file")
buffer_upload :: proc(gpu: ^Gpu, upload: Upload, usage: sdl.GPUBufferUsageFlags, data: rawptr, size: int) -> (buffer: ^sdl.GPUBuffer, ok: bool) {
	buffer = sdl.CreateGPUBuffer(gpu.device, {usage = usage, size = u32(size)})
	if buffer == nil do return nil, false
	staging, staged_ok := staged(gpu, data, size)
	if !staged_ok {
		sdl.ReleaseGPUBuffer(gpu.device, buffer)
		return nil, false
	}
	sdl.UploadToGPUBuffer(upload.pass, {transfer_buffer = staging}, {buffer, 0, u32(size)}, false)
	sdl.ReleaseGPUTransferBuffer(gpu.device, staging)
	return buffer, true
}

// A transfer buffer holding a copy of the bytes, for one upload.
@(private = "file")
staged :: proc(gpu: ^Gpu, data: rawptr, size: int) -> (transfer: ^sdl.GPUTransferBuffer, ok: bool) {
	transfer = sdl.CreateGPUTransferBuffer(gpu.device, {usage = .UPLOAD, size = u32(size)})
	if transfer == nil do return nil, false
	mapped := sdl.MapGPUTransferBuffer(gpu.device, transfer, false)
	if mapped == nil {
		sdl.ReleaseGPUTransferBuffer(gpu.device, transfer)
		return nil, false
	}
	copy(([^]u8)(mapped)[:size], ([^]u8)(data)[:size])
	sdl.UnmapGPUTransferBuffer(gpu.device, transfer)
	return transfer, true
}
