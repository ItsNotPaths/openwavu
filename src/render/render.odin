// The window's renderer: the 3D scene the pack sends (gpu.odin) and 2D (menus, UI, pack 2D) through an SDL_Renderer on
// the same Vulkan device (docs/app.md).
package render

import sdl "vendor:sdl3"

Renderer :: struct {
	window:      ^sdl.Window,
	device:      ^sdl.GPUDevice,  // Vulkan, shared by the 2D renderer and the 3D
	r2d:         ^sdl.Renderer,
	gpu:         Gpu,
	scene:       Scene,           // the last scene the app sent; kept until the next one
	scene_image: ^sdl.Texture,    // gpu.color for the 2D renderer
	image_of:    ^sdl.GPUTexture, // the gpu.color scene_image wraps
}

init :: proc(title: cstring, width, height: i32) -> (r: Renderer, ok: bool) {
	if !sdl.Init({.VIDEO, .GAMEPAD}) {
		return {}, false
	}
	r.window = sdl.CreateWindow(title, width, height, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if r.window == nil {
		return {}, false
	}
	r.device = sdl.CreateGPUDevice({.SPIRV}, false, "vulkan")
	if r.device != nil do r.r2d = sdl.CreateGPURenderer(r.device, r.window)
	gpu_ok := false
	if r.r2d != nil do r.gpu, gpu_ok = gpu_create(r.device)
	if !gpu_ok {
		if r.r2d != nil do sdl.DestroyRenderer(r.r2d)
		if r.device != nil do sdl.DestroyGPUDevice(r.device)
		sdl.DestroyWindow(r.window)
		return {}, false
	}
	r.scene = scene_create()
	sdl.SetRenderVSync(r.r2d, 1)
	sdl.SetRenderDrawBlendMode(r.r2d, sdl.BLENDMODE_BLEND)
	return r, true
}

destroy :: proc(r: ^Renderer) {
	scene_destroy(&r.scene)
	if r.scene_image != nil do sdl.DestroyTexture(r.scene_image)
	gpu_destroy(&r.gpu)
	sdl.DestroyRenderer(r.r2d)
	sdl.DestroyGPUDevice(r.device)
	sdl.DestroyWindow(r.window)
	sdl.Quit()
}

size :: proc(r: ^Renderer) -> [2]f32 {
	w, h: i32
	sdl.GetCurrentRenderOutputSize(r.r2d, &w, &h)
	return {f32(w), f32(h)}
}

begin_frame :: proc(r: ^Renderer, clear: [4]f32) {
	sdl.SetRenderDrawColorFloat(r.r2d, clear.r, clear.g, clear.b, clear.a)
	sdl.RenderClear(r.r2d)
}

end_frame :: proc(r: ^Renderer) {
	sdl.RenderPresent(r.r2d)
}

toggle_fullscreen :: proc(r: ^Renderer) {
	sdl.SetWindowFullscreen(r.window, .FULLSCREEN not_in sdl.GetWindowFlags(r.window))
}

// Shows a newly sent scene from now on; s gets the old one's arrays to read the next into.
show_scene :: proc(r: ^Renderer, s: ^Scene) {
	r.scene, s^ = s^, r.scene
}

// Queues the frame's 3D image as the first 2D draw, so the pack's 2D lands on top. draw_scene renders that image later
// in the frame, from the scene the pack sends this frame, and submits it before the 2D renderer presents.
queue_scene :: proc(r: ^Renderer) -> (ok: bool) {
	w, h: i32
	sdl.GetCurrentRenderOutputSize(r.r2d, &w, &h)
	gpu_targets(&r.gpu, {u32(max(w, 1)), u32(max(h, 1))}) or_return
	if r.image_of != r.gpu.color {
		if r.scene_image != nil do sdl.DestroyTexture(r.scene_image)
		props := sdl.CreateProperties()
		defer sdl.DestroyProperties(props)
		sdl.SetPointerProperty(props, sdl.PROP_TEXTURE_CREATE_GPU_TEXTURE_POINTER, r.gpu.color)
		sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_FORMAT_NUMBER, i64(sdl.PixelFormat.ABGR8888))  // COLOR_FORMAT
		sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_WIDTH_NUMBER, i64(r.gpu.size.x))
		sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_HEIGHT_NUMBER, i64(r.gpu.size.y))
		r.scene_image = sdl.CreateTextureWithProperties(r.r2d, props)
		if r.scene_image == nil do return false
		r.image_of = r.gpu.color
	}
	return sdl.RenderTexture(r.r2d, r.scene_image, nil, nil)
}

// alpha: how far the display is between the last two sim ticks.
// (hole render-fighter :tags render) skinned scene nodes are not drawn from their bones (position, rotation, scale).
// (hole render-stage :tags render) mesh scene nodes are not drawn: no part of a glb, no hidden parts left out of the whole glb, _DRWOFF_ nodes not left out.
// (hole scene-blend :tags render) no blending between the scenes of the last two sim ticks: nodes matched by id, bones, camera, clip times, fx ages; no-blend flag, gameplay class and the fps setting.
draw_scene :: proc(r: ^Renderer, alpha: f32) -> (ok: bool) {
	command := sdl.AcquireGPUCommandBuffer(r.device)
	if command == nil do return false
	if !draw_3d(&r.gpu, command, r.gpu.size, &r.scene, nil) {
		_ = sdl.CancelGPUCommandBuffer(command)
		return false
	}
	return sdl.SubmitGPUCommandBuffer(command)
}
