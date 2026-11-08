// Spring bones (glTF VRMC_springBone 1.0): joint chains that swing behind the pose. Drawn only, never rolled back; a
// scene node keeps its chains' tail points from frame to frame, by node id.
package render

import "core:encoding/json"
import "core:math"
import "core:math/linalg"
import "../../vendor/cgltf"
import "../gltf"

SWING_STEP_MAX :: 1.0 / 20  // seconds; a longer frame steps this much

// One swinging joint: it turns so its tail node points at a point that trails behind.
Swing_Joint :: struct {
	node, tail: int,     // glb nodes; tail is a child of node
	hit_radius: f32,     // metres, around the tail point
	stiffness:  f32,     // pull back toward the rest pose
	gravity:    [3]f32,  // direction times power
	drag:       f32,     // share of the speed lost per 1/60 s
	colliders:  [2]int,  // first and count in Model.swing_colliders
	limit:      gltf.Swing_Limit,
}

// A sphere, or a capsule when tail is not offset, or an ellipsoid; node space.
Swing_Collider :: struct {
	node:         int,
	offset, tail: [3]f32,
	radius:       f32,
	ellipsoid:    Maybe(gltf.Ellipsoid),
}

Swings :: struct {
	states:  map[[32]u8]Swing_State,  // by scene node id
	seconds: f32,                     // since the last frame drawn
	frame:   u64,
}

Swing_State :: struct {
	model:           ^Model,
	tails, previous: [][3]f32,  // world, by Model.swings
	last_seconds:    f32,
	frame:           u64,       // last drawn
}

swings_destroy :: proc(swings: ^Swings) {
	swings_clear(swings)
	delete(swings.states)
}

swings_clear :: proc(swings: ^Swings) {
	for _, state in swings.states do state_destroy(state)
	clear(&swings.states)
}

@(private = "file")
state_destroy :: proc(state: Swing_State) {
	delete(state.tails)
	delete(state.previous)
}

// Drops the states of nodes not drawn this frame.
swings_sweep :: proc(swings: ^Swings) {
	stale := make([dynamic][32]u8, context.temp_allocator)
	for id, state in swings.states do if state.frame != swings.frame do append(&stale, id)
	for id in stale {
		state_destroy(swings.states[id])
		delete_key(&swings.states, id)
	}
}

// Turns each swinging joint of world (per glb node, posed with bones) toward its trailing tail point, its subtree with
// it. A new node, a no-blend node or another model starts from the rest pose.
swing :: proc(swings: ^Swings, node: ^Node, model: ^Model, bones: []Transform, world: []matrix[4, 4]f32) {
	if len(model.swings) == 0 do return
	place := transform_matrix(node.transform)
	state, known := &swings.states[node.id]
	restart := !known || state.model != model || len(state.tails) != len(model.swings) || .No_Blend in node.flags
	if !known {
		swings.states[node.id] = {}
		state = &swings.states[node.id]
	}
	if restart {
		state_destroy(state^)
		state^ = {model = model, tails = make([][3]f32, len(model.swings)), previous = make([][3]f32, len(model.swings))}
	}
	seconds := min(swings.seconds, SWING_STEP_MAX)
	for joint, index in model.swings {
		head := world[joint.node][3].xyz
		rest := (world[joint.node] * model.nodes[joint.tail].local)[3].xyz
		length := linalg.length(rest - head)
		if length == 0 do continue
		if restart {
			state.tails[index], state.previous[index] = rest, rest
		} else if seconds > 0 {
			speed_kept := math.pow(1 - joint.drag, seconds * 60) * (state.last_seconds > 0 ? seconds / state.last_seconds : 1)
			next := state.tails[index] + (state.tails[index] - state.previous[index]) * speed_kept
			next += (linalg.normalize(rest - head) * joint.stiffness + joint.gravity) * seconds
			next = head + linalg.normalize0(next - head) * length
			for collider in model.swing_colliders[joint.colliders[0]:][:joint.colliders[1]] do next = push_out(model.colliders[collider], world, next, joint.hit_radius, head, length)
			next = head + limit_turn(joint.limit, world[joint.node], next - head)
			state.previous[index], state.tails[index] = state.tails[index], next
		}
		turn := linalg.quaternion_between_two_vector3(rest - head, state.tails[index] - head)
		world[joint.node] = linalg.matrix4_translate(head) * linalg.matrix4_from_quaternion(turn) * linalg.matrix4_translate(-head) * world[joint.node]
		for child in model.nodes[joint.node].children do pose(model, bones, world, child, world[joint.node], place)
	}
	if seconds > 0 do state.last_seconds = seconds
	state.frame = swings.frame
}

// The arm from head to tail turned back inside the joint's limit, measured in its rest frame (place, before it swings).
@(private = "file")
limit_turn :: proc(limit: gltf.Swing_Limit, place: matrix[4, 4]f32, arm: [3]f32) -> [3]f32 {
	tilt_range, has_tilt := limit.tilt.?
	swing_range, has_swing := limit.swing.?
	ellipse, has_ellipse := limit.ellipse.?
	if !has_tilt && !has_swing && !has_ellipse do return arm
	frame := matrix[3, 3]f32{place[0, 0], place[0, 1], place[0, 2], place[1, 0], place[1, 1], place[1, 2], place[2, 0], place[2, 1], place[2, 2]}
	local := linalg.transpose(frame) * arm
	tilt := math.atan2(-local.z, math.sqrt(local.x * local.x + local.y * local.y))
	swing := math.atan2(local.y, local.x)
	if has_tilt do tilt = clamp(tilt, tilt_range[0], tilt_range[1])
	if has_swing do swing = clamp(swing, swing_range[0], swing_range[1])
	if has_ellipse {
		offset := [2]f32{(tilt - ellipse.centre[0]) / ellipse.radius[0], (swing - ellipse.centre[1]) / ellipse.radius[1]}
		if reach := linalg.length(offset); reach > 1 {
			tilt = ellipse.centre[0] + (tilt - ellipse.centre[0]) / reach
			swing = ellipse.centre[1] + (swing - ellipse.centre[1]) / reach
		}
	}
	return frame * [3]f32{math.cos(tilt) * math.cos(swing), math.cos(tilt) * math.sin(swing), -math.sin(tilt)} * linalg.length(local)
}

// The tail point moved out of the collider, then back to its length from head.
@(private = "file")
push_out :: proc(collider: Swing_Collider, world: []matrix[4, 4]f32, tail: [3]f32, hit_radius: f32, head: [3]f32, length: f32) -> [3]f32 {
	place := world[collider.node]
	if shape, is := collider.ellipsoid.?; is {
		turn := quaternion(x = shape.rotation.x, y = shape.rotation.y, z = shape.rotation.z, w = shape.rotation.w)
		frame := place * linalg.matrix4_translate(shape.offset) * linalg.matrix4_from_quaternion(turn)
		local := (linalg.inverse(frame) * [4]f32{tail.x, tail.y, tail.z, 1}).xyz
		radii := shape.radii + hit_radius
		if linalg.length(local / radii) >= 1 do return tail
		surface := linalg.normalize0(local / radii) * radii
		pushed := (frame * [4]f32{surface.x, surface.y, surface.z, 1}).xyz
		return head + linalg.normalize0(pushed - head) * length
	}
	start := (place * [4]f32{collider.offset.x, collider.offset.y, collider.offset.z, 1}).xyz
	end := (place * [4]f32{collider.tail.x, collider.tail.y, collider.tail.z, 1}).xyz
	along := end - start
	share := linalg.dot(along, along) > 0 ? clamp(linalg.dot(tail - start, along) / linalg.dot(along, along), 0, 1) : 0
	nearest := start + along * share
	reach := collider.radius + hit_radius
	if linalg.length(tail - nearest) >= reach do return tail
	pushed := nearest + linalg.normalize0(tail - nearest) * reach
	return head + linalg.normalize0(pushed - head) * length
}

@(private = "file")
Spring_File :: struct {
	colliders:      []struct {
		node:   int,
		extras: Maybe(gltf.Ellipsoid),
		shape: struct {
			sphere:  Maybe(struct {
				offset: [3]f32,
				radius: f32,
			}),
			capsule: Maybe(struct {
				offset, tail: [3]f32,
				radius:       f32,
			}),
		},
	},
	colliderGroups: []struct {
		colliders: []int,
	},
	springs:        []struct {
		joints:         []struct {
			node:         int,
			hitRadius:    f32,
			stiffness:    Maybe(f32),
			gravityPower: f32,
			gravityDir:   Maybe([3]f32),
			dragForce:    Maybe(f32),
			extras:       gltf.Swing_Limit,
		},
		colliderGroups: []int,
	},
}

// The glb's springs into model.swings, model.colliders and model.swing_colliders; none is fine. Fails on a node,
// collider or group outside the glb; a joint whose next is not its child does not swing.
swings_read :: proc(model: ^Model, file: ^cgltf.data) -> (ok: bool) {
	extension: cgltf.extension
	for entry in file.data_extensions[:file.data_extensions_count] do if entry.name == gltf.SPRING_EXTENSION do extension = entry
	if extension.data == nil do return true
	springs: Spring_File
	if json.unmarshal_string(string(cstring(extension.data)), &springs, allocator = context.temp_allocator) != nil do return false
	nodes := len(model.nodes)
	model.colliders = make([]Swing_Collider, len(springs.colliders))
	for entry, index in springs.colliders {
		if entry.node < 0 || entry.node >= nodes do return false
		collider := &model.colliders[index]
		collider.node, collider.ellipsoid = entry.node, entry.extras
		if sphere, is := entry.shape.sphere.?; is do collider.offset, collider.tail, collider.radius = sphere.offset, sphere.offset, sphere.radius
		if capsule, is := entry.shape.capsule.?; is do collider.offset, collider.tail, collider.radius = capsule.offset, capsule.tail, capsule.radius
	}
	joints, listed := make([dynamic]Swing_Joint), make([dynamic]int)
	defer model.swings, model.swing_colliders = joints[:], listed[:]  // also on a failure, so model_destroy frees them
	for spring in springs.springs {
		first := len(listed)
		for group in spring.colliderGroups {
			if group < 0 || group >= len(springs.colliderGroups) do return false
			for collider in springs.colliderGroups[group].colliders {
				if collider < 0 || collider >= len(model.colliders) do return false
				append(&listed, collider)
			}
		}
		for index in 0 ..< max(len(spring.joints) - 1, 0) {
			entry, next := spring.joints[index], spring.joints[index + 1].node
			if entry.node < 0 || entry.node >= nodes || next < 0 || next >= nodes do return false
			if model.nodes[next].parent != entry.node do continue
			append(&joints, Swing_Joint{
				node = entry.node,
				tail = next,
				hit_radius = entry.hitRadius,
				stiffness = entry.stiffness.? or_else 1,
				gravity = (entry.gravityDir.? or_else {0, -1, 0}) * entry.gravityPower,
				drag = clamp(entry.dragForce.? or_else 0.5, 0, 1),
				colliders = {first, len(listed) - first},
				limit = entry.extras,
			})
		}
	}
	return true
}
