// The scene a pack sends (sdk/include/ow_scene.h), read out of its block into host types. Old packs send shorter
// structs and newer ones longer: each is read up to the size the pack gives, at least the version 1 size.
package render

import "core:fmt"
import "core:mem"

Transform :: struct {
	position: [3]f32,
	rotation: quaternion128,
	scale:    [3]f32,
}

Camera :: struct {
	position, target: [3]f32,
	fov, roll:        f32,  // radians
}

Light_Kind :: enum u32 {
	Directional,
	Point,
}

Light :: struct {
	kind:      Light_Kind,
	color:     [4]f32,  // a = intensity
	position:  [3]f32,
	direction: [3]f32,
	range:     f32,
}

Fog :: struct {
	color:      [4]f32,
	start, end: f32,  // end 0 is no fog
}

Material :: struct {
	tint:            [4]f32,
	texture, shader: u32,  // asset ids; 0 keeps the asset's
	params:          [8]f32,
}

Node_Flag :: enum u32 {
	Billboard,
	No_Shadow,
	No_Blend,
	Hidden,
}

Node_Class :: enum u32 {
	Gameplay,
	Scenery,
}

Node :: struct {
	id:              [32]u8,
	asset:           u32,
	part:            u32,          // glb node index + 1; 0 = the whole glb but its _DRWOFF_ nodes
	texture:         u32,
	transform:       Transform,
	bones:           []Transform,  // into Scene.bones; empty is the glb's own pose
	clip:            u32,          // glb animation index + 1
	clip_time:       f32,
	material:        Material,
	flags:           bit_set[Node_Flag; u32],
	class:           Node_Class,
}

Fx :: struct {
	effect, node, bone: u32,  // node: index + 1, 0 is a world point
	at:                 Transform,
	age:                f32,
	seed:               u32,
}

Scene :: struct {
	camera:  Camera,
	ambient: [4]f32,
	fog:     Fog,
	lights:  [dynamic]Light,
	nodes:   [dynamic]Node,
	fx:      [dynamic]Fx,
	bones:   [dynamic]Transform,
}

// Reading a block grows the lists with the allocator they are made with here.
scene_create :: proc() -> Scene {
	return {
		lights = make([dynamic]Light),
		nodes = make([dynamic]Node),
		fx = make([dynamic]Fx),
		bones = make([dynamic]Transform),
	}
}

scene_destroy :: proc(s: ^Scene) {
	delete(s.lights)
	delete(s.nodes)
	delete(s.fx)
	delete(s.bones)
}

// Reads a block into s, reusing its arrays. On err s holds part of the block; the caller drops it.
read_scene :: proc(s: ^Scene, block: []byte) -> (err: string) {
	head: Wire_Scene
	if err = read_record(&head, block, 0, wire_size(block, 4), "the scene"); err != "" do return
	if head.version < 1 do return "the scene has no version"
	s.camera, s.ambient, s.fog = head.camera, head.ambient, head.fog
	clear(&s.lights)
	clear(&s.nodes)
	clear(&s.fx)
	if err = read_list(&s.lights, block, head.light_offset, head.light_count, head.light_size, "a light"); err != "" do return
	for light in s.lights do if light.kind > max(Light_Kind) do return "a light has no such kind"
	if err = read_list(&s.fx, block, head.fx_offset, head.fx_count, head.fx_size, "an effect"); err != "" do return
	wire_nodes: [dynamic]Wire_Node
	wire_nodes.allocator = context.temp_allocator
	if err = read_list(&wire_nodes, block, head.node_offset, head.node_count, head.node_size, "a node"); err != "" do return
	for f in s.fx do if f.node > head.node_count do return "an effect follows a node the scene does not have"
	for n in wire_nodes do if n.class > max(Node_Class) do return "a node has no such class"

	// Sized once, so the nodes' slices into it stay put.
	bone_total: u64
	for n in wire_nodes do bone_total += u64(n.bone_count)
	if bone_total * size_of(Transform) > u64(len(block)) do return "the nodes' bones do not fit in the scene"
	resize(&s.bones, int(bone_total))
	bone_at := 0
	for n in wire_nodes {
		bones := s.bones[bone_at:][:n.bone_count]
		if err = read_array(bones, block, n.bone_offset, "a node's bones"); err != "" do return
		bone_at += len(bones)
		append(&s.nodes, Node{
			id = n.id,
			asset = n.asset,
			part = n.part,
			texture = n.texture,
			transform = n.transform,
			bones = bones,
			clip = n.clip,
			clip_time = n.clip_time,
			material = n.material,
			flags = n.flags,
			class = n.class,
		})
	}
	return
}

// The block's layout: as ow_scene.h, with a byte offset where Node has a slice.
@(private = "file")
Wire_Scene :: struct {
	version:                                     u32,
	scene_size, light_size, node_size, fx_size: u32,
	camera:                                      Camera,
	ambient:                                     [4]f32,
	fog:                                         Fog,
	light_count, light_offset:                   u32,
	node_count, node_offset:                     u32,
	fx_count, fx_offset:                         u32,
}

@(private = "file")
Wire_Node :: struct {
	id:                      [32]u8,
	asset, part, texture:    u32,
	transform:               Transform,
	bone_count, bone_offset: u32,
	clip:                    u32,
	clip_time:               f32,
	material:                Material,
	flags:                   bit_set[Node_Flag; u32],
	class:                   Node_Class,
}

// The u32 at byte at, or 0 past the end.
@(private = "file")
wire_size :: proc(block: []byte, at: int) -> u32 {
	if at + 4 > len(block) do return 0
	return u32((^u32le)(&block[at])^)
}

// size bytes at offset, as the pack built the record: a longer one is cut to T, and one shorter than T is refused.
@(private = "file")
read_record :: proc(out: ^$T, block: []byte, offset, size: u32, what: string) -> (err: string) {
	if size < size_of(T) do return fmt.tprintf("%s is %d bytes, under the %d of version 1", what, size, size_of(T))
	if u64(offset) + u64(size) > u64(len(block)) do return fmt.tprintf("%s is outside the scene", what)
	mem.copy(out, &block[offset], size_of(T))
	return
}

@(private = "file")
read_list :: proc(list: ^[dynamic]$T, block: []byte, offset, count, size: u32, what: string) -> (err: string) {
	if count == 0 do return
	if u64(offset) + u64(count) * u64(size) > u64(len(block)) do return fmt.tprintf("%s list is outside the scene", what)
	for i in 0 ..< count {
		item: T
		if err = read_record(&item, block, offset + i * size, size, what); err != "" do return
		append(list, item)
	}
	return
}

@(private = "file")
read_array :: proc(out: []$T, block: []byte, offset: u32, what: string) -> (err: string) {
	bytes := u64(len(out)) * size_of(T)
	if bytes == 0 do return
	if u64(offset) + bytes > u64(len(block)) do return fmt.tprintf("%s are outside the scene", what)
	mem.copy(raw_data(out), &block[offset], int(bytes))
	return
}
