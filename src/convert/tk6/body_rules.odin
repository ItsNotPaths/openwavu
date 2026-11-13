// The rules TK6 gives its two bosses by model in code, written as body data (tk6decomp docs/sim_contract.md 9.5).
package tk6_convert

import "../../db"

MODEL_AZAZEL :: 38
MODEL_NANCY :: 39

// Azazel: 240 points, no reaction to a guarded hit (in his guard class the guard move), no throws or reversals. NANCY:
// 600 points whatever the health setting (as a player; 1000 as a CPU), never a reaction move, no throws or reversals,
// no chip damage, no KO flashback.
write_body_rules :: proc(w: ^db.Writer, character: string, model: int) {
	switch model {
	case MODEL_AZAZEL: db.insert(w, "body_rule", character, i64(240), i64(0), "when_guarding", "azazel_guard", i64(1), i64(0), i64(0))
	case MODEL_NANCY: db.insert(w, "body_rule", character, i64(600), i64(1), "always", db.Null{}, i64(1), i64(1), i64(1))
	}
}
