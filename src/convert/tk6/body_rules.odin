// The rules TK6 gives some models in code, written as body data (tk6decomp docs/sim_contract.md 9.5).
package tk6_convert

import "../../db"

MODEL_MOKUJIN :: 18
MODEL_AZAZEL :: 38
MODEL_NANCY :: 39

// health, health_fixed, reaction_keeping, guard_move_class, unthrowable, no_chip_damage, no_flashback, plain_push
@(private = "file")
Rules :: [8]db.Value

// hit_sound, heavy damage, heavy kick, heavy punch, random first, random count (FUN_002ed920)
@(private = "file")
Hit_Sounds :: [6]i64

// Azazel: 240 points, no reaction to a guarded hit (in his guard class the guard move), no throws or reversals. NANCY:
// 600 points whatever the health setting (as a player; 1000 as a CPU), never a reaction move, no throws or reversals,
// no chip damage, no KO flashback, plain push spheres in her fights. Jack-6 and Mokujin: their own hit sounds.
write_body_rules :: proc(w: ^db.Writer, character: string, model: int) {
	plain := Rules{i64(0), i64(0), "reacts", db.Null{}, i64(0), i64(0), i64(0), i64(0)}
	switch model {
	case MODEL_AZAZEL: insert_rules(w, character, {i64(240), i64(0), "when_guarding", "azazel_guard", i64(1), i64(0), i64(0), i64(0)}, {})
	case MODEL_NANCY: insert_rules(w, character, {i64(600), i64(1), "always", db.Null{}, i64(1), i64(1), i64(1), i64(1)}, {})
	case MODEL_JACK6: insert_rules(w, character, plain, {497, 20, 499, 500, 0, 0})
	// [open] the game also checks a flag of the defender's sound slot (FUN_002e9ad8)
	case MODEL_MOKUJIN: insert_rules(w, character, plain, {0, 0, 0, 0, 468, 5})
	}
}

@(private = "file")
insert_rules :: proc(w: ^db.Writer, character: string, rules: Rules, sounds: Hit_Sounds) {
	rules, sounds := rules, sounds
	row := make([dynamic]db.Value, context.temp_allocator)
	append(&row, character)
	append(&row, ..rules[:])
	for sound in sounds do append(&row, sound)
	db.insert(w, "body_rule", ..row[:])
}
