package tests

import "core:testing"
import "../src/command"

TK5_BUTTONS := []cstring{"1", "2", "3", "4", nil}

// The stock examples of docs/commands.md print back as they were written.
@(test)
stock_commands_print_as_written :: proc(t: ^testing.T) {
	texts := []string {
		"{f:n:^f}20@1..255>1",
		"{n:u:n}16@5..15>15",
		"n+1+2@1..255>1",
		"^b@1..255>1",
		"!*d@10..24>10",
		"1/2@34..43>43",
		"@50..255>50",
		"2~@1..13>1",
		"{1+2}1@21..21>21",
		"{n,f,n,f+1+2}20@1..255>1",
		"{n+{1+2}1,n,n+2,n,n+2,n,n+2,n,n+2,n,n+2,n,n+2}59@1..60>95",
		"{n+1+2+3+4}1@1..255>1",
		"^*@1..255>1",
		"*b/n+!3@1..255>1",
		"!*~@1..255>1",
	}
	for text in texts {
		input, failed := command.parse(text, TK5_BUTTONS)
		if !testing.expect_value(t, failed, "") do continue
		testing.expect_value(t, command.print(input, TK5_BUTTONS), text)
	}
}

// What the text means, for the cases a reader could take two ways.
@(test)
commands_mean_what_the_spec_says :: proc(t: ^testing.T) {
	step :: proc(t: ^testing.T, text: string) -> command.Step {
		input, failed := command.parse(text, TK5_BUTTONS)
		testing.expect_value(t, failed, "")
		return input.steps[0]
	}
	testing.expect_value(t, step(t, "^f@1..1>1"), command.Step{directions = command.F, tap = true})
	testing.expect_value(t, step(t, "*@1..1>1"), command.Step{summary = .Some_Press})
	testing.expect_value(t, step(t, "*b@1..1>1"), command.Step{directions = command.DB | command.B | command.UB})
	testing.expect_value(t, step(t, "!*d@1..1>1").directions, command.ALL & ~u16(command.DB | command.D | command.DF))
	testing.expect_value(t, step(t, "^!*d@1..1>1").tap, true)
	testing.expect_value(t, step(t, "{1+2}1@1..1>1"), command.Step{press = 0b11, press_mode = .Same_Frame})
	testing.expect_value(t, step(t, "1/2@1..1>1"), command.Step{press = 0b11, press_mode = .Any})
	testing.expect_value(t, step(t, "2~+!1@1..1>1"), command.Step{held = 0b10, not_held = 0b01})

	sequence, _ := command.parse("{ n+1+2+3+4 }1 @ 1 .. 2 > 3", TK5_BUTTONS)
	testing.expect_value(t, sequence.step_count, 1)
	testing.expect_value(t, sequence.window, 1)
	testing.expect_value(t, [3]u16{sequence.open, sequence.close, sequence.start}, [3]u16{1, 2, 3})
	strict, _ := command.parse("{f,n:f}20@1..1>1", TK5_BUTTONS)
	testing.expect_value(t, [3]bool{strict.steps[0].strict, strict.steps[1].strict, strict.steps[2].strict}, [3]bool{false, false, true})
}

@(test)
broken_commands_say_what_is_wrong :: proc(t: ^testing.T) {
	texts := []string {
		"f+5@1..1>1",
		"f+1",
		"f@1..1",
		"f@1..65536>1",
		"1/2+{3+4}1@1..1>1",
		"{f,n,f,n,f,n,f,n,f,n,f,n,f,n,f,n,f}20@1..1>1",
		"{f,n@1..1>1",
		"{f,,f}20@1..1>1",
	}
	for text in texts {
		_, failed := command.parse(text, TK5_BUTTONS)
		testing.expectf(t, failed != "", "%q parsed", text)
	}
}

// The plain notation reads like a move list: no frames, no repeat-separating or edge `n`, `^` kept.
@(test)
plain_notation_reads_like_a_move_list :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"{n,f,n,f+1+2}20@1..255>1", "f,f+1+2"},
		{"{n:u:n}16@5..15>15", "u"},
		{"{f:n:^f}20@1..255>1", "f,^f"},
		{"{n,b,n,f+2}50@1..255>1", "b,n,f+2"},
		{"{1+2}1@21..21>21", "1+2"},
		{"^b@1..255>1", "^b"},
		{"@50..255>50", ""},
	}
	for c in cases {
		input, failed := command.parse(c[0], TK5_BUTTONS)
		if !testing.expect_value(t, failed, "") do continue
		testing.expect_value(t, command.notation(input, TK5_BUTTONS), c[1])
	}
}
