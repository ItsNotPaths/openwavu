// Every full TK6 move set converts into rows the TK6 sim loads and can trust, and Kazuya's electric and counter hit stun
// survive the rewrite. Needs ../tk6decomp/game; skips without it.
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import tk6_convert "../src/convert/tk6"
import "../src/db"
import tk6 "../src/formats/tk6"

TK6_SCHEMA :: #load("../src/db/tk6/schema.sql", string)
TK6_CONVERT_DB :: "build/tk6_convert_test.db"
TK6_MOTBIN_CHECK :: "build/tk6_motbin_check"

// The roster converts, the sim's loader takes every character, no TK6 id falls outside the id tables, and no value is
// cut on the way: the converter keeps every frame in the sim's width, the loader every db value (tk6_motbin_check).
@(test)
tk6_roster_converts :: proc(t: ^testing.T) {
	game, opened := tk6_game(t)
	if !opened do return
	defer tk6.close_game_files(&game)
	roster, listed := tk6.read_roster(game)
	if !testing.expect(t, listed, "roster not read") do return
	defer tk6.delete_roster(roster)

	w, created := db.create(TK6_CONVERT_DB, TK6_SCHEMA)
	if !testing.expect_value(t, created, "") do return
	defer os.remove(TK6_CONVERT_DB)
	command := make([dynamic]string, context.temp_allocator)
	append(&command, TK6_MOTBIN_CHECK, TK6_CONVERT_DB)
	for entry in roster {
		if !full_move_set(entry.name) do continue
		data, read := tk6.read_file(game, entry.index, allocator = context.temp_allocator)
		motbin, parsed := tk6.read_motbin(data, context.temp_allocator)
		if !testing.expectf(t, read && parsed, "%s: not read", entry.name) do continue
		character := fmt.tprintf("tk6_%d", entry.index)
		fallbacks: tk6_convert.Fallbacks
		testing.expectf(t, tk6_convert.write_moveset_rows(&w, character, character, motbin, &fallbacks) == "", "%s: not converted", entry.name)
		testing.expectf(t, len(fallbacks[.Requirement_Unknown]) == 0, "%s: requirement ids in no table: %v", entry.name, fallbacks[.Requirement_Unknown])
		testing.expectf(t, len(fallbacks[.Frame_Truncated]) == 0, "%s: frames cut: %v", entry.name, fallbacks[.Frame_Truncated])
		testing.expectf(t, len(fallbacks[.Command_Never]) == 0, "%s: inputs the text can not hold: %v", entry.name, fallbacks[.Command_Never])
		tk6_convert.delete_fallbacks(fallbacks)
		append(&command, character)
	}
	testing.expect_value(t, len(command) - 2, TK6_FULL_MOVE_SETS)
	if !testing.expect_value(t, db.finish(&w), "") do return

	if !testing.expect(t, build_tk6_motbin_check(), "tests/ref/tk6_motbin_check.c did not build") do return
	state, stdout, _, err := os.process_exec({command = command[:]}, context.temp_allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "the sim can not trust the rows:\n%s", stdout)
}

// Electric: forward, neutral, down, then down-forward + right punch on the down-forward frame. Both games build it from
// moves, not one input sequence: a forward step whose neutral cancels go to a one-frame move, whose down goes to the
// crouch-dash start, whose df+2 is the electric. Counter hit df+2 stuns: its counter reaction is a stun move the
// victim can not leave at once.
@(test)
tk6_kazuya_electric_and_stun_convert :: proc(t: ^testing.T) {
	game, opened := tk6_game(t)
	if !opened do return
	defer tk6.close_game_files(&game)
	roster, listed := tk6.read_roster(game)
	if !testing.expect(t, listed, "roster not read") do return
	defer tk6.delete_roster(roster)
	index := -1
	for entry in roster do if entry.name == "[KAZUYA]" do index = entry.index
	if !testing.expect(t, index >= 0, "no [KAZUYA]") do return
	data, _ := tk6.read_file(game, index, allocator = context.temp_allocator)
	motbin, parsed := tk6.read_motbin(data, context.temp_allocator)
	if !testing.expect(t, parsed, "[KAZUYA] not read") do return
	fallbacks: tk6_convert.Fallbacks
	defer tk6_convert.delete_fallbacks(fallbacks)
	context.allocator = context.temp_allocator
	sim := tk6_convert.sim_motbin(motbin, &fallbacks)

	electric, electric_source := -1, -1
	forward_steps := make(map[int]bool)
	for move in 0 ..< len(sim.moves) do for step in cancel_targets(sim, move, "f@") do forward_steps[step] = true
	for step in forward_steps {  // the scan takes a move's first matching entry
		one_frame := first_target(sim, step, "n@1..1>1") or_continue
		crouch_dash := first_target(sim, one_frame, "d@") or_continue
		electric = first_target(sim, crouch_dash, "df+2@1..") or_continue
		electric_source = crouch_dash
	}
	if !testing.expect(t, electric >= 0, "no f, n, d, df+2 chain") do return
	active_first, active_last := sim.moves[electric].unknown_48[1], sim.moves[electric].unknown_48[2]
	testing.expectf(t, active_first == 11 && active_last == 12, "electric active %d..%d, want 11..12", active_first, active_last)
	electric_command: u64
	for cancel in cancel_entries(sim, electric_source) do if int(cancel.move) == electric do electric_command = cancel.command
	testing.expectf(t, electric_command == DOWN_FORWARD << 32 | tk6_convert.BUTTON_HOLD_AFTER_PRESS | RIGHT_PUNCH,
		"electric command %x", electric_command)

	// An input sequence, as steps and a window: down, down-forward, down, down-forward + both punches.
	sequence_found := false
	for cancel in sim.cancels {
		_, text, _ := tk6_convert.cancel_input(sim, cancel)
		sequence_found ||= strings.has_prefix(text, "{d,df,d,df+1+2}59@")
	}
	testing.expect(t, sequence_found, "no {d,df,d,df+1+2}59 sequence")

	idle := int(sim.aliases[IDLE_STAND_SLOT])
	stun_found := false
	for uppercut in cancel_targets(sim, idle, "df+2@") {
		move := sim.moves[uppercut]
		for condition in sim.hit_conditions[move.hit_conditions:] {
			reaction := sim.reactions[condition.reaction]
			stun := int(reaction.move_counter)
			if condition.unk_06 > 0 && reaction.move_counter != reaction.move_standing && stun < len(sim.moves) {
				for cancel in cancel_entries(sim, stun) do stun_found ||= cancel.command >> 32 != tk6_convert.COMMAND_END && cancel.window_start > 1
			}
			if sim.requirements[condition.requirements].id == tk6_convert.REQUIREMENT_LIST_END do break  // the last condition
		}
	}
	testing.expect(t, stun_found, "no counter hit df+2 stun move with a later cancel window")
}

TK6_FULL_MOVE_SETS :: 84
IDLE_STAND_SLOT :: 1
DOWN_FORWARD :: 1 << 3
RIGHT_PUNCH :: 2

@(private = "file")
tk6_game :: proc(t: ^testing.T) -> (game: tk6.Game_Files, ok: bool) {
	if !os.exists(TK6_USRDIR + "/TEKKEN.psarc") do return
	game, ok = tk6.open_game_files(TK6_USRDIR)
	testing.expect(t, ok, "game files not opened")
	return
}

// [NAME] and [NAME]1; not the menu sets, the campaign enemies, the bonus stage's two-move sets.
@(private = "file")
full_move_set :: proc(name: string) -> bool {
	inner := strings.trim_suffix(name, "1")
	if len(inner) < 3 || inner[0] != '[' || inner[len(inner) - 1] != ']' || inner == "[select]" do return false
	if strings.has_prefix(inner, "[Zako") || strings.has_prefix(inner, "[RT2_") do return false
	for character in inner[1:len(inner) - 1] {
		if !(character == '_' || (character >= '0' && character <= '9') || (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z')) do return false
	}
	return true
}

// The entries a move scans, group lists inlined, up to its end entry.
@(private = "file")
cancel_entries :: proc(m: tk6.Motbin, move: int) -> []tk6.Cancel {
	entries := make([dynamic]tk6.Cancel, context.temp_allocator)
	for index := int(m.moves[move].cancels); index < len(m.cancels); index += 1 {
		cancel := m.cancels[index]
		if cancel.command >> 32 == tk6_convert.COMMAND_GROUP {
			for group := int(cancel.move); m.group_cancels[group].command >> 32 != tk6_convert.COMMAND_GROUP_END; group += 1 {
				append(&entries, m.group_cancels[group])
			}
			continue
		}
		append(&entries, cancel)
		if cancel.command >> 32 == tk6_convert.COMMAND_END do break
	}
	return entries[:]
}

// Plain moves a move's entries go to when their input text starts with `input`.
@(private = "file")
cancel_targets :: proc(m: tk6.Motbin, move: int, input: string) -> []int {
	targets := make([dynamic]int, context.temp_allocator)
	for cancel in cancel_entries(m, move) {
		_, text, _ := tk6_convert.cancel_input(m, cancel)
		if strings.has_prefix(text, input) && int(cancel.move) < len(m.moves) do append(&targets, int(cancel.move))
	}
	return targets[:]
}

@(private = "file")
first_target :: proc(m: tk6.Motbin, move: int, input: string) -> (target: int, ok: bool) {
	targets := cancel_targets(m, move, input)
	if len(targets) == 0 do return
	return targets[0], true
}

@(private = "file")
build_tk6_motbin_check :: proc() -> bool {
	sim :: "modules/tk6/sim/"
	command := []string{
		"cc", "-std=c23", "-fwrapv", "-ffp-contract=off", "-Imodules/tk6", "-Isdk/include", "-Ivendor/sqlite", "-Ivendor/jsmn",
		"-o", TK6_MOTBIN_CHECK, "tests/ref/tk6_motbin_check.c", "modules/tk6/load.c", sim + "stage_file.c", sim + "anim.c",
		sim + "fighter_data.c", sim + "motbin.c", sim + "skel.c", sim + "math.c", sim + "quat.c", sim + "vec.c",
		"vendor/sqlite/libsqlite3.a", "-lpthread", "-lm",
	}
	state, _, _, err := os.process_exec({command = command}, context.temp_allocator)
	return err == nil && state.exit_code == 0
}
