// SDL3 GPU renderer: draws the 3D scene the app module sends (docs/app.md).
// 2D (menus, UI) goes through an SDL_Renderer on the same GPU device.
package render

import sdl "vendor:sdl3"

Renderer :: struct {
	window: ^sdl.Window,
	gpu:    ^sdl.GPUDevice,
	r2d:    ^sdl.Renderer,
	scene:  Scene,  // the last scene the app sent; kept until the next one
}

Model :: struct {}

init :: proc(title: cstring, width, height: i32) -> (r: Renderer, ok: bool) {
	if !sdl.Init({.VIDEO, .GAMEPAD}) {
		return {}, false
	}
	r.window = sdl.CreateWindow(title, width, height, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if r.window == nil {
		return {}, false
	}
	r.r2d = sdl.CreateGPURenderer(nil, r.window)
	if r.r2d == nil {
		sdl.DestroyWindow(r.window)
		return {}, false
	}
	r.gpu = sdl.GetGPURendererDevice(r.r2d)
	r.scene = scene_create()
	sdl.SetRenderVSync(r.r2d, 1)
	sdl.SetRenderDrawBlendMode(r.r2d, sdl.BLENDMODE_BLEND)
	return r, true
}

destroy :: proc(r: ^Renderer) {
	scene_destroy(&r.scene)
	sdl.DestroyRenderer(r.r2d)
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

// (hole render-gpu :tags render :sev blocker) no 3D pipelines: depth target, skinned mesh and stage shaders.
// (hole glb-loader :tags render :needs (render-gpu) :sev blocker) parts and stages are not uploaded to the GPU.
load_glb :: proc(r: ^Renderer, path: string) -> (m: Model, ok: bool) {
	return {}, false
}

// Shows a newly sent scene from now on; s gets the old one's arrays to read the next into.
show_scene :: proc(r: ^Renderer, s: ^Scene) {
	r.scene, s^ = s^, r.scene
}

// alpha: how far the display is between the last two sim ticks.
// (hole render-fighter :tags render :needs (render-gpu glb-loader)) skinned scene nodes are not drawn from their bones (position, rotation, scale).
// (hole render-stage :tags render :needs (render-gpu glb-loader)) mesh scene nodes are not drawn: no part of a glb, no hidden parts left out of the whole glb, _DRWOFF_ nodes not left out.
// (hole scene-blend :tags render) no blending between the scenes of the last two sim ticks: nodes matched by id, bones, camera, clip times, fx ages; no-blend flag, gameplay class and the fps setting.
draw_scene :: proc(r: ^Renderer, alpha: f32) {}
