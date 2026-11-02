// A cancel's TK5 command as the command syntax (docs/commands.md).
package tk5_convert

import "core:fmt"
import "../../command"
import formats "../../formats/tk5"

TK5_NAMES := command.Names{{"1", "2", "3", "4", nil}, {"unlock", nil}}

// The codes after CMD_END: dashes and taps, as the sequences they match.
SPECIAL_INPUTS := [4]string{"{^f:n:^f}20", "{^b:n:^b}20", "{n:u:n}16", "{n:d:n}16"}

EXTRA_UNLOCK :: 1 << 18  // the input counts while the fighter's input is locked: the word `unlock`
COMMAND_ANY_PRESS :: 1 << 12
COMMAND_HOLD_AFTER_PRESS :: 1 << 13
COMMAND_SUMMARY :: 1 << 14
DIRECTION_NEW :: 1 << 10

// kind: "" for a cancel, else end, group or return.
cancel_input :: proc(m: formats.Motbin, c: formats.Cancel) -> (kind, text: string) {
	input: command.Input
	code := c.command >> 16
	switch {
	case code == CMD_END: kind = "end"
	case code == CMD_GROUP: kind = "group"
	case code == CMD_GROUP_END: kind = "return"
	case code > CMD_END && code < CMD_GROUP:
		input, _ = command.parse(fmt.tprintf("%s@0..0>0", SPECIAL_INPUTS[code - CMD_END - 1]), TK5_NAMES)
	case code >= CMD_SEQUENCE:
		s := m.input_sequences[code - CMD_SEQUENCE]
		input.window, input.step_count = s.unk_00, u8(s.unk_02)
		for x, i in m.input_extras[s.inputs:][:s.unk_02] do input.steps[i] = step(x.unk_00, x.unk_02, true)
	case code != 0 || c.command & 0xffff != 0:
		input.steps[0], input.step_count = step(u16(code), u16(c.command), false), 1
	}
	input.open, input.close, input.start = c.window_start, c.window_end, c.start_frame
	if m.cancel_extras[c.extra] & EXTRA_UNLOCK != 0 do input.words = 1
	return kind, command.print(input, TK5_NAMES)
}

// Inside a sequence "no press" is a step without buttons. A one-button press is written one way: the game's three modes
// match it alike.
@(private = "file")
step :: proc(code, buttons: u16, in_sequence: bool) -> (s: command.Step) {
	s.directions = code >> 1 & command.ALL
	s.tap = code & DIRECTION_NEW != 0
	if buttons & COMMAND_SUMMARY != 0 {
		summaries := [4]command.Summary{.No_Press, .Nothing_Held, .Some_Press, .Some_Held}
		s.summary = summaries[buttons & 3]
		if in_sequence && s.summary == .No_Press do s.summary = .None
		return
	}
	s.press, s.held, s.not_held = u8(buttons & 15), u8(buttons >> 4 & 15), u8(buttons >> 8 & 15)
	switch {
	case s.press & (s.press - 1) == 0: s.press_mode = .Together
	case buttons & COMMAND_ANY_PRESS != 0: s.press_mode = .Any
	case buttons & COMMAND_HOLD_AFTER_PRESS != 0: s.press_mode = .Together
	case: s.press_mode = .Same_Frame
	}
	return
}
