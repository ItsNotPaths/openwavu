// TK5 finger and face clips as glTF clip banks (convert/clips.odin) on the character's bone tree: the game's axis keys,
// move steps and scale percents baked to bone rotations, metres and scales.
package tk5_convert

import "core:math"
import "../../convert"
import "../../gltf"
import formats "../../formats/tk5"

FIRST_FINGER_JOINT :: 55  // 55..69 the right fingers, 70..84 the left, each root joint first
FACE_MOVE_UNIT :: 0.2     // mm per face move step
FACE_SCALE_UNIT :: 0.01   // a face scale of 100 keeps the size

// Left fingers play the right hand's keys mirrored by joint in its finger: roots S_y M S_y, the others S_x M S_x.
@(rodata)
LEFT_MIRROR := [3][4]f32{{-1, 1, -1, 1}, {1, -1, -1, 1}, {1, -1, -1, 1}}

// Face channel -> its glb joint and path.
@(rodata)
FACE_TRACKS := [formats.FACE_CHANNELS]convert.Clip_Track{
	{85, .Rotation}, {85, .Translation}, {100, .Rotation}, {109, .Rotation}, {98, .Rotation}, {107, .Rotation},
	{101, .Translation}, {110, .Translation}, {99, .Translation}, {108, .Translation}, {97, .Translation}, {106, .Translation},
	{95, .Translation}, {104, .Translation}, {94, .Translation}, {103, .Translation}, {93, .Rotation}, {102, .Rotation},
	{93, .Translation}, {102, .Translation}, {92, .Rotation}, {96, .Rotation}, {105, .Rotation}, {92, .Translation},
	{96, .Translation}, {105, .Translation}, {87, .Rotation}, {89, .Rotation}, {87, .Translation}, {89, .Translation},
	{86, .Rotation}, {88, .Rotation}, {86, .Translation}, {88, .Translation}, {90, .Rotation}, {91, .Rotation},
	{90, .Scale}, {91, .Scale},
}

// The sim's turn of an axis key (axis pitch, axis yaw, angle; t5_anim_key_turn) as a glTF rotation. The sim keeps the
// rotation's matrix transposed, so the glTF quaternion is the conjugate.
key_rotation :: proc(key: [3]f32) -> [4]f32 {
	pitch, yaw, angle := key.x, key.y, key.z
	axis := [3]f32{math.sin(yaw) * math.cos(pitch), -math.sin(pitch), math.cos(yaw) * math.cos(pitch)}
	sine := math.sin(angle / 2)
	return {-axis.x * sine, -axis.y * sine, -axis.z * sine, math.sqrt(1 - sine * sine)}
}

// Tracks 0..14 the right fingers, 15..29 the left: either hand can play any clip.
write_hand_clips :: proc(path: string, bones: formats.Skeleton, bank: formats.Clip_Bank) -> (ok: bool) {
	context.allocator = context.temp_allocator
	g: gltf.Gltf
	roots, _ := add_bones(&g, bones, len(bones.bones))
	append(&g.scenes, gltf.Scene{nodes = roots})
	tracks: [2 * formats.HAND_JOINTS]convert.Clip_Track
	for &track, index in tracks do track = {FIRST_FINGER_JOINT + index, .Rotation}
	for clip in 0 ..< bank.count {
		frames := formats.read_hand_clip(bank, clip) or_return
		if len(frames) == 0 do return false
		keys := make([][4]f32, len(frames) * len(tracks))
		for frame, frame_index in frames do for joint in 0 ..< formats.HAND_JOINTS {
			turn := key_rotation({f32(frame[joint][0]), f32(frame[joint][1]), f32(frame[joint][2])} * formats.ANGLE)
			keys[frame_index * len(tracks) + joint] = turn
			keys[frame_index * len(tracks) + formats.HAND_JOINTS + joint] = turn * LEFT_MIRROR[joint % 3]
		}
		convert.add_clip(&g, tracks[:], len(frames), keys)
	}
	return gltf.write_glb(&g, path)
}

write_face_clips :: proc(path: string, bones: formats.Skeleton, bank: formats.Clip_Bank) -> (ok: bool) {
	for track, channel in FACE_TRACKS {
		if (track.path == .Rotation) != formats.is_rotation(bank, channel) do return false
		if (track.path == .Scale) != (formats.channel_type(bank, channel) == formats.SCALE_TYPE) do return false
	}
	context.allocator = context.temp_allocator
	g: gltf.Gltf
	roots, _ := add_bones(&g, bones, len(bones.bones))
	append(&g.scenes, gltf.Scene{nodes = roots})
	for clip in 0 ..< bank.count {
		raw := formats.read_clip(bank, clip) or_return
		keys := make([][4]f32, len(raw) / 3)
		if len(keys) == 0 do return false
		for &key, at in keys {
			value := [3]f32{f32(raw[3 * at]), f32(raw[3 * at + 1]), f32(raw[3 * at + 2])}
			switch FACE_TRACKS[at % formats.FACE_CHANNELS].path {
			case .Rotation: key = key_rotation(value * formats.ANGLE)
			case .Translation: key.xyz = value * FACE_MOVE_UNIT / MM
			case .Scale: key.xyz = value * FACE_SCALE_UNIT
			}
		}
		convert.add_clip(&g, FACE_TRACKS[:], len(keys) / formats.FACE_CHANNELS, keys)
	}
	return gltf.write_glb(&g, path)
}
