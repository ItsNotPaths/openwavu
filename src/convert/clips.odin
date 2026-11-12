// Bone clips as glTF 2.0 animation, the same for every game: display-only motion (faces, hands) baked to each bone's
// local rotation, translation (metres) and scale, keyed every 1 / CLIP_FPS seconds from 0, linear between keys.
// A clip bank is one glb: the bone tree of the model it plays on, then animation i = clip i, every clip with the same tracks.
package convert

import "core:fmt"
import "../gltf"

CLIP_FPS :: 60

Clip_Path :: enum {Rotation, Translation, Scale}

@(rodata)
CLIP_PATH_NAMES := [Clip_Path]string{.Rotation = "rotation", .Translation = "translation", .Scale = "scale"}

Clip_Track :: struct {
	node: int,
	path: Clip_Path,
}

// keys: [frames][tracks]; a rotation is a quaternion x, y, z, w; a translation or a scale is x, y, z.
add_clip :: proc(g: ^gltf.Gltf, tracks: []Clip_Track, frames: int, keys: [][4]f32) {
	times := make([]f32, frames, context.temp_allocator)
	for &time, frame in times do time = f32(frame) / CLIP_FPS
	input := gltf.add_accessor(g, times, "SCALAR", with_bounds = true)
	animation := gltf.Animation{name = fmt.tprintf("%d", len(g.animations))}
	for track, index in tracks {
		output: int
		if track.path == .Rotation {
			values := make([][4]f32, frames, context.temp_allocator)
			for &value, frame in values do value = keys[frame * len(tracks) + index]
			output = gltf.add_accessor(g, values, "VEC4")
		} else {
			values := make([][3]f32, frames, context.temp_allocator)
			for &value, frame in values do value = keys[frame * len(tracks) + index].xyz
			output = gltf.add_accessor(g, values, "VEC3")
		}
		append(&animation.samplers, gltf.Sampler{input = input, output = output, interpolation = "LINEAR"})
		append(&animation.channels, gltf.Channel{sampler = index, target = {node = track.node, path = CLIP_PATH_NAMES[track.path]}})
	}
	append(&g.animations, animation)
}
