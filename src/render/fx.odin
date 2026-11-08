// Host fx: the fx entries of the scene (effect def, anchor, age, seed) as camera facing quads. The app builds the entries;
// the host keeps no fx state: each particle is worked out from the entry, its age and seed, and the scene ring.
package render

import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"
import "../fx"

Fx_Vertex :: struct {
	position: [3]f32,
	uv:       [2]f32,
	color:    [4]f32,
}

// Six vertices in Fx_Quads.vertices from first.
Fx_Quad :: struct {
	first:    u32,
	texture:  ^sdl.GPUTexture,
	add:      bool,
	distance: f32,  // from the camera, less the depth bias: drawn far to near
}

Fx_Quads :: struct {
	vertices: [dynamic]Fx_Vertex,
	quads:    [dynamic]Fx_Quad,
}

// What one entry's particles are placed from: its anchor now, and the ring for where it was before.
@(private = "file")
Anchors :: struct {
	now:    matrix[4, 4]f32,
	entry:  ^Fx,
	scene:  ^Scene,
	ring:   ^Scene_Ring,
	assets: ^Assets,
	gpu:    ^Gpu,
}

// (hole fx-mesh-ribbon :tags (render effects)) mesh and ribbon elements are not drawn; only sprites.
fx_quads :: proc(ring: ^Scene_Ring, scene: ^Scene, assets: ^Assets, gpu: ^Gpu, allocator := context.temp_allocator) -> (out: Fx_Quads) {
	out.vertices = make([dynamic]Fx_Vertex, allocator)
	out.quads = make([dynamic]Fx_Quad, allocator)
	for &entry in scene.fx {
		effect := asset_effect(assets, gpu, entry.effect)
		if effect == nil do continue
		now, placed := anchor_matrix(scene, entry.node, entry.bone, entry.at, assets, gpu)
		if !placed do continue
		anchors := Anchors{now, &entry, scene, ring, assets, gpu}
		for &element, element_index in effect.elements {
			if element.kind == .Sprite do sprite_quads(&out, &element, u32(element_index), &anchors)
		}
	}
	return
}

@(private = "file")
sprite_quads :: proc(out: ^Fx_Quads, element: ^fx.Element, element_index: u32, anchors: ^Anchors) {
	if len(element.frames) == 0 do return
	age := anchors.entry.age
	longest := element.life + element.life_jitter
	first_spawn := 0
	if element.period > 0 do first_spawn = max(0, int(math.ceil((age - element.delay - longest) / element.period)))
	count := len(element.tracks) > 0 ? len(element.tracks) : int(element.count)
	for spawn := first_spawn; ; spawn += 1 {
		birth := element.delay + f32(spawn) * element.period
		if birth > age do break
		for particle in 0 ..< count {
			random := random_start(anchors.entry.seed, element_index, u32(spawn), u32(particle))
			particle_age := age - birth
			life := element.life + element.life_jitter * random_next(&random)
			if particle_age >= life do continue
			sprite_quad(out, element, particle, particle_age, life, &random, anchors)
		}
		if element.period <= 0 do break
	}
}

@(private = "file")
sprite_quad :: proc(out: ^Fx_Quads, element: ^fx.Element, particle: int, particle_age, life: f32, random: ^u32, anchors: ^Anchors) {
	life_part := particle_age / life
	size := element.size + element.size_jitter * random_signed(random)
	opacity := element.opacity
	local: [3]f32
	if len(element.tracks) > 0 {
		track := element.tracks[particle]
		tick := particle_age * 60
		local = sample(track.positions, tick)
		size *= sample(track.sizes, tick)
		opacity *= sample(track.opacities, tick)
	} else {
		local = motion_offset(element.motion, particle_age, random)
	}
	size *= curve(element.size_curve, life_part)
	opacity *= curve(element.opacity_curve, life_part)
	if size <= 0 || opacity <= 0 do return

	birth := anchors.now
	if element.bind_position == .Spawn || element.bind_rotation == .Spawn do birth = anchor_back(anchors, particle_age)
	origin := pick(element.bind_position, anchors.now, birth)
	turn := pick(element.bind_rotation, anchors.now, birth)
	position := origin[3].xyz + rotation_of(turn) * local
	if len(element.tracks) == 0 do position.y -= element.motion.gravity * particle_age * particle_age / 2

	color := element.color * curve(element.color_curve, life_part)
	texture := anchors.assets.textures[element.frames[flipbook_frame(element, particle_age, life_part)]] or_else nil
	motion := element.motion
	roll := motion.spin + motion.spin_jitter * random_signed(random) + (motion.spin_rate + motion.spin_rate_jitter * random_signed(random)) * particle_age
	quad_color := [4]f32{color.r, color.g, color.b, opacity}
	camera_quad(out, anchors.scene.camera, position, size, roll, element.depth_bias, quad_color, texture, element.blend == .Add)
}

// The anchor's world matrix: the node's bone in its pose, or a world point, times at.
@(private = "file")
anchor_matrix :: proc(scene: ^Scene, node_number, bone: u32, at: Transform, assets: ^Assets, gpu: ^Gpu) -> (anchor: matrix[4, 4]f32, ok: bool) {
	place := transform_matrix(at)
	if node_number == 0 do return place, true
	if int(node_number) > len(scene.nodes) do return
	return node_bone_matrix(&scene.nodes[node_number - 1], bone, assets, gpu) * place, true
}

@(private = "file")
node_bone_matrix :: proc(node: ^Node, bone: u32, assets: ^Assets, gpu: ^Gpu) -> matrix[4, 4]f32 {
	place := transform_matrix(node.transform)
	model := asset_model(assets, gpu, node.asset)
	if model == nil || len(model.skins) == 0 || int(bone) >= len(model.skins[0].joints) do return place
	return posed_world(model, node.bones, place)[model.skins[0].joints[bone]]
}

// The anchor some time back: the same node in the ring's scene of then, found by id; the oldest held when past the ring.
@(private = "file")
anchor_back :: proc(anchors: ^Anchors, seconds: f32) -> matrix[4, 4]f32 {
	entry := anchors.entry
	if entry.node == 0 || int(entry.node) > len(anchors.scene.nodes) do return anchors.now
	past := scene_ring_back(anchors.ring, min(int(math.round(seconds * 60)), anchors.ring.count - 1))
	id := anchors.scene.nodes[entry.node - 1].id
	for &node in past.nodes {
		if node.id == id do return node_bone_matrix(&node, entry.bone, anchors.assets, anchors.gpu) * transform_matrix(entry.at)
	}
	return anchors.now
}

@(private = "file")
pick :: proc(bind: fx.Bind, now, birth: matrix[4, 4]f32) -> matrix[4, 4]f32 {
	switch bind {
	case .Follow: return now
	case .Spawn: return birth
	case .None: return 1
	}
	return now
}

// The turn of a matrix without its scale.
@(private = "file")
rotation_of :: proc(place: matrix[4, 4]f32) -> matrix[3, 3]f32 {
	turn := linalg.matrix3_from_matrix4(place)
	for column in 0 ..< 3 {
		length := linalg.length(turn[column])
		if length > 0 do turn[column] /= length
	}
	return turn
}

// A start offset in its box, then along a random way in the cone around +z at a speed that drag slows.
@(private = "file")
motion_offset :: proc(motion: fx.Motion, age: f32, random: ^u32) -> [3]f32 {
	start := motion.box * [3]f32{random_signed(random), random_signed(random), random_signed(random)}
	way: [3]f32
	if motion.cone >= math.TAU - 0.001 {
		height := random_signed(random)
		around := random_next(random) * math.TAU
		across := math.sqrt(max(0, 1 - height * height))
		way = {across * math.cos(around), height, across * math.sin(around)}
	} else {
		yaw, pitch := random_signed(random) * motion.cone / 2, random_signed(random) * motion.cone / 2
		way = {math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)}
	}
	speed := motion.speed + motion.speed_jitter * random_signed(random)
	distance := motion.drag > 0 ? speed * (1 - math.exp(-motion.drag * age)) / motion.drag : speed * age
	return start + way * distance
}

@(private = "file")
flipbook_frame :: proc(element: ^fx.Element, age, life_part: f32) -> int {
	frames := len(element.frames)
	switch element.frame_mode {
	case .Life: return min(int(life_part * f32(frames)), frames - 1)
	case .Loop: return int(age * element.frames_per_second) % frames
	case .Hold: return min(int(age * element.frames_per_second), frames - 1)
	}
	return 0
}

@(private = "file")
camera_quad :: proc(out: ^Fx_Quads, camera: Camera, position: [3]f32, size, roll, depth_bias: f32, color: [4]f32, texture: ^sdl.GPUTexture, add: bool) {
	forward := linalg.normalize(camera.target - camera.position)
	right := linalg.normalize(linalg.cross(forward, [3]f32{0, 1, 0}))
	up := linalg.cross(right, forward)
	cosine, sine := math.cos(roll), math.sin(roll)
	right, up = (right * cosine + up * sine) * size, (up * cosine - right * sine) * size
	corners := [4]Fx_Vertex{
		{position - right - up, {0, 1}, color},
		{position + right - up, {1, 1}, color},
		{position + right + up, {1, 0}, color},
		{position - right + up, {0, 0}, color},
	}
	append(&out.quads, Fx_Quad{u32(len(out.vertices)), texture, add, linalg.distance(position, camera.position) - depth_bias})
	append(&out.vertices, corners[0], corners[1], corners[2], corners[0], corners[2], corners[3])
}

// A value at a fractional tick, between the keys around it; the last key past the end.
@(private = "file")
sample :: proc(keys: []$T, tick: f32) -> T {
	if len(keys) == 0 do return 1
	at := clamp(tick, 0, f32(len(keys) - 1))
	low := int(at)
	high := min(low + 1, len(keys) - 1)
	return keys[low] + (keys[high] - keys[low]) * (at - f32(low))
}

// The curve's value at a time of life, between its keys; no keys is 1.
@(private = "file")
curve :: proc(keys: []fx.Key($Value), time: f32) -> Value {
	if len(keys) == 0 do return 1
	if time <= keys[0].time do return keys[0].value
	for index in 1 ..< len(keys) {
		if time > keys[index].time do continue
		before, after := keys[index - 1], keys[index]
		return before.value + (after.value - before.value) * (time - before.time) / max(after.time - before.time, 1e-6)
	}
	return keys[len(keys) - 1].value
}

// A particle's own random numbers: the same entry seed, element, spawn and particle give the same numbers.
@(private = "file")
random_start :: proc(seed, element, spawn, particle: u32) -> u32 {
	return mix(seed ~ mix(element + mix(spawn + mix(particle))))
}

// 0 up to 1.
@(private = "file")
random_next :: proc(state: ^u32) -> f32 {
	state^ = mix(state^ + 0x9e3779b9)
	return f32(state^ >> 8) / (1 << 24)
}

// -1 up to 1.
@(private = "file")
random_signed :: proc(state: ^u32) -> f32 {
	return random_next(state) * 2 - 1
}

// An integer hash (lowbias32).
@(private = "file")
mix :: proc(value: u32) -> u32 {
	value := value
	value ~= value >> 16
	value *= 0x7feb352d
	value ~= value >> 15
	value *= 0x846ca68b
	value ~= value >> 16
	return value
}
