// TK6 Start/Win camera clips as camera tracks (eye, target, lens), the layout TK5's tracks use. tk6decomp docs/data.md
// "Hands, face and move cameras".
package tk6_convert

import "core:math"
import "core:math/linalg"
import "../../convert"
import formats "../../formats/tk6"
import tk5_convert "../tk5"

@(private = "file")
LOOK_DISTANCE :: 5000  // mm: the game sets the target this far down the view
@(private = "file")
CAMERA_VALUES :: 9

write_camera_anim :: proc(path: string, keys: [][formats.CAMERA_CHANNELS][3]f32) -> bool {
	if len(keys) == 0 do return false
	values := make([]f32, len(keys) * CAMERA_VALUES, context.temp_allocator)
	for key, frame in keys {
		eye, field_of_view := key[0], key[2][0]
		forward, up := view_axes(key[1])
		target := eye + LOOK_DISTANCE * forward
		out := values[frame * CAMERA_VALUES:][:CAMERA_VALUES]
		copy(out[0:3], eye[:])
		copy(out[3:6], target[:])
		out[6], out[7], out[8] = field_of_view, roll(forward, up), 1
	}
	return convert.write_anim(path, {
		layout        = "camera",
		frames        = len(keys),
		fps           = tk5_convert.FPS,
		position_unit = 0.001,
		channels      = tk5_convert.CAMERA_CHANNELS[:],
		values        = values,
	})
}

// The game's turn Rx Ry Rz of the euler angles (sampler FUN_000231e0); the camera looks down minus its row 2 with row 1
// up (FUN_0026b620).
@(private = "file")
view_axes :: proc(euler: [3]f32) -> (forward, up: [3]f32) {
	turn_x :: proc(angle: f32) -> matrix[3, 3]f32 {
		c, s := math.cos(angle), math.sin(angle)
		return {1, 0, 0, 0, c, s, 0, -s, c}
	}
	turn_y :: proc(angle: f32) -> matrix[3, 3]f32 {
		c, s := math.cos(angle), math.sin(angle)
		return {c, 0, -s, 0, 1, 0, s, 0, c}
	}
	turn_z :: proc(angle: f32) -> matrix[3, 3]f32 {
		c, s := math.cos(angle), math.sin(angle)
		return {c, s, 0, -s, c, 0, 0, 0, 1}
	}
	turn := turn_x(euler.x) * turn_y(euler.y) * turn_z(euler.z)
	forward = -[3]f32{turn[2, 0], turn[2, 1], turn[2, 2]}
	up = {turn[1, 0], turn[1, 1], turn[1, 2]}
	return
}

// The host turns world up about the view by the roll: the angle from world up to `up`, both seen square to the view.
@(private = "file")
roll :: proc(forward, up: [3]f32) -> f32 {
	plain_up := [3]f32{0, 1, 0} - forward.y * forward
	return math.atan2(linalg.dot(forward, linalg.cross(plain_up, up)), linalg.dot(plain_up, up))
}
