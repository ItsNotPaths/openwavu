// Drawing between sim ticks: the display runs at the player's fps, the sim at 60 (docs/app.md, Frame rate).
package render

import "core:math/linalg"

// The scene on screen: the tick before the newest, alpha of the way to the newest.
Blend :: struct {
	shown:     Scene,
	from_node: map[[32]u8]int,  // the earlier tick's node index by id
	fighters:  bool,            // gameplay nodes blend too
}

blend_create :: proc() -> Blend {
	return {shown = scene_create(), fighters = true}
}

blend_destroy :: proc(blend: ^Blend) {
	scene_destroy(&blend.shown)
	delete(blend.from_node)
}

// A new tick's scene came in; from is the one before it.
blend_restart :: proc(blend: ^Blend, from: ^Scene) {
	clear(&blend.from_node)
	if from != nil do for node, index in from.nodes do blend.from_node[node.id] = index
}

// Nodes match by id; a new node, a no-blend node and, with fighters off, a gameplay node draw as in to.
blend_scenes :: proc(blend: ^Blend, from, to: ^Scene, alpha: f32) -> ^Scene {
	shown := &blend.shown
	from := from != nil && alpha < 1 ? from : nil
	shown.ambient, shown.fog = to.ambient, to.fog
	shown.camera = from != nil ? blend_camera(from.camera, to.camera, alpha) : to.camera
	clear(&shown.lights)
	append(&shown.lights, ..to.lights[:])

	bone_count := 0
	for node in to.nodes do bone_count += len(node.bones)
	clear(&shown.bones)
	reserve(&shown.bones, bone_count)  // the shown nodes slice into it
	clear(&shown.nodes)
	for node in to.nodes {
		blended := node
		first := len(shown.bones)
		append(&shown.bones, ..node.bones)
		blended.bones = shown.bones[first:first + len(node.bones)]
		blends := from != nil && .No_Blend not_in node.flags && (blend.fighters || node.class != .Gameplay)
		if earlier, found := blend.from_node[node.id]; blends && found do blend_node(&blended, from.nodes[earlier], alpha)
		append(&shown.nodes, blended)
	}

	clear(&shown.fx)
	for effect in to.fx {
		blended := effect
		if from != nil do for earlier in from.fx do if earlier.effect == effect.effect && earlier.seed == effect.seed {
			blended.at = blend_transform(earlier.at, effect.at, alpha)
			blended.age = linalg.lerp(earlier.age, effect.age, alpha)
			break
		}
		append(&shown.fx, blended)
	}
	return shown
}

@(private = "file")
blend_node :: proc(node: ^Node, earlier: Node, alpha: f32) {
	node.transform = blend_transform(earlier.transform, node.transform, alpha)
	if len(earlier.bones) == len(node.bones) do for &bone, index in node.bones do bone = blend_transform(earlier.bones[index], bone, alpha)
	if earlier.clip == node.clip && earlier.clip_time <= node.clip_time do node.clip_time = linalg.lerp(earlier.clip_time, node.clip_time, alpha)  // not across a loop
	node.material.tint = linalg.lerp(earlier.material.tint, node.material.tint, alpha)
	node.material.params = linalg.lerp(earlier.material.params, node.material.params, alpha)
}

@(private = "file")
blend_transform :: proc(from, to: Transform, alpha: f32) -> Transform {
	return {
		position = linalg.lerp(from.position, to.position, alpha),
		rotation = linalg.quaternion_slerp(from.rotation, to.rotation, alpha),
		scale = linalg.lerp(from.scale, to.scale, alpha),
	}
}

@(private = "file")
blend_camera :: proc(from, to: Camera, alpha: f32) -> Camera {
	return {
		position = linalg.lerp(from.position, to.position, alpha),
		target = linalg.lerp(from.target, to.target, alpha),
		fov = linalg.lerp(from.fov, to.fov, alpha),
		roll = linalg.lerp(from.roll, to.roll, alpha),
	}
}
