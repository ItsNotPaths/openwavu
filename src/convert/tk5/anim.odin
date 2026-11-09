// TK5 anims as .anim: 23 channels, positions in mm. The sim adds channels 0 and 1 for the root
// position and takes only the yaw of channel 2 (tk5decomp skel.py). Channel to bone: FUN_001cc6fc.
package tk5_convert

import "core:slice"
import "../../convert"
import formats "../../formats/tk5"

FPS :: 60

CHANNELS := [formats.CHANNELS]convert.Anim_Channel{
	{.Position, 3, 0}, {.Position, 3, 0}, {.Spherical_Axis_Angle, 3, 0},
	{.Spherical_Axis_Angle, 3, 1}, {.Spherical_Axis_Angle, 3, 2}, {.Spherical_Axis_Angle, 3, 4},
	{.Position, 3, -1},
	{.Spherical_Axis_Angle, 3, 5}, {.Spherical_Axis_Angle, 3, 6},
	{.Spherical_Axis_Angle, 3, 7}, {.Spherical_Axis_Angle, 3, 8}, {.Spherical_Axis_Angle, 3, 9},
	{.Spherical_Axis_Angle, 3, 10}, {.Spherical_Axis_Angle, 3, 11}, {.Spherical_Axis_Angle, 3, 12},
	{.Spherical_Axis_Angle, 3, 13}, {.Spherical_Axis_Angle, 3, 14}, {.Spherical_Axis_Angle, 3, 15},
	{.Spherical_Axis_Angle, 3, 16}, {.Spherical_Axis_Angle, 3, 17}, {.Spherical_Axis_Angle, 3, 18},
	{.Spherical_Axis_Angle, 3, 19}, {.Spherical_Axis_Angle, 3, 20},
}

write_anim :: proc(path: string, a: formats.Anim) -> (ok: bool) {
	return convert.write_anim(path, {
		layout        = "tk5",
		frames        = a.frames,
		fps           = FPS,
		position_unit = 0.001,
		channels      = CHANNELS[:],
		values        = slice.reinterpret([]f32, a.values),
	})
}

// Finger anims: one hand's 15 joints, root joint first; either hand plays them, so no bone.
HAND_CHANNELS := [formats.HAND_JOINTS]convert.Anim_Channel{0 ..< formats.HAND_JOINTS = {.Spherical_Axis_Angle, 3, -1}}

write_hand_anim :: proc(path: string, frames: []formats.Hand_Frame) -> (ok: bool) {
	raw := slice.reinterpret([]i16, frames)
	values := make([]f32, len(raw), context.temp_allocator)
	for v, i in raw do values[i] = f32(v) * formats.ANGLE
	return convert.write_anim(path, {
		layout   = "tk5hand",
		frames   = len(frames),
		fps      = FPS,
		channels = HAND_CHANNELS[:],
		values   = values,
	})
}

// Face anims: per channel by the bank's type, turns in radians, moves and scales as decoded; the visual maps them to bones.
write_face_anim :: proc(path: string, bank: formats.Clip_Bank, raw: []i16) -> (ok: bool) {
	channels := make([]convert.Anim_Channel, bank.channels, context.temp_allocator)
	for &channel, i in channels {
		kind := convert.Anim_Channel_Kind.Position
		if formats.is_rotation(bank, i) do kind = .Spherical_Axis_Angle
		if formats.channel_type(bank, i) == formats.SCALE_TYPE do kind = .Values
		channel = {kind, 3, -1}
	}
	values := make([]f32, len(raw), context.temp_allocator)
	for v, i in raw do values[i] = channels[i / 3 % bank.channels].kind == .Spherical_Axis_Angle ? f32(v) * formats.ANGLE : f32(v)
	return convert.write_anim(path, {
		layout   = "tk5face",
		frames   = len(raw) / (3 * bank.channels),
		fps      = FPS,
		channels = channels,
		values   = values,
	})
}
