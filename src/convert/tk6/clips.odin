// TK6 finger and face clips as glTF clip banks (convert/clips.odin) on the character's glb bone tree: the game's axis keys
// baked to bone rotations, face positions (mm) to metres. tk6decomp docs/data.md "Hands, face and move cameras".
package tk6_convert

import "core:math"
import "../../convert"
import formats "../../formats/tk6"
import tk5_formats "../../formats/tk5"
import "../../gltf"

FIRST_FINGER_JOINT :: FIRST_FINGER_RECORD + 1  // glb joints 76..90 the right fingers, 91..105 the left, each root joint first
FIRST_FACE_JOINT :: 108  // BONE records 107..146 under ATAMA_Joint
// (hole tk6-face-scales :tags (tk6 importer) :sev polish) face channels 80 and 81 (scales, neutral about 1.0) are not imported: which bones they size is a guess (jaw 127, tongue 128).

// Left fingers play the right hand's keys mirrored by joint in its finger: roots S_y M S_y, the others S_x M S_x [likely, as TK5].
@(rodata)
LEFT_MIRROR := [3][4]f32{{-1, 1, -1, 1}, {1, -1, -1, 1}, {1, -1, -1, 1}}

// The sim's turn of an axis key (axis pitch, axis yaw, angle; t6_anim_key_turn) as a glTF rotation. The sim keeps the
// rotation's matrix transposed, so the glTF quaternion is the conjugate.
key_rotation :: proc(key: [3]f32) -> [4]f32 {
	pitch, yaw, angle := key.x, key.y, key.z
	axis := [3]f32{math.sin(yaw) * math.cos(pitch), -math.sin(pitch), math.cos(yaw) * math.cos(pitch)}
	sine := math.sin(angle / 2)
	return {-axis.x * sine, -axis.y * sine, -axis.z * sine, math.sqrt(1 - sine * sine)}
}

// A bank glb on the glb bone tree (glb_skeleton).
@(private = "file")
clip_gltf :: proc(bones: tk5_formats.Skeleton) -> (g: gltf.Gltf) {
	roots, _ := add_bones(&g, bones, len(bones.bones))
	append(&g.scenes, gltf.Scene{nodes = roots})
	return
}

// Tracks 0..14 the right fingers, 15..29 the left: either hand can play any clip.
write_hand_clips :: proc(path: string, bones: tk5_formats.Skeleton, bank: tk5_formats.Clip_Bank) -> (ok: bool) {
	context.allocator = context.temp_allocator
	g := clip_gltf(bones)
	tracks: [2 * tk5_formats.HAND_JOINTS]convert.Clip_Track
	for &track, index in tracks do track = {FIRST_FINGER_JOINT + index, .Rotation}
	for clip in 0 ..< bank.count {
		frames := tk5_formats.read_hand_clip(bank, clip) or_return
		if len(frames) == 0 do return false
		keys := make([][4]f32, len(frames) * len(tracks))
		for frame, frame_index in frames do for joint in 0 ..< tk5_formats.HAND_JOINTS {
			turn := key_rotation({f32(frame[joint][0]), f32(frame[joint][1]), f32(frame[joint][2])} * tk5_formats.ANGLE)
			keys[frame_index * len(tracks) + joint] = turn
			keys[frame_index * len(tracks) + tk5_formats.HAND_JOINTS + joint] = turn * LEFT_MIRROR[joint % 3]
		}
		convert.add_clip(&g, tracks[:], len(frames), keys)
	}
	return gltf.write_glb(&g, path)
}

// Face bone k: channel 2k its position, 2k + 1 its rotation; each replaces the bind one.
write_face_clips :: proc(path: string, bones: tk5_formats.Skeleton, bank: formats.Mota_Bank) -> (ok: bool) {
	context.allocator = context.temp_allocator
	g := clip_gltf(bones)
	tracks: [2 * formats.FACE_BONES]convert.Clip_Track
	for &track, index in tracks do track = {FIRST_FACE_JOINT + index / 2, index % 2 == 0 ? .Translation : .Rotation}
	for clip in 0 ..< bank.count {
		face := formats.read_face_clip(bank, clip) or_return
		keys := make([][4]f32, face.frames * len(tracks))
		for frame, frame_index in face.values do for &key, track in keys[frame_index * len(tracks):][:len(tracks)] {
			key = tracks[track].path == .Rotation ? key_rotation(frame[track]) : {frame[track].x / MM, frame[track].y / MM, frame[track].z / MM, 0}
		}
		convert.add_clip(&g, tracks[:], face.frames, keys)
	}
	return gltf.write_glb(&g, path)
}
