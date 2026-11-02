// Binding of sdk/include/ow_input.h: the command syntax (docs/commands.md).
package command

foreign import lib "../../build/libow_input.a"

STEPS :: 16

// Directions relative to the facing side, as bits of Step.directions.
DB :: 1 << 0
D :: 1 << 1
DF :: 1 << 2
B :: 1 << 3
N :: 1 << 4
F :: 1 << 5
UB :: 1 << 6
U :: 1 << 7
UF :: 1 << 8
ALL :: 1 << 9 - 1

Press_Mode :: enum u8 {
	Together, // 1+2: all held, one pressed this frame; a one-button press is always this
	Same_Frame, // {1+2}1
	Any, // 1/2
}

Summary :: enum u8 {
	None,
	Some_Press,
	No_Press,
	Some_Held,
	Nothing_Held,
}

Step :: struct {
	directions:               u16, // any of these held; 0: any
	tap:                      bool, // ^: pushed this frame
	strict:                   bool, // joined to the step before by ':'
	press, held, not_held:    u8, // button sets: bit i is the game's button i
	press_mode:               Press_Mode,
	summary:                  Summary,
}

Input :: struct {
	steps:              [STEPS]Step,
	step_count:         u8, // 0: no input
	window:             u16, // {…}N; one step with window 0 is tested on this frame only
	open, close, start: u16, // @open..close >start
}

@(default_calling_convention = "c", link_prefix = "ow_input_")
foreign lib {
	@(private = "file", link_name = "ow_input_parse")
	c_parse :: proc(text: [^]u8, length: u32, buttons: [^]cstring, out: ^Input) -> cstring ---
	@(private = "file", link_name = "ow_input_text")
	c_text :: proc(input: ^Input, buttons: [^]cstring, out: [^]u8, room: u32) -> u32 ---
	@(private = "file", link_name = "ow_input_notation")
	c_notation :: proc(input: ^Input, buttons: [^]cstring, out: [^]u8, room: u32) -> u32 ---
}

// buttons: the game's button names by bit, nil-terminated. failed is "" when the text parses.
parse :: proc(text: string, buttons: []cstring) -> (input: Input, failed: string) {
	failed = string(c_parse(raw_data(text), u32(len(text)), raw_data(buttons), &input))
	return
}

// The exact text of an input, in the temp allocator.
print :: proc(input: Input, buttons: []cstring) -> string {
	return call_printer(c_text, input, buttons)
}

// The plain notation players use (f,f+1+2), in the temp allocator. For reading only.
notation :: proc(input: Input, buttons: []cstring) -> string {
	return call_printer(c_notation, input, buttons)
}

@(private = "file")
call_printer :: proc(printer: proc "c" (input: ^Input, buttons: [^]cstring, out: [^]u8, room: u32) -> u32, input: Input, buttons: []cstring) -> string {
	input := input
	out := make([]u8, 1024, context.temp_allocator)
	return string(out[:printer(&input, raw_data(buttons), raw_data(out), u32(len(out)))])
}
