// Keyboards and gamepads to openwavu pad words (OW_PAD_* in openwavu.h), the same in every title. Player 0 is the
// keyboard and the first gamepad together; player 1 is the second gamepad. One set of bindings serves both.
package input

import "core:strings"
import sdl "vendor:sdl3"

// (hole stick-settings :tags (input game) :sev polish) the stick's x and y inner deadzones are fixed, and there is no outer
// deadzone; the openwavu settings popup should set them.
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
BACK :: 1 << 9  // menus only

// What a player can bind: each direction, each button, and every combination of the buttons.
Slot :: enum u8 {
	Up,
	Down,
	Left,
	Right,
	Button_1,
	Button_2,
	Button_3,
	Button_4,
	Buttons_1_2,
	Buttons_1_3,
	Buttons_1_4,
	Buttons_2_3,
	Buttons_2_4,
	Buttons_3_4,
	Buttons_1_2_3,
	Buttons_1_2_4,
	Buttons_1_3_4,
	Buttons_2_3_4,
	Buttons_1_2_3_4,
}

SLOT_PRESSES := [Slot]u32 {
	.Up              = UP,
	.Down            = DOWN,
	.Left            = LEFT,
	.Right           = RIGHT,
	.Button_1        = BUTTON_1,
	.Button_2        = BUTTON_2,
	.Button_3        = BUTTON_3,
	.Button_4        = BUTTON_4,
	.Buttons_1_2     = BUTTON_1 | BUTTON_2,
	.Buttons_1_3     = BUTTON_1 | BUTTON_3,
	.Buttons_1_4     = BUTTON_1 | BUTTON_4,
	.Buttons_2_3     = BUTTON_2 | BUTTON_3,
	.Buttons_2_4     = BUTTON_2 | BUTTON_4,
	.Buttons_3_4     = BUTTON_3 | BUTTON_4,
	.Buttons_1_2_3   = BUTTON_1 | BUTTON_2 | BUTTON_3,
	.Buttons_1_2_4   = BUTTON_1 | BUTTON_2 | BUTTON_4,
	.Buttons_1_3_4   = BUTTON_1 | BUTTON_3 | BUTTON_4,
	.Buttons_2_3_4   = BUTTON_2 | BUTTON_3 | BUTTON_4,
	.Buttons_1_2_3_4 = BUTTON_1 | BUTTON_2 | BUTTON_3 | BUTTON_4,
}

// Shown above each slot and used as its settings key.
SLOT_NAMES := [Slot]string {
	.Up              = "Up",
	.Down            = "Down",
	.Left            = "Left",
	.Right           = "Right",
	.Button_1        = "1",
	.Button_2        = "2",
	.Button_3        = "3",
	.Button_4        = "4",
	.Buttons_1_2     = "1+2",
	.Buttons_1_3     = "1+3",
	.Buttons_1_4     = "1+4",
	.Buttons_2_3     = "2+3",
	.Buttons_2_4     = "2+4",
	.Buttons_3_4     = "3+4",
	.Buttons_1_2_3   = "1+2+3",
	.Buttons_1_2_4   = "1+2+4",
	.Buttons_1_3_4   = "1+3+4",
	.Buttons_2_3_4   = "2+3+4",
	.Buttons_1_2_3_4 = "1+2+3+4",
}

// One key, one gamepad button or one way of one gamepad axis; nil is unbound.
Binding :: union {
	sdl.Scancode,
	sdl.GamepadButton,
	Pad_Axis,
}

// A stick or trigger leaned one way: positive is right, down, or a trigger pulled.
Pad_Axis :: struct {
	axis:     sdl.GamepadAxis,
	positive: bool,
}

Bindings :: [Slot]Binding

DEFAULT_BINDINGS := #partial Bindings {
	.Up       = sdl.Scancode.UP,
	.Down     = sdl.Scancode.DOWN,
	.Left     = sdl.Scancode.LEFT,
	.Right    = sdl.Scancode.RIGHT,
	.Button_1 = sdl.Scancode.U,
	.Button_2 = sdl.Scancode.I,
	.Button_3 = sdl.Scancode.J,
	.Button_4 = sdl.Scancode.K,
}

// Binds slot, taking the binding off any other slot that had it.
bind :: proc(bindings: ^Bindings, slot: Slot, binding: Binding) {
	if binding != nil do for &other in bindings do if other == binding do other = nil
	bindings[slot] = binding
}

// What a slot's button shows.
binding_name :: proc(binding: Binding) -> string {
	device, name := binding_parts(binding)
	switch device {
	case "key": return name
	case "none": return "-"
	}
	return strings.concatenate({"Pad ", name}, context.temp_allocator)
}

// A binding as settings text: "key <name>", "pad <name>", "axis <name><+ or ->" or "none".
binding_text :: proc(binding: Binding) -> string {
	device, name := binding_parts(binding)
	return device == "none" ? device : strings.concatenate({device, " ", name}, context.temp_allocator)
}

binding_parse :: proc(text: string) -> (binding: Binding, parsed: bool) {
	if text == "none" do return nil, true
	device, _, name := strings.partition(text, " ")
	switch device {
	case "key":
		scancode := sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator))
		return scancode, scancode != .UNKNOWN
	case "pad":
		button := sdl.GetGamepadButtonFromString(strings.clone_to_cstring(name, context.temp_allocator))
		return button, button != .INVALID
	case "axis":
		if len(name) < 2 do return nil, false
		way := name[len(name) - 1]
		axis := sdl.GetGamepadAxisFromString(strings.clone_to_cstring(name[:len(name) - 1], context.temp_allocator))
		return Pad_Axis{axis, way == '+'}, axis != .INVALID && (way == '+' || way == '-')
	}
	return nil, false
}

@(private = "file")
binding_parts :: proc(binding: Binding) -> (device, name: string) {
	switch bound in binding {
	case sdl.Scancode: return "key", string(sdl.GetScancodeName(bound))
	case sdl.GamepadButton: return "pad", string(sdl.GetGamepadStringForButton(bound))
	case Pad_Axis: return "axis", strings.concatenate({string(sdl.GetGamepadStringForAxis(bound.axis)), bound.positive ? "+" : "-"}, context.temp_allocator)
	}
	return "none", ""
}

// How far an axis must lean, 0..1, before its binding presses: y for the sticks' up and down, x for the rest.
Deadzone :: struct {
	x, y: f32,
}

STICK_DEADZONE :: Deadzone{0.35, 0.35}

// An axis binding as an axis moves to lean (-1..1).
axis_leaned :: proc(binding: Pad_Axis, lean: f32, deadzone: Deadzone) -> bool {
	limit := binding.axis == .LEFTY || binding.axis == .RIGHTY ? deadzone.y : deadzone.x
	return binding.positive ? lean > limit : lean < -limit
}

// Menu keys and buttons, not bindable.
@(private = "file")
MENU_KEYS := [?]struct {
	key: sdl.Scancode,
	bit: u32,
}{{.RETURN, START}, {.BACKSPACE, BACK}}

@(private = "file")
MENU_BUTTONS := [?]struct {
	button: sdl.GamepadButton,
	bit:    u32,
}{{.START, START}, {.BACK, BACK}}

// Opens a gamepad as it is plugged in; call it for every event.
handle_event :: proc(e: sdl.Event) {
	if e.type == .GAMEPAD_ADDED do _ = sdl.OpenGamepad(e.gdevice.which)
}

// What each player holds now, with opposite directions cancelled per axis. Keys press for player 0, a gamepad
// for its own player.
poll :: proc(bindings: Bindings) -> (pads: [PLAYERS]u32) {
	key_count: i32
	keys := sdl.GetKeyboardState(&key_count)
	held :: proc(keys: [^]bool, key_count: i32, key: sdl.Scancode) -> bool {return i32(key) < key_count && keys[key]}
	for k in MENU_KEYS do if held(keys, key_count, k.key) do pads[0] |= k.bit
	gamepads: [PLAYERS]^sdl.Gamepad
	ids_count: i32
	ids := sdl.GetGamepads(&ids_count)
	defer sdl.free(ids)
	for i in 0 ..< min(int(ids_count), PLAYERS) do gamepads[i] = sdl.GetGamepadFromID(ids[i])
	for binding, slot in bindings {
		switch bound in binding {
		case sdl.Scancode:
			if held(keys, key_count, bound) do pads[0] |= SLOT_PRESSES[slot]
		case sdl.GamepadButton:
			for gamepad, player in gamepads do if gamepad != nil && sdl.GetGamepadButton(gamepad, bound) do pads[player] |= SLOT_PRESSES[slot]
		case Pad_Axis:
			for gamepad, player in gamepads {
				if gamepad != nil && axis_leaned(bound, f32(sdl.GetGamepadAxis(gamepad, bound.axis)) / 32767, STICK_DEADZONE) do pads[player] |= SLOT_PRESSES[slot]
			}
		}
	}
	for gamepad, player in gamepads {
		if gamepad == nil do continue
		for b in MENU_BUTTONS do if sdl.GetGamepadButton(gamepad, b.button) do pads[player] |= b.bit
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
