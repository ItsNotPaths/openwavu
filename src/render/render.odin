// SDL3 GPU renderer: parts posed from the sim's bone matrices, stage scenes.
package render

Renderer :: struct {}

Model :: struct {}

// (hole render-gpu :tags render :sev blocker) no SDL3 window, GPU device or pipelines.
init :: proc(width, height: int) -> (r: ^Renderer, ok: bool) {
	return nil, false
}

// (hole glb-loader :tags render :needs (render-gpu) :sev blocker) parts and stages are not uploaded to the GPU.
load_glb :: proc(r: ^Renderer, path: string) -> (m: Model, ok: bool) {
	return {}, false
}

// (hole render-fighter :tags render :needs (render-gpu glb-loader mod-pose world-memory)) fighters are not drawn from the bone matrices in the world.
draw_fighter :: proc(r: ^Renderer, parts: []Model, bones: []matrix[4, 4]f32) {}

// (hole render-stage :tags render :needs (render-gpu glb-loader)) stages are not drawn; _DRWOFF_ meshes must start hidden.
draw_stage :: proc(r: ^Renderer, stage: Model) {}

// (hole hand-pose :tags render :needs (render-fighter hand-anims face-anims)) hand and face poses are not layered over the sim pose; which game code picks them is not known (presentation only, never in the sim).
// (hole render-api :tags (render sdk) :needs render-gpu) the app module has no host draw API: a 2D draw list, 3D fighter (loadout, anim), mesh and stage primitives, body slot swaps, material params.
draw_list :: proc(r: ^Renderer, commands: []byte) {}
