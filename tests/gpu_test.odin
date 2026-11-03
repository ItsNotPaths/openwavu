package tests

import "core:log"
import "core:math"
import "core:testing"
import sdl "vendor:sdl3"
import "../src/render"

// A far red square, moved by its own joint, and a nearer green one up and to the left, the green drawn first: the
// depth test keeps it in front, it lands in the upper left of the image (Y up), each draw uses its own joints, and the
// clear color shows around both. Skipped with no
// Vulkan device (lavapipe works).
@(test)
nearer_mesh_wins_and_lands_where_the_camera_sees_it :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {
		log.warnf("no video: %s", sdl.GetError())
		return
	}
	defer sdl.Quit()
	device := sdl.CreateGPUDevice({.SPIRV}, false, "vulkan")
	if device == nil {
		log.warnf("no Vulkan device: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyGPUDevice(device)
	g, ok := render.gpu_create(device)
	if !testing.expect(t, ok, string(sdl.GetError())) do return
	defer render.gpu_destroy(&g)

	square :: proc(t: ^testing.T, g: ^render.Gpu, x0, y0, x1, y1, z: f32) -> render.Mesh {
		corner :: proc(x, y, z: f32) -> render.Vertex {return {position = {x, y, z}, normal = {0, 0, 1}, weights = {1, 0, 0, 0}}}
		vertices := []render.Vertex{corner(x0, y0, z), corner(x1, y0, z), corner(x1, y1, z), corner(x0, y1, z)}
		m, uploaded := render.mesh_upload(g, vertices, {0, 1, 2, 0, 2, 3})
		testing.expect(t, uploaded)
		return m
	}
	far := square(t, &g, -1, -1, 1, 1, 0)
	defer render.mesh_destroy(&g, far)
	near := square(t, &g, -1, 0.25, -0.25, 1, 1)
	defer render.mesh_destroy(&g, near)

	scene := render.scene_create()
	defer render.scene_destroy(&scene)
	scene.camera = {position = {0, 0, 5}, target = {0, 0, 0}, fov = math.PI / 3}
	scene.ambient = {1, 1, 1, 1}
	moved := matrix[4, 4]f32{1, 0, 0, 0.5, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}  // 0.5 m to the right
	draws := []render.Draw{{near, {1}, nil, {0, 1, 0, 1}}, {far, {moved}, nil, {1, 0, 0, 1}}}
	SIZE :: 64
	command := sdl.AcquireGPUCommandBuffer(device)
	if !testing.expect(t, render.draw_3d(&g, command, {SIZE, SIZE}, &scene, draws)) do return

	download := sdl.CreateGPUTransferBuffer(device, {usage = .DOWNLOAD, size = SIZE * SIZE * 4})
	defer sdl.ReleaseGPUTransferBuffer(device, download)
	pass := sdl.BeginGPUCopyPass(command)
	sdl.DownloadFromGPUTexture(pass, {texture = g.color, w = SIZE, h = SIZE, d = 1}, {transfer_buffer = download})
	sdl.EndGPUCopyPass(pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(command)
	defer sdl.ReleaseGPUFence(device, fence)
	testing.expect(t, sdl.WaitForGPUFences(device, true, &fence, 1))
	pixels := ([^][4]u8)(sdl.MapGPUTransferBuffer(device, download, false))
	defer sdl.UnmapGPUTransferBuffer(device, download)

	// The camera sees 2 * tan(30°) * distance across: the green square at x, y = -0.6, 0.6 sits near pixel (23, 23).
	testing.expect_value(t, pixels[23 * SIZE + 23], [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixels[40 * SIZE + 40], [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixels[40 * SIZE + 23], [4]u8{0, 0, 0, 255})  // x = -0.75: left of the moved red square
	testing.expect_value(t, pixels[2 * SIZE + 2], [4]u8{0, 0, 0, 255})
}
