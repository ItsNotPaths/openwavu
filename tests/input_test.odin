package tests

import "core:testing"
import sdl "vendor:sdl3"
import "../src/input"

// settings.conf keeps bindings as text; every kind must load back as it was saved.
@(test)
bindings_load_as_saved :: proc(t: ^testing.T) {
	bindings := []input.Binding{nil, sdl.Scancode.LSHIFT, sdl.GamepadButton.DPAD_UP, input.Pad_Axis{.LEFTX, false}, input.Pad_Axis{.RIGHT_TRIGGER, true}}
	for binding in bindings {
		loaded, parsed := input.binding_parse(input.binding_text(binding))
		testing.expect(t, parsed)
		testing.expect_value(t, loaded, binding)
	}
}
