package tests

import "core:testing"
import "../src/input"

// A stick press needs the lean past that axis's deadzone; each axis has its own, and both past it is a diagonal.
@(test)
stick_presses_past_each_axis_deadzone :: proc(t: ^testing.T) {
	deadzone := input.Deadzone{0.3, 0.6}
	testing.expect_value(t, input.stick_directions({0.2, -0.5}, deadzone), 0)
	testing.expect_value(t, input.stick_directions({0.4, 0}, deadzone), input.RIGHT)
	testing.expect_value(t, input.stick_directions({-0.4, -0.5}, deadzone), input.LEFT)
	testing.expect_value(t, input.stick_directions({0, 0.7}, deadzone), input.DOWN)
	testing.expect_value(t, input.stick_directions({-0.9, -0.9}, deadzone), input.LEFT | input.UP)
}
