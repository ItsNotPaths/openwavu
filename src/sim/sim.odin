// The sim host: runs a title pack's gameplay module. The module owns its memory; a snapshot is that memory
// plus its globals. Bit exact to the game with the stock TK5 sim.
package sim

import "../wasm"

Input :: struct {
	pad: u16,  // Tekken pad bits, the same in every Tekken
}

World :: struct {
	instance: ^wasm.Instance,
	memory:   []byte,  // the gameplay module's own memory
}

// (hole world-memory :tags sim :needs module-memory :sev blocker) no sim instance; the param, loadout and match_seed imports are not served to its init export.
create :: proc(module: ^wasm.Module, params: map[string]f64, loadouts: [2][]byte) -> (w: ^World) {
	return nil
}

// (hole sim-step :tags sim :needs world-memory :sev blocker) the host does not call the gameplay module's sim step export each frame.
// (hole visual-step :tags sim :needs sim-step) the host does not call ow_visual_step once per displayed frame after the sim step, nor ow_visual_reset on a replay seek.
step :: proc(w: ^World, inputs: [2]Input) {}

// (hole module-snapshot :tags (sim net) :needs (world-memory snapshot-range) :sev blocker) no save/restore of the gameplay module's exported mutable range plus its globals.
save :: proc(w: ^World, buf: []byte) -> (size: int) {
	return 0
}

restore :: proc(w: ^World, buf: []byte) -> (ok: bool) {
	return false
}

// The view the app reads: the sim's ow_view export, copied into the app module each frame.
// (hole sim-view :tags (sim game) :needs (world-memory app-host)) the sim view is not copied into the app module.
view :: proc(w: ^World) -> []byte {
	return nil
}

// (hole event-stream :tags sim) no ow_event import: KO, round end and match end are not collected for match reports and lobby rotation.
events :: proc(w: ^World) -> []u8 {
	return nil
}
