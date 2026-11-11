// A cancel's TK6 command as the command syntax (docs/commands.md): the high u32 the code, the low u32 the buttons.
package tk6_convert

import "core:fmt"
import "../../command"
import formats "../../formats/tk6"
import tk5_convert "../tk5"

// Buttons 1..4 are the face buttons; 5 and 6 are TK6 button bits 4 and 5 (the sim's L1 and R1).
TK6_NAMES := command.Names{{"1", "2", "3", "4", "5", "6", nil}, {"unlock", nil}}

BUTTONS_NAMED :: 0x3f
// Low u32: press bits 0..7, held 8..15, not held 16..23, any press 29, hold after press 30, summary 31.
BUTTON_ANY_PRESS :: 1 << 29
BUTTON_HOLD_AFTER_PRESS :: 1 << 30
BUTTON_SUMMARY :: 1 << 31
BUTTONS_KNOWN :: BUTTONS_NAMED | BUTTONS_NAMED << 8 | BUTTONS_NAMED << 16 | BUTTON_ANY_PRESS | BUTTON_HOLD_AFTER_PRESS | BUTTON_SUMMARY
DIRECTION_BITS :: 0x7ff  // no change, nine directions, new press

// kind: "" for a cancel, else end, group or return. readable false: the command has bits the text can not hold.
cancel_input :: proc(motbin: formats.Motbin, cancel: formats.Cancel) -> (kind, text: string, readable: bool) {
	input: command.Input
	code, buttons := u32(cancel.command >> 32), u32(cancel.command)
	readable = true
	switch {
	case code == COMMAND_END: kind = "end"
	case code == COMMAND_GROUP: kind = "group"
	case code == COMMAND_GROUP_END: kind = "return"
	case code > COMMAND_END && code <= COMMAND_SPECIAL_LAST:
		input, _ = command.parse(fmt.tprintf("%s@0..0>0", tk5_convert.SPECIAL_INPUTS[code - COMMAND_END - 1]), TK6_NAMES)
	case code >= COMMAND_STICK_FIRST && code <= COMMAND_STICK_LAST:
		// (hole tk6-stick-buttons :tags (tk6 input) :sev polish) analog stick tests read as digital and buttons 5, 6 go to L1/R1 are guesses.
		if buttons != 0 {  // the stick column holds the test
			input.steps[0], readable = step(0, buttons, false)
			input.step_count = 1
		}
	case code >= COMMAND_SEQUENCE:
		sequence := motbin.input_sequences[code - COMMAND_SEQUENCE]
		input.window, input.step_count = sequence.unk_00, u8(sequence.unk_02)
		for extra, index in motbin.input_extras[sequence.inputs:][:sequence.unk_02] {
			step_readable: bool
			input.steps[index], step_readable = step(extra.unknown_00, extra.unknown_04, true)
			readable &&= step_readable
		}
	case code != 0 || buttons != 0:
		input.steps[0], readable = step(code, buttons, false)
		input.step_count = 1
	}
	input.open, input.close, input.start = u16(cancel.window_start), u16(cancel.window_end), u16(cancel.starting_frame)
	if motbin.cancel_extras[cancel.extra] & tk5_convert.EXTRA_UNLOCK != 0 do input.words = 1
	return kind, command.print(input, TK6_NAMES), readable
}

// Inside a sequence "no press" is a step without buttons. A one-button press is written one way: the game's three modes
// match it alike.
@(private = "file")
step :: proc(code, buttons: u32, in_sequence: bool) -> (result: command.Step, readable: bool) {
	result.directions = u16(code >> 1) & command.ALL
	result.tap = code & tk5_convert.DIRECTION_NEW != 0
	readable = code &~ DIRECTION_BITS == 0 && buttons &~ BUTTONS_KNOWN == 0
	if buttons & BUTTON_SUMMARY != 0 {
		summaries := [4]command.Summary{.No_Press, .Nothing_Held, .Some_Press, .Some_Held}
		result.summary = summaries[buttons & 3]
		if in_sequence && result.summary == .No_Press do result.summary = .None
		return
	}
	result.press, result.held, result.not_held = u8(buttons & BUTTONS_NAMED), u8(buttons >> 8 & BUTTONS_NAMED), u8(buttons >> 16 & BUTTONS_NAMED)
	switch {
	case result.press & (result.press - 1) == 0: result.press_mode = .Together
	case buttons & BUTTON_ANY_PRESS != 0: result.press_mode = .Any
	case buttons & BUTTON_HOLD_AFTER_PRESS != 0: result.press_mode = .Together
	case: result.press_mode = .Same_Frame
	}
	return
}
