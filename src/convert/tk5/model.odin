// Character parts and stage scenes as glb: skinned meshes, metres, Y up. Materials point at their DDS files (texture.odin).
package tk5_convert

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:slice"
import "../../gltf"
import formats "../../formats/tk5"

MM :: 1000.0  // file millimetres per glTF metre
BODY_BONES :: 23  // animated by the 23 channels; the rest are helpers

// Writes root/file. skeleton: nil for unskinned (stage) geometry; mop: its swing joint values. matrices: per mesh, row vectors in file units, or nil.
// layers: per mesh of a stage, or nil; glb node k is then the root of layer k (all STAGE_LAYERS), the meshes its children.
// Mesh k is glb node first_mesh_node + k.
write_model :: proc(root, file: string, meshes: []formats.Mesh, textures: Texture_Files, skeleton: Maybe(formats.Skeleton), matrices: []Maybe([16]f32) = nil, layers: []int = nil, mop: formats.Mop = {}) -> (first_mesh_node: int, ok: bool) {
	context.allocator = context.temp_allocator
	g: gltf.Gltf
	scene: gltf.Scene
	skin: Maybe(int)
	if s, has := skeleton.?; has {
		append(&scene.nodes, ..add_skin(&g, s, max_joint(meshes) + 1)[:])
		add_springs(&g, s, meshes, mop)
		skin = 0
	}
	for layer in 0 ..< (layers != nil ? formats.STAGE_LAYERS : 0) {
		append(&g.nodes, gltf.Node{name = fmt.tprintf("layer_%d", layer)})
		append(&scene.nodes, layer)
	}
	materials := Materials{glb = file, files = textures, by_look = make(map[Material_Look]int)}
	first_mesh_node = len(g.nodes)
	for mesh, mesh_index in meshes {
		out := gltf.Mesh{name = mesh.name}
		for p in mesh.polys {
			if len(p.positions) == 0 do continue  // glTF accessors hold at least one element
			prim := gltf.Primitive{attributes = make(map[string]int)}
			prim.attributes["POSITION"] = gltf.add_accessor(&g, metres(p.positions), "VEC3", gltf.ARRAY_BUFFER, with_bounds = true)
			if p.normals != nil do prim.attributes["NORMAL"] = gltf.add_accessor(&g, unit(p.normals), "VEC3", gltf.ARRAY_BUFFER)
			if p.uvs != nil do prim.attributes["TEXCOORD_0"] = gltf.add_accessor(&g, finite(p.uvs), "VEC2", gltf.ARRAY_BUFFER)
			// (hole part-vertex-color :tags (importer look) :sev polish) fighters' vertex colours are not drawn: their rgb is one constant per primitive (0 or 255) and only alpha varies, use unknown; kept as _TK5_COLOR.
			if p.colors != nil && skin != nil do prim.attributes["_TK5_COLOR"] = gltf.add_accessor(&g, p.colors, "VEC4", gltf.ARRAY_BUFFER)
			if p.colors != nil && skin == nil do prim.attributes["COLOR_0"] = gltf.add_accessor(&g, p.colors, "VEC4", gltf.ARRAY_BUFFER)  // 1.0 = neutral, up to 2
			if skin != nil && p.joints != nil {
				prim.attributes["JOINTS_0"] = gltf.add_accessor(&g, used_joints(p.joints, p.weights), "VEC4", gltf.ARRAY_BUFFER)
				prim.attributes["WEIGHTS_0"] = gltf.add_accessor(&g, normalized(p.weights), "VEC4", gltf.ARRAY_BUFFER)
			}
			prim.indices = gltf.add_accessor(&g, flat(p.triangles), "SCALAR", gltf.ELEMENT_ARRAY_BUFFER)
			if len(p.materials) > 0 do prim.material = material(&g, &materials, p.materials, unlit = p.normals == nil)
			append(&out.primitives, prim)
		}
		append(&g.meshes, out)
		node := gltf.Node{name = mesh.name, mesh = len(g.meshes) - 1, skin = skin}
		if matrices != nil {
			if m, has := matrices[mesh_index].?; has && m != IDENTITY {
				node.transform = make([]f32, 16)
				copy(node.transform, m[:])  // row vectors in file order = column major
				for k in 12 ..< 15 do node.transform[k] /= f32(MM)
			}
		}
		append(&g.nodes, node)
		parent := layers != nil ? &g.nodes[layers[mesh_index]].children : &scene.nodes
		append(parent, len(g.nodes) - 1)
	}
	append(&g.scenes, scene)
	path, _ := filepath.join({root, file})
	return first_mesh_node, gltf.write_glb(&g, path)
}

@(private = "file")
Materials :: struct {
	glb:     string,  // the pack path being written
	files:   Texture_Files,
	by_look: map[Material_Look]int,
}

// What a glTF material is made from: the first pass's base texture, its alpha test, whether its mesh is lit, its reflection.
@(private = "file")
Material_Look :: struct {
	hash:   u32,
	cutoff: f32,   // 0: no alpha test
	keep_below: f32,  // 0: no alpha test
	blend:  bool,  // a blend factor: drawn over what is behind
	additive: bool,  // dst factor 2: added onto what is behind
	unlit:  bool,  // a mesh with no normals (stages): its vertex colours are the baked light
	reflection: Reflection,
}

// A sphere map added onto the base texture, from the camera-to-vertex direction turned by NU_mEnvMap (no normals).
// Only the shaders keyed by these flags read NU_mEnvMap; tk5decomp docs/render.md has the decode.
@(private = "file")
Reflection :: struct {
	hash:        u32,  // the sphere map: the pass's first texture; the second is then the base
	orientation: [16]f32,  // NU_mEnvMap rows as stored
	masked:      bool,  // scaled by the base alpha
}

@(private = "file")
reflection :: proc(pass: formats.Material) -> (out: Reflection, ok: bool) {
	REFLECT_ADDED :: 0x48131011  // acid_rain puddles
	REFLECT_MASKED :: 0x48131003  // acid_rain wet floor
	if pass.flags != REFLECT_ADDED && pass.flags != REFLECT_MASKED || len(pass.textures) < 2 do return
	for property in pass.properties {
		if property.name != "NU_mEnvMap" || len(property.values) != 16 do continue
		copy(out.orientation[:], property.values)
		return {pass.textures[0].hash, out.orientation, pass.flags == REFLECT_MASKED}, true
	}
	return
}

// A pass's alpha test from the GL compare function and ref_alpha: cutoff drops alpha below it (glTF MASK), keep_below
// drops alpha at or above it (OW_materials_alpha_keep_below); 0 for neither.
@(private = "file")
alpha_test :: proc(pass: formats.Material) -> (cutoff, keep_below: f32) {
	GL_LESS :: 1  // GL compare functions, in GL's order from NEVER = 0
	GL_LEQUAL :: 3
	GL_GREATER :: 4
	GL_NOTEQUAL :: 5
	GL_GEQUAL :: 6
	if pass.alpha_test == 0 do return
	switch pass.alpha_function {
	case GL_GEQUAL: cutoff = f32(pass.ref_alpha) / 255  // GEQUAL 0 keeps all: 0, no test
	case GL_GREATER: cutoff = f32(pass.ref_alpha + 1) / 255
	case GL_NOTEQUAL: cutoff = pass.ref_alpha == 0 ? 1.0 / 255 : 0
	case GL_LESS: keep_below = f32(pass.ref_alpha) / 255
	case GL_LEQUAL: keep_below = f32(pass.ref_alpha + 1) / 255
	}
	return
}

// One glTF material per first-pass texture and alpha test; every pass goes to extras as stored, texture hashes included.
// (hole texture-second-layer :tags (importer look)) only a pass's first texture is used; a pass with two (flags 0x41110003, NU_vUVset; kazuya_1 materials 3 and 4) has a blurry highlight map second, likely shine masked by the first texture's alpha.
// (hole stage-reflection-variants :tags (importer render look) :sev polish) reflection shaders 0x48131103 (vertex colour also scales the sphere map) and 0x4813000f, 0x4813010f (four textures) are not decoded: they draw their first texture only.
// (hole stage-white-models :tags (importer render look)) some distant stage models draw pure white; every stage material names a texture and every DDS passes dds.read, so the cause is elsewhere (the texture's content, UVs, or lighting).
@(private = "file")
material :: proc(g: ^gltf.Gltf, materials: ^Materials, passes: []formats.Material, unlit: bool) -> int {
	DST_ONE :: 2  // additive glows; the other factors are not decoded
	cutoff, keep_below := alpha_test(passes[0])
	look := Material_Look{hash = len(passes[0].textures) > 0 ? passes[0].textures[0].hash : 0, cutoff = cutoff, keep_below = keep_below, blend = passes[0].dst_factor != 0, additive = passes[0].dst_factor == DST_ONE, unlit = unlit}
	reflects: bool
	if look.reflection, reflects = reflection(passes[0]); reflects do look.hash = passes[0].textures[1].hash
	if m, seen := materials.by_look[look]; seen do return m
	out: gltf.Material
	out.doubleSided = true
	if file, has := materials.files[look.hash]; has && len(passes[0].textures) > 0 {
		out.pbrMetallicRoughness.baseColorTexture = gltf.Texture_Info{gltf.add_dds_texture(g, gltf.relative_uri(materials.glb, file))}
	}
	extras := make(json.Object)
	if file, has := materials.files[look.reflection.hash]; has && reflects {
		orientation := make(json.Array)
		for value in look.reflection.orientation do append(&orientation, json.Float(value))
		entry := make(json.Object)
		entry["texture"] = json.Integer(gltf.add_dds_texture(g, gltf.relative_uri(materials.glb, file)))
		entry["orientation"] = orientation
		entry["masked"] = json.Boolean(look.reflection.masked)
		extras["reflection"] = entry
	}
	if look.cutoff > 0 {
		out.alphaMode = "MASK"
		out.alphaCutoff = look.cutoff
	}
	// (hole material-blend :tags (render importer look)) dst 2 draws additive (extras blend = "additive"); the other factors (dst 4, 7, 10; src 257, 513) draw as plain alpha blend.
	if look.blend do out.alphaMode = "BLEND"
	if look.unlit do gltf.set_unlit(g, &out)
	if look.keep_below > 0 do gltf.set_keep_below(g, &out, look.keep_below)
	pass_values := make(json.Array)
	for p in passes {
		v, _ := json.marshal(p, allocator = context.temp_allocator)
		parsed, _ := json.parse(v)
		append(&pass_values, parsed)
	}
	extras["tk5_passes"] = pass_values
	if look.additive do extras["blend"] = "additive"
	out.extras = extras
	append(&g.materials, out)
	materials.by_look[look] = len(g.materials) - 1
	return materials.by_look[look]
}

// Joint nodes in bind pose plus the skin. Returns the root nodes. Joints past the skeleton get an identity bind under bone 0.
// (hole helper-joint-re :tags (port fighter-detail)) TK5 SPLJNT block (section 8) and kkhelperjoint (0x1e96c4) are not decoded: twist rules for the helper joints.
@(private = "file")
add_skin :: proc(g: ^gltf.Gltf, s: formats.Skeleton, joints: int) -> (roots: [dynamic]int) {
	bones := len(s.bones)
	world := make([]matrix[4, 4]f64, max(bones, joints))
	copy(world, world_matrices(s))
	parents := make([]int, len(world))
	copy(parents, helper_parents(s, world[:bones]))
	for i in bones ..< len(world) do world[i], parents[i] = 1, 0
	for i in 0 ..< len(world) {
		m := parents[i] < 0 ? world[i] : linalg.inverse(world[parents[i]]) * world[i]
		name := i < bones ? fmt.tprintf("bone%d", i) : fmt.tprintf("mop%d", i)
		node := gltf.Node{name = name, translation = translation_metres(m), rotation = rotation(m)}
		for p, k in parents do if p == i do append(&node.children, k)
		append(&g.nodes, node)
		if parents[i] < 0 do append(&roots, i)
	}
	inverse := make([][16]f32, len(world))
	for w, i in world {
		w := w
		w[0, 3], w[1, 3], w[2, 3] = w[0, 3] / MM, w[1, 3] / MM, w[2, 3] / MM
		inv := linalg.inverse(w)
		for c in 0 ..< 4 do for r in 0 ..< 4 do inverse[i][c * 4 + r] = f32(inv[r, c])  // glTF is column major
	}
	sk := gltf.Skin{inverseBindMatrices = gltf.add_accessor(g, inverse, "MAT4"), skeleton = roots[0]}
	for i in 0 ..< len(world) do append(&sk.joints, i)
	append(&g.skins, sk)
	return roots
}

SWING_FIRST :: 111  // bon bones from here swing; the bon list gives each its MOP record id
SWING_STEPS :: 60.0  // the game steps a swing joint once a tick
MOP_ELLIPSOID :: 1
MOP_CLAMP_TILT :: 0x20
MOP_CLAMP_SWING :: 0x40
MOP_ELLIPSE :: 0x01
CLOTH_WEIGHT :: 0.15  // a vertex counts toward a joint's cloth from this weight
// (hole mop-rope :tags (importer fighter-detail) :sev polish) MOP kind 5 ropes (a pull between two joints) are not mapped; they are weak.

// Each swing joint with a MOP record as a spring of its own, the tail on its +x axis where its cloth is: the game
// steps every joint about its own rest frame, a tree as well as a chain. The game's values are per tick on a 1 m
// lever; the spring's are per second at its tail.
@(private = "file")
add_springs :: proc(g: ^gltf.Gltf, s: formats.Skeleton, meshes: []formats.Mesh, mop: formats.Mop) {
	bones := len(s.bones)
	if bones <= SWING_FIRST || len(s.list) < bones - SWING_FIRST do return
	world := world_matrices(s)
	springs := gltf.Spring_Bone{specVersion = "1.0"}
	group_of := make([]int, len(mop.shapes))
	for shape, index in mop.shapes {
		group_of[index] = -1
		if shape.kind != MOP_ELLIPSOID || int(shape.target) < 0 || int(shape.target) >= bones do continue
		append(&springs.colliders, ellipsoid_collider(shape))
		append(&springs.colliderGroups, gltf.Collider_Group{})
		append(&springs.colliderGroups[len(springs.colliderGroups) - 1].colliders, len(springs.colliders) - 1)
		group_of[index] = len(springs.colliderGroups) - 1
	}
	reach := cloth_reach(meshes, world)
	for bone in SWING_FIRST ..< bones {
		record, has := mop.records[s.list[bone - SWING_FIRST]]
		if !has do continue
		length := reach[bone]
		if length <= 0 do for child in SWING_FIRST ..< bones do if int(s.bones[child].parent) == bone {
			length = f64(s.bones[child].translation.x)
			break
		}
		if length <= 0 do length = f64(record.reach)
		metres := f32(length / MM)
		append(&g.nodes, gltf.Node{name = fmt.tprintf("bone%d_end", bone), translation = slice.clone([]f32{metres, 0, 0})})
		append(&g.nodes[bone].children, len(g.nodes) - 1)
		joint := gltf.Spring_Joint{
			node = bone,
			stiffness = record.stiffness * metres * SWING_STEPS,
			gravityPower = record.gravity / MM * metres * SWING_STEPS,
			dragForce = 1 - record.drag,
			gravityDir = {0, -1, 0},
			extras = swing_limit(record),
		}
		spring := gltf.Spring{}
		append(&spring.joints, joint, gltf.Spring_Joint{node = len(g.nodes) - 1})
		for shape in record.shapes do if int(shape) < len(group_of) && group_of[shape] >= 0 do append(&spring.colliderGroups, group_of[shape])
		append(&springs.springs, spring)
	}
	if len(springs.springs) > 0 do gltf.set_springs(g, springs)
}

@(private = "file")
swing_limit :: proc(record: formats.Mop_Record) -> (limit: gltf.Swing_Limit) {
	if record.flags & MOP_ELLIPSE != 0 {  // high words are 1 / semi-axis, low words the centre
		if record.angle_a[0] == 0 || record.angle_b[0] == 0 do return
		limit.ellipse = gltf.Swing_Ellipse{centre = {record.angle_a[1], record.angle_b[1]}, radius = {1 / record.angle_a[0], 1 / record.angle_b[0]}}
		return
	}
	if record.flags & MOP_CLAMP_TILT != 0 do limit.tilt = [2]f32{record.angle_a[1], record.angle_a[0]}
	if record.flags & MOP_CLAMP_SWING != 0 do limit.swing = [2]f32{record.angle_b[1], record.angle_b[0]}
	return
}

// A MOP ellipsoid on its body bone; the sphere inside it stands in for readers without the extras.
@(private = "file")
ellipsoid_collider :: proc(shape: formats.Mop_Shape) -> gltf.Collider {
	turn := linalg.quaternion_from_matrix3_f32(linalg.matrix3_from_euler_angles_zyx_f32(shape.rotation.z, shape.rotation.y, shape.rotation.x))  // as the bon
	centre, radii := shape.centre / MM, shape.size / MM
	return {
		node = int(shape.target),
		shape = {sphere = gltf.Sphere{offset = centre, radius = min(radii.x, radii.y, radii.z)}},
		extras = gltf.Ellipsoid{offset = centre, radii = radii, rotation = {turn.x, turn.y, turn.z, turn.w}},
	}
}

// Per bone, how far along its +x axis the vertices weighted to it sit (weighted mean), file units; 0 for none.
@(private = "file")
cloth_reach :: proc(meshes: []formats.Mesh, world: []matrix[4, 4]f64) -> []f64 {
	along := make([]f64, len(world))
	total := make([]f64, len(world))
	inverse := make([]matrix[4, 4]f64, len(world))
	for place, bone in world do inverse[bone] = linalg.inverse(place)
	for m in meshes do for p in m.polys do for joints, vertex in p.joints do for k in 0 ..< 4 {
		bone, weight := int(joints[k]), f64(p.weights[vertex][k])
		if weight < CLOTH_WEIGHT || bone >= len(world) do continue
		local := inverse[bone] * [4]f64{f64(p.positions[vertex].x), f64(p.positions[vertex].y), f64(p.positions[vertex].z), 1}
		along[bone] += local.x * weight
		total[bone] += weight
	}
	for &value, bone in along do if total[bone] > 0 do value /= total[bone]
	return along
}

// Bind pose, file units. R = Rz*Ry*Rx (data.md §6.1).
world_matrices :: proc(s: formats.Skeleton) -> []matrix[4, 4]f64 {
	world := make([]matrix[4, 4]f64, len(s.bones))
	for b, i in s.bones {
		e := linalg.Vector3f64{f64(b.euler.x), f64(b.euler.y), f64(b.euler.z)}
		local := linalg.matrix4_from_euler_angles_zyx_f64(e.z, e.y, e.x)
		local[0, 3], local[1, 3], local[2, 3] = f64(b.translation.x), f64(b.translation.y), f64(b.translation.z)
		world[i] = b.parent < 0 ? local : world[b.parent] * local
	}
	return world
}

// Stand-in for kkhelperjoint (not decoded): a helper under a body bone moves to the nearest body bone
// among that bone and its children, so roll joints under the clavicle follow the arm. As export_glb.py.
@(private = "file")
helper_parents :: proc(s: formats.Skeleton, world: []matrix[4, 4]f64) -> []int {
	parents := make([]int, len(s.bones))
	for b, i in s.bones do parents[i] = int(b.parent)
	pos :: proc(m: matrix[4, 4]f64) -> [3]f64 {return {m[0, 3], m[1, 3], m[2, 3]}}
	for h in BODY_BONES ..< min(len(s.bones), SWING_FIRST) {  // swing joints turn about their own parent
		p := parents[h]
		if p < 0 || p >= BODY_BONES do continue
		best, best_d := p, linalg.length(pos(world[h]) - pos(world[p]))
		for k in 0 ..< BODY_BONES {
			if int(s.bones[k].parent) != p do continue
			if d := linalg.length(pos(world[h]) - pos(world[k])); d < best_d do best, best_d = k, d
		}
		parents[h] = best
	}
	return parents
}

@(private = "file")
translation_metres :: proc(m: matrix[4, 4]f64) -> []f32 {
	return slice.clone([]f32{f32(m[0, 3] / MM), f32(m[1, 3] / MM), f32(m[2, 3] / MM)})
}

@(private = "file")
rotation :: proc(m: matrix[4, 4]f64) -> []f32 {
	q := linalg.quaternion_from_matrix4_f64(m)
	return slice.clone([]f32{f32(q.x), f32(q.y), f32(q.z), f32(q.w)})
}

@(private = "file")
metres :: proc(v: [][3]f32) -> [][3]f32 {
	out := make([][3]f32, len(v))
	for p, i in v do out[i] = p / f32(MM)
	return out
}

@(private = "file")
unit :: proc(v: [][3]f32) -> [][3]f32 {
	out := make([][3]f32, len(v))
	for n, i in v do out[i] = n / max(linalg.length(n), 1e-8)
	return out
}

@(private = "file")
normalized :: proc(w: [][4]f32) -> [][4]f32 {
	out := make([][4]f32, len(w))
	for x, i in w do out[i] = x / max(x.x + x.y + x.z + x.w, 1e-6)
	return out
}

// NaN -> 0. Some culling meshes store NaN UVs.
@(private = "file")
finite :: proc(uvs: [][2]f32) -> [][2]f32 {
	out := make([][2]f32, len(uvs))
	for uv, i in uvs do for k in 0 ..< 2 do out[i][k] = math.is_nan(uv[k]) ? 0 : uv[k]
	return out
}

// Highest joint index with a weight.
@(private = "file")
max_joint :: proc(meshes: []formats.Mesh) -> (top: int) {
	for m in meshes do for p in m.polys do for j, i in p.joints do for k in 0 ..< 4 {
		if p.weights[i][k] != 0 do top = max(top, int(j[k]))
	}
	return top
}

IDENTITY :: [16]f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

// Joints with zero weight point at 0; the file leaves stale indices there.
@(private = "file")
used_joints :: proc(joints: [][4]u16, weights: [][4]f32) -> [][4]u16 {
	out := make([][4]u16, len(joints))
	for j, i in joints do for k in 0 ..< 4 do if weights[i][k] != 0 do out[i][k] = j[k]
	return out
}

@(private = "file")
flat :: proc(t: [][3]u16) -> []u16 {
	return (cast([^]u16)raw_data(t))[:3 * len(t)]
}

