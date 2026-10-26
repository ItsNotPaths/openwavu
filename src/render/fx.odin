// Host fx: plays effect defs (particles, trails, decals, meshes at bones). The app spawns directly, the sim through cues.
package render

Fx :: distinct u32

Fx_Attach :: struct {
	fighter, bone: i32,  // fighter -1: world position
	position:      [3]f32,
}

// (hole fx-api :tags (render sdk) :needs (render-gpu cue-api)) no ow_fx_spawn/param/kill and no effect def format.
fx_spawn :: proc(r: ^Renderer, def: u32, at: Fx_Attach, frame: u32, key: u32) -> Fx {
	return 0
}
