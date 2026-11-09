// The host's 3D: one pipeline draws every scene mesh, skinned or not, into a color and depth target the size of the
// screen, and a second the blended ones over it. A mesh with no skin draws with one joint, its model matrix. Effect quads
// go last, through an alpha or an additive pipeline. Shaders are src/render/shaders, SPIR-V only.
package render

import "core:math"
import "core:math/linalg"
import "core:slice"
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
	centre:            [3]f32,  // of its vertices, in model space: blended draws sort by it
}

// One mesh to draw: joints are model space to world, one per joint the vertices name; texture nil is white.
Draw :: struct {
	mesh:    Mesh,
	joints:  []matrix[4, 4]f32,
	texture: ^sdl.GPUTexture,
	tint:    [4]f32,
	cutoff:  f32,  // drop pixels with alpha below it; 0 keeps all
	keep_below: f32,  // drop pixels with alpha at or above it; 0 keeps all
	scenery: bool,  // fades where it hides a fighter
	blend:   bool,  // drawn over what is behind, after the opaque draws, by draw_order then far to near
	draw_order: int,  // stage layer sort value, lower first; 0 for the rest
	additive: bool,  // a blended draw added onto what is behind
	unlit:   bool,  // base color only, no scene lights
	reflection: Reflection,
}

// A sphere map added onto the base color, looked up by the camera-to-vertex direction (TK5 NU_mEnvMap shaders).
Reflection :: struct {
	texture:     ^sdl.GPUTexture,  // nil: none
	orientation: [16]f32,  // turns that direction first; rows as stored, which the shader reads as columns
	masked:      bool,  // scaled by the base alpha
}

// scene.vert's Frame and Draw blocks.
@(private = "file")
Frame :: struct {
	view_projection: matrix[4, 4]f32,
	camera_position: [4]f32,
}
@(private = "file")
Draw_Block :: struct {
	reflection_orientation: [16]f32,
	joint_base: u32,
	_: [3]u32,
}

// scene.frag's Material block.
@(private = "file")
Material :: struct {
	tint:    [4]f32,
	cutoff:  f32,
	scenery: f32,
	unlit:   f32,
	blend:   f32,
	reflection: f32,
	keep_below: f32,
}

Gpu :: struct {
	device:        ^sdl.GPUDevice,
	pipeline:      ^sdl.GPUGraphicsPipeline,
	blend_pipeline, add_pipeline: ^sdl.GPUGraphicsPipeline,
	sampler:       ^sdl.GPUSampler,
	white:         ^sdl.GPUTexture,
	color, depth:  ^sdl.GPUTexture,  // the targets, made at size
	size:          [2]u32,
	joints:        ^sdl.GPUBuffer,   // every draw's joints of this frame, in draw order
	joint_upload:  ^sdl.GPUTransferBuffer,
	joint_cap:     int,
	fx_pipeline, fx_add_pipeline: ^sdl.GPUGraphicsPipeline,
	fx_vertices:   ^sdl.GPUBuffer,   // this frame's effect quads
	fx_upload:     ^sdl.GPUTransferBuffer,
	fx_cap:        int,
}

gpu_create :: proc(device: ^sdl.GPUDevice) -> (gpu: Gpu, ok: bool) {
	gpu.device = device
	defer if !ok do gpu_destroy(&gpu)
	vertex_shader := shader(device, #load("../../build/shaders/scene.vert.spv"), .VERTEX, storage_buffers = 1, uniform_buffers = 2) or_return
	defer sdl.ReleaseGPUShader(device, vertex_shader)
	fragment_shader := shader(device, #load("../../build/shaders/scene.frag.spv"), .FRAGMENT, samplers = 2, uniform_buffers = 2) or_return
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
	info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = vertex_shader,
		fragment_shader = fragment_shader,
		vertex_input_state = {raw_data(buffers), u32(len(buffers)), raw_data(attributes), u32(len(attributes))},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},  // glTF double-sided materials; winding unchecked
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {color_target_descriptions = raw_data(targets), num_color_targets = 1, depth_stencil_format = DEPTH_FORMAT, has_depth_stencil_target = true},
	}
	gpu.pipeline = sdl.CreateGPUGraphicsPipeline(device, info)
	if gpu.pipeline == nil do return
	blended := []sdl.GPUColorTargetDescription{{format = COLOR_FORMAT, blend_state = {
		enable_blend = true,
		src_color_blendfactor = .SRC_ALPHA, dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA, color_blend_op = .ADD,
		src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA, alpha_blend_op = .ADD,
	}}}
	info.target_info.color_target_descriptions = raw_data(blended)
	info.depth_stencil_state.enable_depth_write = false
	gpu.blend_pipeline = sdl.CreateGPUGraphicsPipeline(device, info)
	if gpu.blend_pipeline == nil do return
	blended[0].blend_state.dst_color_blendfactor = .ONE
	blended[0].blend_state.src_alpha_blendfactor, blended[0].blend_state.dst_alpha_blendfactor = .ZERO, .ONE
	gpu.add_pipeline = sdl.CreateGPUGraphicsPipeline(device, info)
	if gpu.add_pipeline == nil do return
	gpu.fx_pipeline, gpu.fx_add_pipeline = fx_pipelines(device) or_return
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
	if gpu.blend_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(gpu.device, gpu.blend_pipeline)
	if gpu.add_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(gpu.device, gpu.add_pipeline)
	if gpu.fx_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(gpu.device, gpu.fx_pipeline)
	if gpu.fx_add_pipeline != nil do sdl.ReleaseGPUGraphicsPipeline(gpu.device, gpu.fx_add_pipeline)
	if gpu.fx_vertices != nil do sdl.ReleaseGPUBuffer(gpu.device, gpu.fx_vertices)
	if gpu.fx_upload != nil do sdl.ReleaseGPUTransferBuffer(gpu.device, gpu.fx_upload)
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
	for vertex in vertices do mesh.centre += vertex.position / f32(max(len(vertices), 1))
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

// Draws the draws, seen by the scene's camera and lit by its lights, then the effect quads, into color, which then holds
// the frame's 3D. The targets follow size.
draw_3d :: proc(gpu: ^Gpu, command: ^sdl.GPUCommandBuffer, size: [2]u32, scene: ^Scene, draws: []Draw, effects: Fx_Quads) -> (ok: bool) {
	gpu_targets(gpu, size) or_return
	joint_count := 0
	for draw in draws do joint_count += len(draw.joints)
	upload_joints(gpu, command, draws, joint_count) or_return
	upload_fx(gpu, command, effects.vertices[:]) or_return

	clear := scene.fog.end > 0 ? scene.fog.color : [4]f32{0, 0, 0, 1}
	color := sdl.GPUColorTargetInfo{texture = gpu.color, clear_color = sdl.FColor(clear), load_op = .CLEAR, store_op = .STORE}
	depth := sdl.GPUDepthStencilTargetInfo{texture = gpu.depth, clear_depth = 1, load_op = .CLEAR, store_op = .DONT_CARE}
	pass := sdl.BeginGPURenderPass(command, &color, 1, &depth)
	camera := scene.camera.position
	frame := Frame{camera_matrix(scene.camera, f32(size.x) / f32(size.y)), {camera.x, camera.y, camera.z, 1}}
	sdl.PushGPUVertexUniformData(command, 0, &frame, size_of(frame))
	lighting := scene_lighting(scene)
	sdl.PushGPUFragmentUniformData(command, 0, &lighting, size_of(lighting))
	if joint_count > 0 do sdl.BindGPUVertexStorageBuffers(pass, 0, &gpu.joints, 1)
	joint_bases := make([]u32, len(draws), context.temp_allocator)
	for index in 1 ..< len(draws) do joint_bases[index] = joint_bases[index - 1] + u32(len(draws[index - 1].joints))
	sdl.BindGPUGraphicsPipeline(pass, gpu.pipeline)
	Blended :: struct {
		index:      int,
		draw_order: int,
		distance:   f32,  // of its centre from the camera
	}
	blended := make([dynamic]Blended, context.temp_allocator)
	for draw, index in draws {
		if !draw.blend {
			draw_one(command, pass, gpu, draw, joint_bases[index])
			continue
		}
		centre := draw.mesh.centre
		if len(draw.joints) > 0 do centre = (draw.joints[0] * [4]f32{centre.x, centre.y, centre.z, 1}).xyz
		append(&blended, Blended{index, draw.draw_order, linalg.distance(centre, scene.camera.position)})
	}
	slice.sort_by(blended[:], proc(first, second: Blended) -> bool {
		if first.draw_order != second.draw_order do return first.draw_order < second.draw_order
		return first.distance > second.distance
	})
	bound: ^sdl.GPUGraphicsPipeline
	for entry in blended {
		draw := draws[entry.index]
		pipeline := draw.additive ? gpu.add_pipeline : gpu.blend_pipeline
		if pipeline != bound do sdl.BindGPUGraphicsPipeline(pass, pipeline)
		bound = pipeline
		draw_one(command, pass, gpu, draw, joint_bases[entry.index])
	}
	draw_fx(pass, gpu, effects.quads[:])
	sdl.EndGPURenderPass(pass)
	return true
}

// Far to near, so alpha quads blend over the ones behind them.
@(private = "file")
draw_fx :: proc(pass: ^sdl.GPURenderPass, gpu: ^Gpu, quads: []Fx_Quad) {
	if len(quads) == 0 do return
	slice.sort_by(quads, proc(first, second: Fx_Quad) -> bool {return first.distance > second.distance})
	vertices := sdl.GPUBufferBinding{gpu.fx_vertices, 0}
	sdl.BindGPUVertexBuffers(pass, 0, &vertices, 1)
	bound: ^sdl.GPUGraphicsPipeline
	for quad in quads {
		pipeline := quad.add ? gpu.fx_add_pipeline : gpu.fx_pipeline
		if pipeline != bound do sdl.BindGPUGraphicsPipeline(pass, pipeline)
		bound = pipeline
		binding := sdl.GPUTextureSamplerBinding{quad.texture != nil ? quad.texture : gpu.white, gpu.sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)
		sdl.DrawGPUPrimitives(pass, 6, 1, quad.first, 0)
	}
}

// The alpha and the additive pipeline of effect quads: tested against the scene's depth, writing none.
@(private = "file")
fx_pipelines :: proc(device: ^sdl.GPUDevice) -> (alpha, add: ^sdl.GPUGraphicsPipeline, ok: bool) {
	vertex_shader := shader(device, #load("../../build/shaders/fx.vert.spv"), .VERTEX, uniform_buffers = 1) or_return
	defer sdl.ReleaseGPUShader(device, vertex_shader)
	fragment_shader := shader(device, #load("../../build/shaders/fx.frag.spv"), .FRAGMENT, samplers = 1) or_return
	defer sdl.ReleaseGPUShader(device, fragment_shader)
	buffers := []sdl.GPUVertexBufferDescription{{slot = 0, pitch = size_of(Fx_Vertex), input_rate = .VERTEX}}
	attributes := []sdl.GPUVertexAttribute {
		{0, 0, .FLOAT3, u32(offset_of(Fx_Vertex, position))},
		{1, 0, .FLOAT2, u32(offset_of(Fx_Vertex, uv))},
		{2, 0, .FLOAT4, u32(offset_of(Fx_Vertex, color))},
	}
	targets := []sdl.GPUColorTargetDescription{{format = COLOR_FORMAT, blend_state = {
		enable_blend = true,
		src_color_blendfactor = .SRC_ALPHA, dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA, color_blend_op = .ADD,
		src_alpha_blendfactor = .ONE, dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA, alpha_blend_op = .ADD,
	}}}
	info := sdl.GPUGraphicsPipelineCreateInfo{
		vertex_shader = vertex_shader,
		fragment_shader = fragment_shader,
		vertex_input_state = {raw_data(buffers), u32(len(buffers)), raw_data(attributes), u32(len(attributes))},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true},
		target_info = {color_target_descriptions = raw_data(targets), num_color_targets = 1, depth_stencil_format = DEPTH_FORMAT, has_depth_stencil_target = true},
	}
	alpha = sdl.CreateGPUGraphicsPipeline(device, info)
	targets[0].blend_state.dst_color_blendfactor = .ONE
	targets[0].blend_state.src_alpha_blendfactor, targets[0].blend_state.dst_alpha_blendfactor = .ZERO, .ONE
	add = sdl.CreateGPUGraphicsPipeline(device, info)
	return alpha, add, alpha != nil && add != nil
}

// The quads' vertices into gpu.fx_vertices, in a copy pass before the render pass; the buffer grows to fit.
@(private = "file")
upload_fx :: proc(gpu: ^Gpu, command: ^sdl.GPUCommandBuffer, vertices: []Fx_Vertex) -> (ok: bool) {
	if len(vertices) == 0 do return true
	if len(vertices) > gpu.fx_cap {
		if gpu.fx_vertices != nil do sdl.ReleaseGPUBuffer(gpu.device, gpu.fx_vertices)
		if gpu.fx_upload != nil do sdl.ReleaseGPUTransferBuffer(gpu.device, gpu.fx_upload)
		gpu.fx_cap = max(len(vertices), 2 * gpu.fx_cap)
		bytes := u32(gpu.fx_cap * size_of(Fx_Vertex))
		gpu.fx_vertices = sdl.CreateGPUBuffer(gpu.device, {usage = {.VERTEX}, size = bytes})
		gpu.fx_upload = sdl.CreateGPUTransferBuffer(gpu.device, {usage = .UPLOAD, size = bytes})
		if gpu.fx_vertices == nil || gpu.fx_upload == nil {
			gpu.fx_cap = 0
			return false
		}
	}
	mapped := ([^]Fx_Vertex)(sdl.MapGPUTransferBuffer(gpu.device, gpu.fx_upload, true))
	if mapped == nil do return false
	copy(mapped[:len(vertices)], vertices)
	sdl.UnmapGPUTransferBuffer(gpu.device, gpu.fx_upload)
	pass := sdl.BeginGPUCopyPass(command)
	sdl.UploadToGPUBuffer(pass, {transfer_buffer = gpu.fx_upload}, {gpu.fx_vertices, 0, u32(len(vertices) * size_of(Fx_Vertex))}, true)
	sdl.EndGPUCopyPass(pass)
	return true
}

@(private = "file")
draw_one :: proc(command: ^sdl.GPUCommandBuffer, pass: ^sdl.GPURenderPass, gpu: ^Gpu, draw: Draw, joint_base: u32) {
	block := Draw_Block{reflection_orientation = draw.reflection.orientation, joint_base = joint_base}
	reflection: f32 = draw.reflection.texture == nil ? 0 : draw.reflection.masked ? 2 : 1
	material := Material{tint = draw.tint, cutoff = draw.cutoff, scenery = draw.scenery ? 1 : 0, unlit = draw.unlit ? 1 : 0, blend = draw.blend ? 1 : 0, reflection = reflection, keep_below = draw.keep_below}
	sdl.PushGPUVertexUniformData(command, 1, &block, size_of(block))
	sdl.PushGPUFragmentUniformData(command, 1, &material, size_of(material))
	bindings := [2]sdl.GPUTextureSamplerBinding{{draw.texture != nil ? draw.texture : gpu.white, gpu.sampler}, {draw.reflection.texture != nil ? draw.reflection.texture : gpu.white, gpu.sampler}}
	sdl.BindGPUFragmentSamplers(pass, 0, &bindings[0], len(bindings))
	vertices := sdl.GPUBufferBinding{draw.mesh.vertices, 0}
	sdl.BindGPUVertexBuffers(pass, 0, &vertices, 1)
	sdl.BindGPUIndexBuffer(pass, {draw.mesh.indices, 0}, ._32BIT)
	sdl.DrawGPUIndexedPrimitives(pass, draw.mesh.index_count, 1, 0, 0, 0)
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
	fighter_plane:   [4]f32,
	fighter_fade:    [4]f32,
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
	fighter_fade(scene, &lighting)
	return
}

// Scenery fades on the whole screen above the fighters' feet, in front of a plane flat to the camera as far as the
// fighters allow: it holds the camera's up and the line that best fits their middles seen along it, and sits
// BODY_REACH in front of the one nearest the camera; gone DEPTH_RIM in front of it. A fighter is the middle of a
// shown gameplay node's joints (its transform without bones); a fighter's part nodes share them.
@(private = "file")
fighter_fade :: proc(scene: ^Scene, lighting: ^Lighting) {
	FLOOR_ABOVE_FEET :: 0.15  // metres; stock floors are flat within 0.1
	BODY_REACH :: 0.4         // metres from a fighter's middle toward the camera
	DEPTH_RIM :: 0.5
	middles := make([dynamic][3]f32, context.temp_allocator)
	feet := max(f32)
	for node in scene.nodes {
		if node.class != .Gameplay || .Hidden in node.flags do continue
		place := transform_matrix(node.transform)
		middle := node.transform.position
		feet = min(feet, middle.y)
		if len(node.bones) > 0 {
			sum: [3]f32
			for bone in node.bones {
				joint := (place * [4]f32{bone.position.x, bone.position.y, bone.position.z, 1}).xyz
				sum += joint
				feet = min(feet, joint.y)
			}
			middle = sum / f32(len(node.bones))
		}
		if !slice.contains(middles[:], middle) do append(&middles, middle)
	}
	if len(middles) == 0 do return
	normal := fighters_facing(scene.camera, middles[:])
	nearest := -max(f32)
	for middle in middles do nearest = max(nearest, linalg.dot(normal, middle))
	lighting.fighter_plane = {normal.x, normal.y, normal.z, nearest + BODY_REACH}
	lighting.fighter_fade = {feet + FLOOR_ABOVE_FEET, DEPTH_RIM, 0, 0}
}

// The normal, toward the camera, of the plane that holds the camera's up and the line best fitting the middles seen
// along it (their principal axis). The plane turns back to face the camera as that line turns toward the view or the
// middles close in, so it never jumps between frames.
@(private = "file")
fighters_facing :: proc(camera: Camera, middles: [][3]f32) -> [3]f32 {
	forward := linalg.normalize(camera.target - camera.position)
	up := linalg.quaternion128_mul_vector3(linalg.quaternion_angle_axis_f32(camera.roll, forward), [3]f32{0, 1, 0})
	right := linalg.normalize(linalg.cross(forward, up))
	away := linalg.cross(up, right)  // forward with its up part taken out
	centre: [2]f32
	for middle in middles do centre += {linalg.dot(middle, right), linalg.dot(middle, away)}
	centre /= f32(len(middles))
	spread: [3]f32  // right * right, away * away, right * away
	for middle in middles {
		offset := [2]f32{linalg.dot(middle, right), linalg.dot(middle, away)} - centre
		spread += {offset.x * offset.x, offset.y * offset.y, offset.x * offset.y}
	}
	FULL_SPREAD :: 0.25  // square metres: closer middles turn the plane part way
	angle := 0.5 * math.atan2(2 * spread.z, spread.x - spread.y)  // of the line, from right toward away
	tilt := abs(angle) < math.PI / 4 ? angle : math.sign(angle) * (math.PI / 2 - abs(angle))
	tilt *= min(1, (spread.x + spread.y) / FULL_SPREAD)
	return right * math.sin(tilt) - away * math.cos(tilt)
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
