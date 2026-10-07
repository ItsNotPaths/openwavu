// The sim host: runs a title pack's sim modules on one shared world memory. Bit exact to the game
// with the default TK5 modules.
package sim

import "../content"
import "../wasm"

SEAMS :: [?]string{"frame", "input", "state", "motion", "collision", "hit", "pose", "match"}

Input :: struct {
	pad: u16,  // raw TK5 pad bits
}

World :: struct {
	memory:    []byte,  // the shared world; layout from sdk/include/openwavu.h
	instances: [len(SEAMS)]^wasm.Instance,
}

// (hole world-memory :tags sim :needs seam-abi :sev blocker) no shared world memory, no instances of the sim seams, no rules block filled from the pack.
create :: proc(modules: [len(SEAMS)]^wasm.Module, rules: map[string]string) -> (w: ^World) {
	return nil
}

// (hole fighter-data-load :tags (sim content) :needs (world-memory pack-open) :sev blocker) moveset rows and .anim files are not loaded into the world for the seams.
load_fighter :: proc(w: ^World, slot: int, p: ^content.Pack, character, costume: string) -> (ok: bool) {
	return false
}

// (hole seam-wiring :tags sim :needs world-memory :sev blocker) the host does not run the frame seam or route its calls to the other seams.
step :: proc(w: ^World, inputs: [2]Input) {}

// (hole module-snapshot :tags (sim net) :needs world-memory :sev blocker) no save/restore of the world memory plus each module's private memory and globals.
save :: proc(w: ^World, buf: []byte) -> (size: int) {
	return 0
}

restore :: proc(w: ^World, buf: []byte) -> (ok: bool) {
	return false
}

// (hole event-stream :tags (sim render) :needs seam-abi) no event stream (KO, round end, hits, spawn effect); presentation can not cancel effects of rolled-back frames.
events :: proc(w: ^World) -> []u8 {
	return nil
}
