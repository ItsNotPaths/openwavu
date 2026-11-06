// EFP records -> effect defs (src/fx): one sprite element per record (tk5decomp docs/effects.md, sections 2, 3a, 5).
// The game steps at 60 ticks a second in mm; the defs are in seconds and metres.
package tk5_convert

import "core:math"
import "../../fx"
import formats "../../formats/tk5"

TICKS :: 60.0
METRES :: 0.001

// (hole efp-gravity :tags (importer effects) :sev gap) the particle kinds' fall per tick is a constant in 0xa6744 that is not read yet; particles do not fall.
EFP_GRAVITY :: 0.0

// (hole efp-spark-size :tags (importer effects) :sev polish) the hit and guard sparks look 10-20% too big next to the game; the size unit (half side in mm) and the baked track scale are not confirmed.
// One record's effect, drawing block's frames; false for the kinds that draw no sprite (3, 5, 17, 18 are unused or
// spawn other records) and for a block with no frame written.
record_effect :: proc(record: formats.Efp_Record, block: formats.Element_Block, tracks: []formats.Efp_Track, files: Texture_Files, allocator := context.allocator) -> (effect: fx.Effect, ok: bool) {
	frames := make([dynamic]string, allocator)
	for hash in block.textures do if file, has := files[hash]; has do append(&frames, file)
	if len(frames) == 0 do return

	life := f32(record.life) / TICKS
	size := f32(record.size) * METRES
	opacity := f32(record.opacity) / 128
	element := fx.Element{
		kind = .Sprite,
		frames = frames[:],
		blend = record.blend == 0 ? .Alpha : .Add,
		color = {f32(record.color[0]), f32(record.color[1]), f32(record.color[2])} / 128,
		opacity = opacity,  // draw modes 2, 3 double a vertex alpha where 128 is 1; the textures' alpha is full range
		orient = .Camera,
		bind_position = .Spawn,
		bind_rotation = .Spawn,
		bind_scale = .None,
		count = u32(max(record.count, 1)),
		life = life,
		size = size,
		size_jitter = size * f32(record.size_jitter) * 0.01,
		depth_bias = f32(record.depth_bias) * 4 * METRES,
		frames_per_second = f32(len(frames)) / life,
	}
	switch record.kind {
	case 0, 1, 8, 12, 13, 16:
		if len(tracks) > 0 {
			element.tracks = baked_tracks(tracks, record.spread, allocator)
			element.count = u32(len(tracks))
			element.life = f32(len(tracks[0].positions)) / TICKS
		} else {
			element.opacity_curve = line(1, 0, allocator)
		}
	case 2:
		element.life_jitter = 31 / TICKS
		element.size_curve = line(0.4, 0, allocator)
		element.opacity_curve = line(1, 0, allocator)
		element.motion = record_motion(record, true)
	case 4, 9, 10, 11, 15:
		element.frame_mode = record.kind == 9 || record.kind == 11 ? .Loop : record.kind == 10 ? .Hold : .Life
		element.life_jitter = f32(record.life_jitter) / TICKS
		element.size_curve = line(1, record.size == 0 ? 1 : f32(record.end_size) / f32(record.size), allocator)
		element.opacity_curve = line(1, record.opacity == 0 ? 1 : f32(record.end_opacity) / f32(record.opacity), allocator)
		element.motion = record_motion(record, record.flags & formats.EFP_SPHERE != 0)
		if record.kind == 11 || (record.kind == 15 && record.follow_disabled == 0) do element.bind_position = .Follow
	case:
		return
	}
	elements := make([]fx.Element, 1, allocator)
	elements[0] = element
	return {version = fx.VERSION, elements = elements}, true
}

@(private = "file")
record_motion :: proc(record: formats.Efp_Record, sphere: bool) -> (motion: fx.Motion) {
	spread := [3]f32{f32(record.spread[0]), f32(record.spread[1]), f32(record.spread[2])} * 0.01
	if record.flags & formats.EFP_RANDOM_START != 0 {
		motion.box = [3]f32{f32(record.box[0]), f32(record.box[1]), f32(record.box[2])} * spread * METRES
	}
	motion.cone = sphere ? math.TAU : f32(record.cone) * math.TAU / 100
	motion.speed = f32(record.speed) * 0.1 * METRES * TICKS
	motion.speed_jitter = motion.speed * f32(record.speed_jitter) * 0.01
	motion.gravity = EFP_GRAVITY
	return
}

@(private = "file")
baked_tracks :: proc(tracks: []formats.Efp_Track, spread: [3]i16, allocator := context.allocator) -> []fx.Track {
	scale := [3]f32{f32(spread[0]), f32(spread[1]), f32(spread[2])} * 0.01 * METRES
	baked := make([]fx.Track, len(tracks), allocator)
	for track, index in tracks {
		positions := make([][3]f32, len(track.positions), allocator)
		for position, tick in track.positions do positions[tick] = [3]f32{f32(position.x), f32(position.y), f32(position.z)} * scale
		baked[index] = {positions = positions, sizes = track.scales, opacities = track.alphas}
	}
	return baked
}

@(private = "file")
line :: proc(start, end: f32, allocator := context.allocator) -> []fx.Key(f32) {
	keys := make([]fx.Key(f32), 2, allocator)
	keys[0], keys[1] = {0, start}, {1, end}
	return keys
}
