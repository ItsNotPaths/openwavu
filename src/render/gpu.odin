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

gpu_create :: proc(device: ^sdl.GPUDevice) -> (g: Gpu, ok: bool) {
	g.device = device
	defer if !ok do gpu_destroy(&g)
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
	g.pipeline = sdl.CreateGPUGraphicsPipeline(device, {
		vertex_shader = vertex_shader,
		fragment_shader = fragment_shader,
		vertex_input_state = {raw_data(buffers), u32(len(buffers)), raw_data(attributes), u32(len(attributes))},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},  // glTF double-sided materials; winding unchecked
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {color_target_descriptions = raw_data(targets), num_color_targets = 1, depth_stencil_format = DEPTH_FORMAT, has_depth_stencil_target = true},
	})
	if g.pipeline == nil do return
	g.sampler = sdl.CreateGPUSampler(device, {min_filter = .LINEAR, mag_filter = .LINEAR, mipmap_mode = .LINEAR, address_mode_u = .REPEAT, address_mode_v = .REPEAT, address_mode_w = .REPEAT})
	if g.sampler == nil do return
	white := [4]u8{255, 255, 255, 255}
	u := upload_begin(&g) or_return
	white_ok: bool
	g.white, white_ok = texture_upload(&g, u, COLOR_FORMAT, white[:], 1, 1)
	if !upload_end(u) || !white_ok do return g, false
	return g, true
}

gpu_destroy :: proc(g: ^Gpu) {
	release_targets(g)
	if g.joints != nil do sdl.ReleaseGPUBuffer(g.device, g.joints)
	if g.joint_upload != nil do sdl.ReleaseGPUTransferBuffer(g.device, g.joint_upload)
	if g.white != nil do sdl.ReleaseGPUTexture(g.device, g.white)
	if g.sampler != nil do sdl.ReleaseGPUSampler(g.device, g.sampler)
	if g.pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(g.device, g.pipeline)
	g^ = {device = g.device}
}

// Uploads that go in one copy pass and one submit: upload_begin, any mesh_upload and texture_upload, upload_end.
Upload :: struct {
	command: ^sdl.GPUCommandBuffer,
	pass:    ^sdl.GPUCopyPass,
}

upload_begin :: proc(g: ^Gpu) -> (u: Upload, ok: bool) {
	u.command = sdl.AcquireGPUCommandBuffer(g.device)
	if u.command == nil do return {}, false
	u.pass = sdl.BeginGPUCopyPass(u.command)
	return u, true
}

upload_end :: proc(u: Upload) -> (ok: bool) {
	sdl.EndGPUCopyPass(u.pass)
	return sdl.SubmitGPUCommandBuffer(u.command)
}

mesh_upload :: proc(g: ^Gpu, u: Upload, vertices: []Vertex, indices: []u32) -> (m: Mesh, ok: bool) {
	m.index_count = u32(len(indices))
	m.vertices = buffer_upload(g, u, {.VERTEX}, raw_data(vertices), len(vertices) * size_of(Vertex)) or_return
	if m.indices, ok = buffer_upload(g, u, {.INDEX}, raw_data(indices), len(indices) * size_of(u32)); !ok {
		sdl.ReleaseGPUBuffer(g.device, m.vertices)
		return {}, false
	}
	return m, true
}

mesh_destroy :: proc(g: ^Gpu, m: Mesh) {
	sdl.ReleaseGPUBuffer(g.device, m.vertices)
	sdl.ReleaseGPUBuffer(g.device, m.indices)
}

// One mip, rows top first, for a mesh's base color: RGBA8 pixels or BC blocks as stored.
texture_upload :: proc(g: ^Gpu, u: Upload, format: sdl.GPUTextureFormat, data: []u8, width, height: u32) -> (t: ^sdl.GPUTexture, ok: bool) {
	t = sdl.CreateGPUTexture(g.device, {type = .D2, format = format, usage = {.SAMPLER}, width = width, height = height, layer_count_or_depth = 1, num_levels = 1})
	if t == nil do return nil, false
	staging, staged_ok := staged(g, raw_data(data), len(data))
	if !staged_ok {
		sdl.ReleaseGPUTexture(g.device, t)
		return nil, false
	}
	sdl.UploadToGPUTexture(u.pass, {transfer_buffer = staging}, {texture = t, w = width, h = height, d = 1}, false)
	sdl.ReleaseGPUTransferBuffer(g.device, staging)  // freed once the upload has run
	return t, true
}

// Draws the draws, seen by the scene's camera and lit by its lights, into color, which then holds the frame's 3D.
// The targets follow size.
draw_3d :: proc(g: ^Gpu, command: ^sdl.GPUCommandBuffer, size: [2]u32, s: ^Scene, draws: []Draw) -> (ok: bool) {
	gpu_targets(g, size) or_return
	joint_count := 0
	for d in draws do joint_count += len(d.joints)
	upload_joints(g, command, draws, joint_count) or_return

	clear := s.fog.end > 0 ? s.fog.color : [4]f32{0, 0, 0, 1}
	color := sdl.GPUColorTargetInfo{texture = g.color, clear_color = sdl.FColor(clear), load_op = .CLEAR, store_op = .STORE}
	depth := sdl.GPUDepthStencilTargetInfo{texture = g.depth, clear_depth = 1, load_op = .CLEAR, store_op = .DONT_CARE}
	pass := sdl.BeginGPURenderPass(command, &color, 1, &depth)
	sdl.BindGPUGraphicsPipeline(pass, g.pipeline)
	view_projection := camera_matrix(s.camera, f32(size.x) / f32(size.y))
	sdl.PushGPUVertexUniformData(command, 0, &view_projection, size_of(view_projection))
	lighting := scene_lighting(s)
	sdl.PushGPUFragmentUniformData(command, 0, &lighting, size_of(lighting))
	if joint_count > 0 do sdl.BindGPUVertexStorageBuffers(pass, 0, &g.joints, 1)
	joint_base: u32
	for d in draws {
		material := Material{tint = d.tint, cutout = d.cutout ? 1 : 0}
		sdl.PushGPUVertexUniformData(command, 1, &joint_base, size_of(joint_base))
		sdl.PushGPUFragmentUniformData(command, 1, &material, size_of(material))
		binding := sdl.GPUTextureSamplerBinding{d.texture != nil ? d.texture : g.white, g.sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
		vertices := sdl.GPUBufferBinding{d.mesh.vertices, 0}
		sdl.BindGPUVertexBuffers(pass, 0, &vertices, 1)
		sdl.BindGPUIndexBuffer(pass, {d.mesh.indices, 0}, ._32BIT)
		sdl.DrawGPUIndexedPrimitives(pass, d.mesh.index_count, 1, 0, 0, 0)
		joint_base += u32(len(d.joints))
	}
	sdl.EndGPURenderPass(pass)
	return true
}

// Projection times view, Vulkan depth 0 to 1, right handed and Y up as glTF.
camera_matrix :: proc(c: Camera, aspect: f32) -> matrix[4, 4]f32 {
	forward := linalg.normalize(c.target - c.position)
	up := linalg.quaternion128_mul_vector3(linalg.quaternion_angle_axis_f32(c.roll, forward), [3]f32{0, 1, 0})
	view := linalg.matrix4_look_at_f32(c.position, c.target, up)
	f := 1 / math.tan(c.fov / 2)
	projection := matrix[4, 4]f32{
		f / aspect, 0, 0, 0,
		0, f, 0, 0,
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
scene_lighting :: proc(s: ^Scene) -> (l: Lighting) {
	l.ambient = s.ambient
	for light, i in s.lights[:min(len(s.lights), LIGHTS)] {
		l.light_position[i] = {light.position.x, light.position.y, light.position.z, light.kind == .Point ? 1 : 0}
		l.light_direction[i] = {light.direction.x, light.direction.y, light.direction.z, light.range}
		l.light_color[i] = light.color
	}
	l.fog_color = s.fog.color
	l.fog_range = {s.fog.start, s.fog.end, 0, 0}
	l.camera_position = {s.camera.position.x, s.camera.position.y, s.camera.position.z, 1}
	return
}

@(private = "file")
shader :: proc(device: ^sdl.GPUDevice, code: []u8, stage: sdl.GPUShaderStage, samplers: u32 = 0, storage_buffers: u32 = 0, uniform_buffers: u32 = 0) -> (s: ^sdl.GPUShader, ok: bool) {
	s = sdl.CreateGPUShader(device, {
		code_size = len(code),
		code = raw_data(code),
		entrypoint = "main",
		format = {.SPIRV},
		stage = stage,
		num_samplers = samplers,
		num_storage_buffers = storage_buffers,
		num_uniform_buffers = uniform_buffers,
	})
	return s, s != nil
}

// The color and depth targets at size, made again when it changes.
gpu_targets :: proc(g: ^Gpu, size: [2]u32) -> (ok: bool) {
	if g.size == size && g.color != nil do return true
	release_targets(g)
	g.size = size
	g.color = sdl.CreateGPUTexture(g.device, {type = .D2, format = COLOR_FORMAT, usage = {.COLOR_TARGET, .SAMPLER}, width = size.x, height = size.y, layer_count_or_depth = 1, num_levels = 1})
	g.depth = sdl.CreateGPUTexture(g.device, {type = .D2, format = DEPTH_FORMAT, usage = {.DEPTH_STENCIL_TARGET}, width = size.x, height = size.y, layer_count_or_depth = 1, num_levels = 1})
	return g.color != nil && g.depth != nil
}

@(private = "file")
release_targets :: proc(g: ^Gpu) {
	if g.color != nil do sdl.ReleaseGPUTexture(g.device, g.color)
	if g.depth != nil do sdl.ReleaseGPUTexture(g.device, g.depth)
	g.color, g.depth = nil, nil
}

// All draws' joints into g.joints, in a copy pass before the render pass; the buffer grows to fit.
@(private = "file")
upload_joints :: proc(g: ^Gpu, command: ^sdl.GPUCommandBuffer, draws: []Draw, count: int) -> (ok: bool) {
	if count == 0 do return true
	if count > g.joint_cap {
		if g.joints != nil do sdl.ReleaseGPUBuffer(g.device, g.joints)
		if g.joint_upload != nil do sdl.ReleaseGPUTransferBuffer(g.device, g.joint_upload)
		g.joint_cap = max(count, 2 * g.joint_cap)
		bytes := u32(g.joint_cap * size_of(matrix[4, 4]f32))
		g.joints = sdl.CreateGPUBuffer(g.device, {usage = {.GRAPHICS_STORAGE_READ}, size = bytes})
		g.joint_upload = sdl.CreateGPUTransferBuffer(g.device, {usage = .UPLOAD, size = bytes})
		if g.joints == nil || g.joint_upload == nil {
			g.joint_cap = 0
			return false
		}
	}
	mapped := ([^]matrix[4, 4]f32)(sdl.MapGPUTransferBuffer(g.device, g.joint_upload, true))
	if mapped == nil do return false
	at := 0
	for d in draws {
		copy(mapped[at:][:len(d.joints)], d.joints)
		at += len(d.joints)
	}
	sdl.UnmapGPUTransferBuffer(g.device, g.joint_upload)
	pass := sdl.BeginGPUCopyPass(command)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = g.joint_upload}, {g.joints, 0, u32(count * size_of(matrix[4, 4]f32))}, true)
	sdl.EndGPUCopyPass(pass)
	return true
}

@(private = "file")
buffer_upload :: proc(g: ^Gpu, u: Upload, usage: sdl.GPUBufferUsageFlags, data: rawptr, size: int) -> (b: ^sdl.GPUBuffer, ok: bool) {
	b = sdl.CreateGPUBuffer(g.device, {usage = usage, size = u32(size)})
	if b == nil do return nil, false
	staging, staged_ok := staged(g, data, size)
	if !staged_ok {
		sdl.ReleaseGPUBuffer(g.device, b)
		return nil, false
	}
	sdl.UploadToGPUBuffer(u.pass, {transfer_buffer = staging}, {b, 0, u32(size)}, false)
	sdl.ReleaseGPUTransferBuffer(g.device, staging)
	return b, true
}

// A transfer buffer holding a copy of the bytes, for one upload.
@(private = "file")
staged :: proc(g: ^Gpu, data: rawptr, size: int) -> (t: ^sdl.GPUTransferBuffer, ok: bool) {
	t = sdl.CreateGPUTransferBuffer(g.device, {usage = .UPLOAD, size = u32(size)})
	if t == nil do return nil, false
	mapped := sdl.MapGPUTransferBuffer(g.device, t, false)
	if mapped == nil {
		sdl.ReleaseGPUTransferBuffer(g.device, t)
		return nil, false
	}
	copy(([^]u8)(mapped)[:size], ([^]u8)(data)[:size])
	sdl.UnmapGPUTransferBuffer(g.device, t)
	return t, true
}
