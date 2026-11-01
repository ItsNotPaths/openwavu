package ui

import sdl "vendor:sdl3"

// Folds one SDL event into the frame's input.
handle_event :: proc(ui: ^Ui, e: sdl.Event) {
	input := &ui.input
	#partial switch e.type {
	case .MOUSE_MOTION:
		input.mouse = {e.motion.x, e.motion.y}
		input.pad = false
	case .MOUSE_BUTTON_DOWN:
		if e.button.button == sdl.BUTTON_LEFT {
			input.mouse_down = true
			input.mouse_pressed = true
			input.pad = false
		}
	case .MOUSE_BUTTON_UP:
		if e.button.button == sdl.BUTTON_LEFT {
			input.mouse_down = false
		}
	case .MOUSE_WHEEL:
		input.wheel += {e.wheel.x, e.wheel.y}
	case .KEY_DOWN:
		press(input, key_action(e.key.key))
	case .GAMEPAD_BUTTON_DOWN:
		press(input, pad_action(sdl.GamepadButton(e.gbutton.button)))
	}
}

@(private)
Action :: enum u8 {
	None,
	Up,
	Down,
	Left,
	Right,
	Accept,
	Back,
}

@(private)
press :: proc(input: ^Input, action: Action) {
	switch action {
	case .None:
		return
	case .Up:
		input.nav = .Up
	case .Down:
		input.nav = .Down
	case .Left:
		input.nav = .Left
	case .Right:
		input.nav = .Right
	case .Accept:
		input.accept = true
	case .Back:
		input.back = true
	}
	input.pad = true
}

@(private)
key_action :: proc(key: sdl.Keycode) -> Action {
	switch key {
	case sdl.K_UP:
		return .Up
	case sdl.K_DOWN:
		return .Down
	case sdl.K_LEFT:
		return .Left
	case sdl.K_RIGHT:
		return .Right
	case sdl.K_RETURN, sdl.K_SPACE:
		return .Accept
	case sdl.K_ESCAPE, sdl.K_BACKSPACE:
		return .Back
	}
	return .None
}

@(private)
pad_action :: proc(button: sdl.GamepadButton) -> Action {
	#partial switch button {
	case .DPAD_UP:
		return .Up
	case .DPAD_DOWN:
		return .Down
	case .DPAD_LEFT:
		return .Left
	case .DPAD_RIGHT:
		return .Right
	case .SOUTH:
		return .Accept
	case .EAST:
		return .Back
	}
	return .None
}
