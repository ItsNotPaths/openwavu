// SDL3 GPU renderer: parts posed from the sim's bone matrices, stage scenes.
package render

Renderer :: struct {}

Model :: struct {}

// (hole render-gpu :tags render :sev blocker) no SDL3 window, GPU device or pipelines.
init :: proc(width, height: int) -> (r: ^Renderer, ok: bool) {
	return nil, false
}

// (hole glb-loader :tags render :needs (glb-reader render-gpu) :sev blocker) parts and stages are not uploaded to the GPU.
load_glb :: proc(r: ^Renderer, path: string) -> (m: Model, ok: bool) {
	return {}, false
}

// (hole render-fighter :tags render :needs (render-gpu glb-loader mod-pose world-memory)) fighters are not drawn from the bone matrices in the world.
draw_fighter :: proc(r: ^Renderer, parts: []Model, bones: []matrix[4, 4]f32) {}

// (hole render-stage :tags render :needs (render-gpu glb-loader)) stages are not drawn; _DRWOFF_ meshes must start hidden.
draw_stage :: proc(r: ^Renderer, stage: Model) {}

// (hole render-api :tags (render sdk) :needs (render-gpu seam-abi)) presentation modules (effects, camera, UI) have no host draw API: particles, meshes at bones, text, shader parameters.
draw_presentation :: proc(r: ^Renderer, world: []byte) {}
