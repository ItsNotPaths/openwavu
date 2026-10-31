// Host fx: plays effect defs (sprites, meshes, ribbons, bursts at visual bones). The app spawns directly, the sim through cues.
package render

Fx :: distinct u32

Fx_Attach :: struct {
	fighter, bone: i32,  // fighter -1: world position
	position:      [3]f32,
}

// (hole fx-spec :tags (render content)) no effect def schema (elements, curves, inputs; ws.md Decisions), drafted from what TK5 EFP uses.
// (hole fx-api :tags (render sdk) :needs (render-gpu cue-api fx-spec visual-view)) no ow_fx_spawn/param/kill; effects are not played or attached to visual bones.
fx_spawn :: proc(r: ^Renderer, def: u32, at: Fx_Attach, frame: u32, key: u32) -> Fx {
	return 0
}
