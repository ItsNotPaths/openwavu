// SDL3 GPU renderer: parts posed from the sim's bone matrices, stage scenes.
// 2D (menus, UI) goes through an SDL_Renderer on the same GPU device.
package render

import sdl "vendor:sdl3"

Renderer :: struct {
	window: ^sdl.Window,
	gpu:    ^sdl.GPUDevice,
	r2d:    ^sdl.Renderer,
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
	sdl.SetRenderVSync(r.r2d, 1)
	sdl.SetRenderDrawBlendMode(r.r2d, sdl.BLENDMODE_BLEND)
	return r, true
}

destroy :: proc(r: ^Renderer) {
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

// (hole render-fighter :tags render :needs (render-gpu glb-loader world-memory)) fighters are not drawn from the bone matrices in the world.
draw_fighter :: proc(r: ^Renderer, parts: []Model, bones: []matrix[4, 4]f32) {}

// (hole render-stage :tags render :needs (render-gpu glb-loader)) stages are not drawn; _DRWOFF_ meshes must start hidden.
draw_stage :: proc(r: ^Renderer, stage: Model) {}

// (hole hand-pose :tags render :needs (render-fighter visual-view face-anims)) the visual skeleton from ow_visual_view (fingers, face, eyes, head tilt over the hitbox skeleton) is not drawn; only the sim pose is.
// (hole render-api :tags (render sdk) :needs render-gpu) the app module has no host draw API: a 2D draw list, 3D fighter (loadout, anim), mesh and stage primitives, body slot swaps, material params.
draw_list :: proc(r: ^Renderer, commands: []byte) {}
