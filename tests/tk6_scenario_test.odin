// Scripted inputs through the TK6 gameplay module, natively (tests/ref/tk6_scenario.c): Kazuya against Kazuya, the
// first side on the left. Needs ../tk6decomp/game; skips without it.
package tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

TK6_SCENARIO_TOOL :: "build/tk6_scenario"

// Script pads are OW_PAD_* words in hex: 8 forward (right, from the left side), 2 down, a down-forward, 10 button 1,
// 20 button 2.

// kazuya/move/592: the electric, the crouch-dash start's df+2 (tk6_convert_test finds it from the f, n, d, df+2 chain).
KAZUYA_ELECTRIC :: 592

// One side in one frame.
Scenario_Side :: struct {
	move, bounds, health: int,
	air_window:           bool,
}

// The frames of each "mark" block in turn; block 0 is the frames before the first mark.
Scenario_Run :: [dynamic][dynamic][2]Scenario_Side

@(private = "file")
whole_number :: proc(text: string) -> int {
	value, _ := strconv.parse_int(text)
	return value
}

@(private = "file")
build_scenario_tool :: proc() -> bool {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "cc", "-std=c23", "-O1", "-fwrapv", "-ffp-contract=off", "-Wno-attributes", "-Imodules/tk6", "-Isdk/include",
		"-Ivendor/sqlite", "-Ivendor/jsmn", "-o", TK6_SCENARIO_TOOL, "tests/ref/tk6_scenario.c", "modules/tk6/load.c",
		"modules/tk6/pack_file.c", "modules/tk6/view.c")
	for folder in ([]string{"modules/tk6/sim", "modules/tk6/gameplay"}) {
		entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
		if err != nil do return false
		for entry in entries do if strings.has_suffix(entry.name, ".c") do append(&command, entry.fullpath)
	}
	append(&command, "vendor/sqlite/libsqlite3.a", "-lpthread", "-lm")
	state, _, _, err := os.process_exec({command = command[:]}, context.temp_allocator)
	return err == nil && state.exit_code == 0
}

@(private = "file")
run_tool :: proc(t: ^testing.T, pack, stage, script: string) -> (stdout: []byte, ok: bool) {
	script_path :: "build/tk6_scenario.txt"
	if !testing.expect(t, os.write_entire_file(script_path, transmute([]byte)script) == nil, "script not written") do return
	state, out, _, err := os.process_exec({command = {TK6_SCENARIO_TOOL, pack, "kazuya", "kazuya", stage, script_path}}, context.temp_allocator)
	if !testing.expectf(t, err == nil && state.exit_code == 0, "the scenario tool failed on %s (%v)", stage, state.exit_code) do return
	return out, true
}

// Runs a script and reads its state lines, split at its marks.
@(private = "file")
run_scenario :: proc(t: ^testing.T, script: string) -> (run: Scenario_Run, ok: bool) {
	pack, imported := tk6_pack(t)
	if !imported do return
	if !testing.expect(t, build_scenario_tool(), "tests/ref/tk6_scenario.c did not build") do return
	stdout := run_tool(t, pack, "stage_00", script) or_return
	run.allocator = context.temp_allocator
	append(&run, make([dynamic][2]Scenario_Side, context.temp_allocator))
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) > 0 && fields[0] == "mark" do append(&run, make([dynamic][2]Scenario_Side, context.temp_allocator))
		if len(fields) != 14 || fields[0] != "state" do continue
		frame: [2]Scenario_Side
		for side in 0 ..< 2 {
			at := 2 + 6 * side
			frame[side] = {move = whole_number(fields[at]), bounds = whole_number(fields[at + 2]),
				air_window = fields[at + 3] == "1", health = whole_number(fields[at + 4])}
		}
		append(&run[len(run) - 1], frame)
	}
	return run, true
}

// Walk in, stop, then the electric frame-perfect: f, n, d, df+2 on four frames in a row. The defender walks forward,
// so it does not guard.
@(private = "file")
ELECTRIC_SCRIPT :: "fight\nstep 20 8 8\nstep 5 0 8\nstep 1 8 8\nstep 1 0 8\nstep 1 2 8\nstep 1 2a 8\n"

@(test)
tk6_electric_comes_out :: proc(t: ^testing.T) {
	run, ran := run_scenario(t, ELECTRIC_SCRIPT + "step 40 0 8\n")
	if !ran do return
	electric, launched := false, false
	for frame in run[0] {
		electric ||= frame[0].move == KAZUYA_ELECTRIC
		launched ||= electric && frame[1].air_window && frame[1].health < run[0][0][1].health
	}
	testing.expect(t, electric, "f, n, d, df+2 on four frames did not give the electric")
	testing.expect(t, launched, "the electric did not hit and launch")
}

// d/f+1 alone hits without juggling; d/f+1,2 bounds on hit two.
@(test)
tk6_bound_on_hit_two :: proc(t: ^testing.T) {
	jab := "fight\nstep 20 8 8\nstep 5 0 8\nstep 1 1a 8\nstep 80 0 8\n"
	run, ran := run_scenario(t, jab)
	if !ran do return
	frames := run[0]
	testing.expect(t, frames[len(frames) - 1][1].health < frames[0][1].health, "d/f+1 did not hit")
	for frame in frames do if !testing.expect(t, !frame[1].air_window && frame[1].bounds == 0, "d/f+1 alone juggled or bounded") do break

	run, ran = run_scenario(t, "fight\nstep 20 8 8\nstep 5 0 8\nstep 1 1a 8\nstep 8 0 8\nstep 1 20 8\nstep 80 0 8\n")
	if !ran do return
	bounded := false
	for frame in run[0] do bounded ||= frame[1].bounds == 1
	testing.expect(t, bounded, "d/f+1,2 did not bound")
}

// A combo takes one bound: after the electric launches and d/f+1,2 bounds, more d/f+1,2 at any timing do not bound again.
@(test)
tk6_one_bound_per_combo :: proc(t: ^testing.T) {
	script := strings.builder_make(context.temp_allocator)
	strings.write_string(&script, ELECTRIC_SCRIPT + "step 14 0 8\nstep 20 8 0\nstep 4 0 0\nstep 1 1a 0\nstep 8 0 0\nstep 1 20 0\nsave\n")
	for wait := 0; wait <= 32; wait += 4 {
		fmt.sbprintf(&script, "load\nmark\nstep %d 0 0\nstep 4 8 0\nstep 1 1a 0\nstep 8 0 0\nstep 1 20 0\nstep 60 0 0\n", wait)
	}
	run, ran := run_scenario(t, strings.to_string(script))
	if !ran do return
	bounded := false
	for frame in run[0] do bounded ||= frame[1].bounds == 1
	if !testing.expect(t, bounded, "the electric, then d/f+1,2, did not bound") do return
	for block in run[1:] do for frame in block do if !testing.expectf(t, frame[1].bounds <= 1, "bounds %d in one combo", frame[1].bounds) do return
}

// The fight starts on the stage's start line: centred on the posf centre, turned by its turn, 2000 apart (stage 12:
// 5000, side 1 on the right), each fighter facing the other.
@(test)
tk6_fighters_start_on_the_stage_line :: proc(t: ^testing.T) {
	Start_Line :: struct {
		stage:       string,
		centre, gap: [2]f32,  // x, z; gap: side 2's place minus side 1's
	}
	TURN_03 :: -80.0 * math.PI / 180
	lines := []Start_Line{
		{"stage_00", {0, 0}, {2000, 0}},
		{"stage_03", {0, 0}, {2000 * math.cos(f32(TURN_03)), -2000 * math.sin(f32(TURN_03))}},
		{"stage_09", {-2000, 0}, {2000 * math.cos(f32(4.764749)), -2000 * math.sin(f32(4.764749))}},
		{"stage_12", {0, 0}, {-5000, 0}},
	}
	pack, imported := tk6_pack(t)
	if !imported do return
	if !testing.expect(t, build_scenario_tool(), "tests/ref/tk6_scenario.c did not build") do return
	for line in lines {
		stdout, ran := run_tool(t, pack, line.stage, "fight\nplace\n")
		if !ran do continue
		fields: []string
		for text in strings.split_lines(string(stdout), context.temp_allocator) do if strings.has_prefix(text, "place ") do fields = strings.fields(text, context.temp_allocator)
		if !testing.expectf(t, len(fields) == 7, "%s: no place line", line.stage) do continue
		value :: proc(text: string) -> f32 {number, _ := strconv.parse_f32(text); return number}
		place := [2][2]f32{{value(fields[1]), value(fields[2])}, {value(fields[4]), value(fields[5])}}
		facing := [2]f32{value(fields[3]), value(fields[6])}
		centre, gap := (place[0] + place[1]) / 2, place[1] - place[0]
		testing.expectf(t, math.abs(centre.x - line.centre.x) < 20 && math.abs(centre.y - line.centre.y) < 20, "%s: centred on %v", line.stage, centre)
		testing.expectf(t, math.abs(gap.x - line.gap.x) < 20 && math.abs(gap.y - line.gap.y) < 20, "%s: gap %v, want %v", line.stage, gap, line.gap)
		for side in 0 ..< 2 {
			toward := (side == 0 ? gap : -gap) / math.sqrt(gap.x * gap.x + gap.y * gap.y)
			angle := facing[side] * 2 * math.PI / 65536
			testing.expectf(t, toward.x * math.sin(angle) + toward.y * math.cos(angle) > 0.99, "%s: side %d does not face the other", line.stage, side + 1)
		}
	}
}
