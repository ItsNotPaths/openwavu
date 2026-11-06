package tests

import "core:log"
import "core:math"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"
import "../src/render"

// One Vulkan device for every GPU test, made once and kept: SDL's video can not start and stop under tests running
// in parallel.
@(private = "file")
gpu_device: ^sdl.GPUDevice
@(private = "file")
gpu_once: sync.Once
@(private = "file")
gpu_lock: sync.Mutex

// The 3D pipeline on the shared device, for a test to draw with; GPU tests take turns, until test_gpu_destroy.
// ok is false, with a warning, on a machine with no Vulkan device (lavapipe works).
test_gpu_create :: proc(t: ^testing.T) -> (g: render.Gpu, ok: bool) {
	sync.once_do(&gpu_once, proc() {
		if sdl.Init({.VIDEO}) do gpu_device = sdl.CreateGPUDevice({.SPIRV}, false, "vulkan")
	})
	if gpu_device == nil {
		log.warnf("no Vulkan device: %s", sdl.GetError())
		return
	}
	sync.mutex_lock(&gpu_lock)
	if g, ok = render.gpu_create(gpu_device); !ok {
		testing.expect(t, ok, string(sdl.GetError()))
		sync.mutex_unlock(&gpu_lock)
	}
	return
}

test_gpu_destroy :: proc(g: ^render.Gpu) {
	render.gpu_destroy(g)
	sync.mutex_unlock(&gpu_lock)
}

// The draws drawn at size by size; pixels row by row from the top, in the temp allocator.
test_draw :: proc(t: ^testing.T, g: ^render.Gpu, scene: ^render.Scene, draws: []render.Draw, size: u32) -> (pixels: [][4]u8, ok: bool) {
	command := sdl.AcquireGPUCommandBuffer(g.device)
	if !testing.expect(t, render.draw_3d(g, command, {size, size}, scene, draws, {})) {
		_ = sdl.CancelGPUCommandBuffer(command)
		return
	}
	download := sdl.CreateGPUTransferBuffer(g.device, {usage = .DOWNLOAD, size = size * size * 4})
	defer sdl.ReleaseGPUTransferBuffer(g.device, download)
	pass := sdl.BeginGPUCopyPass(command)
	sdl.DownloadFromGPUTexture(pass, {texture = g.color, w = size, h = size, d = 1}, {transfer_buffer = download})
	sdl.EndGPUCopyPass(pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(command)
	defer sdl.ReleaseGPUFence(g.device, fence)
	if !testing.expect(t, sdl.WaitForGPUFences(g.device, true, &fence, 1)) do return
	mapped := ([^][4]u8)(sdl.MapGPUTransferBuffer(g.device, download, false))
	defer sdl.UnmapGPUTransferBuffer(g.device, download)
	pixels = make([][4]u8, size * size, context.temp_allocator)
	copy(pixels, mapped[:size * size])
	return pixels, true
}

// A far red square, moved by its own joint, and a nearer green one up and to the left, the green drawn first: the
// depth test keeps it in front, it lands in the upper left of the image (Y up), each draw uses its own joints, and the
// clear color shows around both.
@(test)
nearer_mesh_wins_and_lands_where_the_camera_sees_it :: proc(t: ^testing.T) {
	g, ok := test_gpu_create(t)
	if !ok do return
	defer test_gpu_destroy(&g)

	square :: proc(t: ^testing.T, g: ^render.Gpu, u: render.Upload, x0, y0, x1, y1, z: f32) -> render.Mesh {
		corner :: proc(x, y, z: f32) -> render.Vertex {return {position = {x, y, z}, normal = {0, 0, 1}, weights = {1, 0, 0, 0}, color = 1}}
		vertices := []render.Vertex{corner(x0, y0, z), corner(x1, y0, z), corner(x1, y1, z), corner(x0, y1, z)}
		m, uploaded := render.mesh_upload(g, u, vertices, {0, 1, 2, 0, 2, 3})
		testing.expect(t, uploaded)
		return m
	}
	u, began := render.upload_begin(&g)
	if !testing.expect(t, began) do return
	far := square(t, &g, u, -1, -1, 1, 1, 0)
	defer render.mesh_destroy(&g, far)
	near := square(t, &g, u, -1, 0.25, -0.25, 1, 1)
	defer render.mesh_destroy(&g, near)
	testing.expect(t, render.upload_end(u))

	scene := render.scene_create()
	defer render.scene_destroy(&scene)
	scene.camera = {position = {0, 0, 5}, target = {0, 0, 0}, fov = math.PI / 3}
	scene.ambient = {1, 1, 1, 1}
	moved := matrix[4, 4]f32{1, 0, 0, 0.5, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}  // 0.5 m to the right
	draws := []render.Draw{{mesh = near, joints = {1}, tint = {0, 1, 0, 1}}, {mesh = far, joints = {moved}, tint = {1, 0, 0, 1}}}
	SIZE :: 64
	pixels, drawn := test_draw(t, &g, &scene, draws, SIZE)
	if !drawn do return

	// The camera sees 2 * tan(30°) * distance across: the green square at x, y = -0.6, 0.6 sits near pixel (23, 23).
	testing.expect_value(t, pixels[23 * SIZE + 23], [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixels[40 * SIZE + 40], [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixels[40 * SIZE + 23], [4]u8{0, 0, 0, 255})  // x = -0.75: left of the moved red square
	testing.expect_value(t, pixels[2 * SIZE + 2], [4]u8{0, 0, 0, 255})
}
