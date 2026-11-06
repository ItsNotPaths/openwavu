// Effect defs (.fx, docs/formats.md): what an effect looks like and how it moves, as pack data. The importer writes them,
// the renderer reads them. Every particle is a pure function of the scene's fx entry, its age and seed, and the scene
// ring: motion is closed form, randomness comes from the seed and the particle's number.
// Units: metres, seconds, radians; world y is up.
package fx

import "core:encoding/json"

VERSION :: 1

Effect :: struct {
	version:  u32,  // VERSION
	elements: []Element,
}

Element_Kind :: enum u32 {
	Sprite,  // quads facing the camera, a flipbook on each
	Mesh,    // a glb mesh per particle
	Ribbon,  // one strip through the anchor's points of the last trail seconds, from the scene ring
}

Frame_Mode :: enum u32 {
	Life,  // all frames spread evenly over the particle's life
	Loop,  // frames_per_second, from the first again
	Hold,  // frames_per_second, then the last frame stays
}

Blend :: enum u32 {
	Alpha,
	Add,
}

Orient :: enum u32 {
	Camera,     // sprites face the camera
	Direction,  // turned to the entry's `at` rotation (a hit direction)
	Anchor,     // turned with the anchor bone
}

// How a particle takes the anchor's position, rotation or scale.
Bind :: enum u32 {
	Follow,  // every frame
	Spawn,   // once, at the particle's birth: where the anchor was then (the scene ring)
	None,    // never: the world's
}

// A curve's point: time 0 = birth, 1 = death.
Key :: struct($Value: typeid) {
	time:  f32,
	value: Value,
}

Element :: struct {
	kind:                                    Element_Kind,
	frames:                                  []string,  // pack paths: a sprite's flipbook images, a mesh's glb
	frame_mode:                              Frame_Mode,
	frames_per_second:                       f32,
	blend:                                   Blend,
	color:                                   [3]f32,  // times the texture; over 1 brightens
	opacity:                                 f32,
	orient:                                  Orient,
	bind_position, bind_rotation, bind_scale: Bind,
	count:                                   u32,  // particles per spawn; the track count when there are tracks
	delay:                                   f32,  // first spawn after the entry starts
	period:                                  f32,  // spawns again every period; 0 = once
	life, life_jitter:                       f32,  // life + up to life_jitter
	size, size_jitter:                       f32,  // quad half side, ribbon half width
	depth_bias:                              f32,  // metres nearer than it is, for the draw order only
	trail:                                   f32,  // ribbon: seconds of the anchor's past it spans
	size_curve, opacity_curve:               []Key(f32),  // times size and opacity; none = 1
	color_curve:                             []Key([3]f32),  // times color; none = 1
	motion:                                  Motion,
	tracks:                                  []Track,  // baked paths: when present they replace motion
}

// Free particle motion from the birth point, along the entry's `at` forward direction.
Motion :: struct {
	box:                         [3]f32,  // random start offset, half sides
	cone:                        f32,     // random spread around the direction; tau = any way
	speed, speed_jitter:         f32,     // metres per second, plus or minus
	gravity:                     f32,     // metres per second squared, down
	drag:                        f32,     // speed lost per second, as a fraction
	floor:                       f32,     // dies this far below its birth height; 0 = never
	spin, spin_jitter:           f32,     // roll at birth, plus or minus
	spin_rate, spin_rate_jitter: f32,     // roll per second, plus or minus
}

// One particle's path, one key per sim tick (60 a second): position from the birth point, size and opacity factors.
Track :: struct {
	positions: [][3]f32,
	sizes:     []f32,
	opacities: []f32,
}

// An .fx file's effect, its slices and strings in allocator; false when it is no effect of a version this reads.
read :: proc(data: []byte, allocator := context.allocator) -> (effect: Effect, ok: bool) {
	if json.unmarshal(data, &effect, allocator = allocator) != nil do return
	return effect, effect.version >= 1 && effect.version <= VERSION
}

write :: proc(effect: Effect, allocator := context.allocator) -> (data: []byte, ok: bool) {
	written, err := json.marshal(effect, {pretty = true, use_enum_names = true}, allocator)
	return written, err == nil
}
