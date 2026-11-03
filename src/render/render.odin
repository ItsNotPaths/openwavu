// The window's renderer: the 3D scene the pack sends (gpu.odin) and 2D (menus, UI, pack 2D) through an SDL_Renderer on
// the same Vulkan device (docs/app.md).
package render

import sdl "vendor:sdl3"

Renderer :: struct {
	window:      ^sdl.Window,
	device:      ^sdl.GPUDevice,  // Vulkan, shared by the 2D renderer and the 3D
	renderer_2d:         ^sdl.Renderer,
	gpu:         Gpu,
	scene:       Scene,           // the last scene the pack sent; kept until the next one
	from:        Scene,           // the last scene of the tick before scene's: where blending starts
	scene_image: ^sdl.Texture,    // gpu.color for the 2D renderer
	image_of:    ^sdl.GPUTexture, // the gpu.color scene_image wraps
}

init :: proc(title: cstring, width, height: i32) -> (renderer: Renderer, ok: bool) {
	if !sdl.Init({.VIDEO, .GAMEPAD}) {
		return {}, false
	}
	renderer.window = sdl.CreateWindow(title, width, height, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if renderer.window == nil {
		return {}, false
	}
	renderer.device = sdl.CreateGPUDevice({.SPIRV}, false, "vulkan")
	if renderer.device != nil do renderer.renderer_2d = sdl.CreateGPURenderer(renderer.device, renderer.window)
	gpu_ok := false
	if renderer.renderer_2d != nil do renderer.gpu, gpu_ok = gpu_create(renderer.device)
	if !gpu_ok {
		if renderer.renderer_2d != nil do sdl.DestroyRenderer(renderer.renderer_2d)
		if renderer.device != nil do sdl.DestroyGPUDevice(renderer.device)
		sdl.DestroyWindow(renderer.window)
		return {}, false
	}
	renderer.scene, renderer.from = scene_create(), scene_create()
	sdl.SetRenderVSync(renderer.renderer_2d, 1)
	sdl.SetRenderDrawBlendMode(renderer.renderer_2d, sdl.BLENDMODE_BLEND)
	return renderer, true
}

destroy :: proc(renderer: ^Renderer) {
	scene_destroy(&renderer.scene)
	scene_destroy(&renderer.from)
	if renderer.scene_image != nil do sdl.DestroyTexture(renderer.scene_image)
	gpu_destroy(&renderer.gpu)
	sdl.DestroyRenderer(renderer.renderer_2d)
	sdl.DestroyGPUDevice(renderer.device)
	sdl.DestroyWindow(renderer.window)
	sdl.Quit()
}

size :: proc(renderer: ^Renderer) -> [2]f32 {
	width, height: i32
	sdl.GetCurrentRenderOutputSize(renderer.renderer_2d, &width, &height)
	return {f32(width), f32(height)}
}

begin_frame :: proc(renderer: ^Renderer, clear: [4]f32) {
	sdl.SetRenderDrawColorFloat(renderer.renderer_2d, clear.r, clear.g, clear.b, clear.a)
	sdl.RenderClear(renderer.renderer_2d)
}

end_frame :: proc(renderer: ^Renderer) {
	sdl.RenderPresent(renderer.renderer_2d)
}

toggle_fullscreen :: proc(renderer: ^Renderer) {
	sdl.SetWindowFullscreen(renderer.window, .FULLSCREEN not_in sdl.GetWindowFlags(renderer.window))
}

// Shows a newly sent scene from now on; scene gets back arrays to read the next into. ticked: it is a new sim tick's, so
// the scene so far becomes where blending starts; else it replaces the current one.
show_scene :: proc(renderer: ^Renderer, scene: ^Scene, ticked: bool) {
	if ticked do renderer.from, renderer.scene = renderer.scene, renderer.from
	renderer.scene, scene^ = scene^, renderer.scene
}

// Queues the frame's 3D image as the first 2D draw, so the pack's 2D lands on top. draw_scene renders that image later
// in the frame, from the scene the pack sends this frame, and submits it before the 2D renderer presents.
queue_scene :: proc(renderer: ^Renderer) -> (ok: bool) {
	width, height: i32
	sdl.GetCurrentRenderOutputSize(renderer.renderer_2d, &width, &height)
	gpu_targets(&renderer.gpu, {u32(max(width, 1)), u32(max(height, 1))}) or_return
	if renderer.image_of != renderer.gpu.color {
		if renderer.scene_image != nil do sdl.DestroyTexture(renderer.scene_image)
		props := sdl.CreateProperties()
		defer sdl.DestroyProperties(props)
		sdl.SetPointerProperty(props, sdl.PROP_TEXTURE_CREATE_GPU_TEXTURE_POINTER, renderer.gpu.color)
		sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_FORMAT_NUMBER, i64(sdl.PixelFormat.ABGR8888))  // COLOR_FORMAT
		sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_WIDTH_NUMBER, i64(renderer.gpu.size.x))
		sdl.SetNumberProperty(props, sdl.PROP_TEXTURE_CREATE_HEIGHT_NUMBER, i64(renderer.gpu.size.y))
		renderer.scene_image = sdl.CreateTextureWithProperties(renderer.renderer_2d, props)
		if renderer.scene_image == nil do return false
		renderer.image_of = renderer.gpu.color
	}
	return sdl.RenderTexture(renderer.renderer_2d, renderer.scene_image, nil, nil)
}

// alpha: how far the display is from the last tick's scene to the newest. assets: the pack's, which the scene names;
// nil draws no nodes.
draw_scene :: proc(renderer: ^Renderer, assets: ^Assets, alpha: f32) -> (ok: bool) {
	command := sdl.AcquireGPUCommandBuffer(renderer.device)
	if command == nil do return false
	shown := blend_scenes(&renderer.from, &renderer.scene, alpha)
	draws := assets != nil ? scene_draws(shown, assets, &renderer.gpu) : nil
	if !draw_3d(&renderer.gpu, command, renderer.gpu.size, shown, draws) {
		_ = sdl.CancelGPUCommandBuffer(command)
		return false
	}
	return sdl.SubmitGPUCommandBuffer(command)
}
