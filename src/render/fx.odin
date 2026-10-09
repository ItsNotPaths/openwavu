// Host fx: plays effect defs (particles, trails, decals, meshes at bones). sim and app both spawn.
// A sim spawn carries a key: a resimulated (frame, key) is ignored, a spawn not repeated is killed.
package render

Fx :: distinct u32

Fx_Attach :: struct {
	fighter, bone: i32,  // fighter -1: world position
	position:      [3]f32,
}

// (hole fx-api :tags (render sdk) :needs render-gpu) no ow_fx_spawn/param/kill, no effect def format, no keyed reconcile after rollback.
fx_spawn :: proc(r: ^Renderer, def: u32, at: Fx_Attach, frame: u32, key: u32) -> Fx {
	return 0
}
