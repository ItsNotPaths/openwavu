// Keyboards and gamepads to openwavu pad words (OW_PAD_* in openwavu.h), the same in every title. Player 0 is the
// keyboard and the first gamepad together; player 1 is the second gamepad.
package input

import sdl "vendor:sdl3"

// (hole button-config :tags input :sev polish) the keys and buttons below are fixed: arrows, U I J K for buttons 1 to 4, Enter; on a gamepad the d-pad, the four face buttons and Start.
// (hole stick-config :tags input :sev polish) no analog stick to directions, deadzone or stick settings; one modern scheme for every title.
PLAYERS :: 2

UP :: 1 << 0
DOWN :: 1 << 1
LEFT :: 1 << 2
RIGHT :: 1 << 3
BUTTON_1 :: 1 << 4
BUTTON_2 :: 1 << 5
BUTTON_3 :: 1 << 6
BUTTON_4 :: 1 << 7
START :: 1 << 8

@(private = "file")
KEYS := [?]struct {
	key: sdl.Scancode,
	bit: u32,
}{{.UP, UP}, {.DOWN, DOWN}, {.LEFT, LEFT}, {.RIGHT, RIGHT}, {.U, BUTTON_1}, {.I, BUTTON_2}, {.J, BUTTON_3}, {.K, BUTTON_4}, {.RETURN, START}}

@(private = "file")
BUTTONS := [?]struct {
	button: sdl.GamepadButton,
	bit:    u32,
}{
	{.DPAD_UP, UP}, {.DPAD_DOWN, DOWN}, {.DPAD_LEFT, LEFT}, {.DPAD_RIGHT, RIGHT},
	{.WEST, BUTTON_1}, {.NORTH, BUTTON_2}, {.SOUTH, BUTTON_3}, {.EAST, BUTTON_4}, {.START, START},
}

// Opens a gamepad as it is plugged in; call it for every event.
handle_event :: proc(e: sdl.Event) {
	if e.type == .GAMEPAD_ADDED do _ = sdl.OpenGamepad(e.gdevice.which)
}

// What each player holds now, with opposite directions cancelled per axis.
poll :: proc() -> (pads: [PLAYERS]u32) {
	key_count: i32
	keys := sdl.GetKeyboardState(&key_count)
	for k in KEYS do if i32(k.key) < key_count && keys[k.key] do pads[0] |= k.bit
	ids_count: i32
	ids := sdl.GetGamepads(&ids_count)
	defer sdl.free(ids)
	for i in 0 ..< min(int(ids_count), PLAYERS) {
		gamepad := sdl.GetGamepadFromID(ids[i])
		if gamepad == nil do continue
		for b in BUTTONS do if sdl.GetGamepadButton(gamepad, b.button) do pads[i] |= b.bit
	}
	for &pad in pads do pad = cancel_opposites(pad)
	return
}

@(private = "file")
cancel_opposites :: proc(pad: u32) -> u32 {
	pad := pad
	if pad & (UP | DOWN) == UP | DOWN do pad &~= UP | DOWN
	if pad & (LEFT | RIGHT) == LEFT | RIGHT do pad &~= LEFT | RIGHT
	return pad
}
