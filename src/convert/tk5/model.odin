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

// Writes root/file. skeleton: nil for unskinned (stage) geometry. matrices: per mesh, row vectors in file units, or nil.
// layers: per mesh of a stage, or nil; glb node k is then the root of layer k (all STAGE_LAYERS), the meshes its children.
write_model :: proc(root, file: string, meshes: []formats.Mesh, textures: Texture_Files, skeleton: Maybe(formats.Skeleton), matrices: []Maybe([16]f32) = nil, layers: []int = nil) -> (ok: bool) {
	context.allocator = context.temp_allocator
	g: gltf.Gltf
	scene: gltf.Scene
	skin: Maybe(int)
	if s, has := skeleton.?; has {
		append(&scene.nodes, ..add_skin(&g, s, max_joint(meshes) + 1)[:])
		add_springs(&g, s, meshes)
		skin = 0
	}
	for layer in 0 ..< (layers != nil ? formats.STAGE_LAYERS : 0) {
		append(&g.nodes, gltf.Node{name = fmt.tprintf("layer_%d", layer)})
		append(&scene.nodes, layer)
	}
	materials := Materials{glb = file, files = textures, by_look = make(map[Material_Look]int)}
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
	return gltf.write_glb(&g, path)
}

@(private = "file")
Materials :: struct {
	glb:     string,  // the pack path being written
	files:   Texture_Files,
	by_look: map[Material_Look]int,
}

// What a glTF material is made from: the first pass's first texture, its alpha test, and whether its mesh is lit.
@(private = "file")
Material_Look :: struct {
	hash:   u32,
	cutoff: f32,   // 0: no alpha test
	blend:  bool,  // a blend factor: drawn over what is behind
	additive: bool,  // dst factor 2: added onto what is behind
	unlit:  bool,  // a mesh with no normals (stages): its vertex colours are the baked light
}

// A pass's alpha test as a glTF cutoff (drop alpha below it), from the GL compare function and ref_alpha; 0 when it has
// none or keeps alpha below ref (LESS), which glTF can not say.
@(private = "file")
alpha_cutoff :: proc(pass: formats.Material) -> f32 {
	GL_GREATER :: 4  // GL compare functions, in GL's order from NEVER = 0
	GL_NOTEQUAL :: 5
	GL_GEQUAL :: 6
	if pass.alpha_test == 0 do return 0
	switch pass.alpha_function {
	case GL_GEQUAL: return f32(pass.ref_alpha) / 255  // GEQUAL 0 keeps all: 0, no test
	case GL_GREATER: return f32(pass.ref_alpha + 1) / 255
	case GL_NOTEQUAL: return pass.ref_alpha == 0 ? 1.0 / 255 : 0
	}
	return 0
}

// One glTF material per first-pass texture and alpha test; every pass goes to extras as stored, texture hashes included.
// (hole texture-second-layer :tags (importer look)) only a pass's first texture is used; a pass with two (flags 0x41110003, NU_vUVset; kazuya_1 materials 3 and 4) has a blurry highlight map second, likely shine masked by the first texture's alpha.
// (hole stage-white-models :tags (importer render look)) some distant stage models draw pure white; every stage material names a texture and every DDS passes dds.read, so the cause is elsewhere (the texture's content, UVs, or lighting).
@(private = "file")
material :: proc(g: ^gltf.Gltf, materials: ^Materials, passes: []formats.Material, unlit: bool) -> int {
	DST_ONE :: 2  // additive glows; the other factors are not decoded
	look := Material_Look{hash = len(passes[0].textures) > 0 ? passes[0].textures[0].hash : 0, cutoff = alpha_cutoff(passes[0]), blend = passes[0].dst_factor != 0, additive = passes[0].dst_factor == DST_ONE, unlit = unlit}
	if m, seen := materials.by_look[look]; seen do return m
	out: gltf.Material
	out.doubleSided = true
	if file, has := materials.files[look.hash]; has && len(passes[0].textures) > 0 {
		out.pbrMetallicRoughness.baseColorTexture = gltf.Texture_Info{gltf.add_dds_texture(g, gltf.relative_uri(materials.glb, file))}
	}
	if look.cutoff > 0 {
		out.alphaMode = "MASK"
		out.alphaCutoff = look.cutoff
	}
	// (hole material-blend :tags (render importer look)) dst 2 draws additive (extras blend = "additive"); the other factors (dst 4, 7, 10; src 257, 513) draw as plain alpha blend.
	if look.blend do out.alphaMode = "BLEND"
	if look.unlit do gltf.set_unlit(g, &out)
	extras := make(json.Object)
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

SWING_FIRST :: 111  // bon bones from here swing: tails, straps, belt ends; the bon list gives each its MOP id
LEG_BONES :: [4]int{15, 16, 18, 19}  // thighs and shins; the bone after each is its end
FIRST_LEG_BONE :: 15  // legs to the body's end, then helpers
LEG_RADIUS :: 0.08  // metres
// (hole mop-swing :tags (importer fighter-detail)) MOP (model section 13) is not mapped: every chain swings with these.
SWING_STIFFNESS :: 1.0
SWING_GRAVITY :: 0.1
SWING_DRAG :: 0.35
SWING_HIT_RADIUS :: 0.02

// Each chain of swing bones as a spring, with a tail node at the farthest vertex of its last bone, kept out of the
// legs but the one it hangs from. A lone bone on a leg or a helper is a pant leg or cuff: it follows its parent.
@(private = "file")
add_springs :: proc(g: ^gltf.Gltf, s: formats.Skeleton, meshes: []formats.Mesh) {
	bones := len(s.bones)
	if bones <= SWING_FIRST do return
	world := world_matrices(s)
	springs := gltf.Spring_Bone{specVersion = "1.0"}
	for leg, group in LEG_BONES {
		end := linalg.inverse(world[leg]) * world[leg + 1]
		tail := [3]f32{f32(end[0, 3] / MM), f32(end[1, 3] / MM), f32(end[2, 3] / MM)}
		append(&springs.colliders, gltf.Collider{node = leg, shape = {capsule = gltf.Capsule{tail = tail, radius = LEG_RADIUS}}})
		append(&springs.colliderGroups, gltf.Collider_Group{})
		append(&springs.colliderGroups[group].colliders, group)
	}
	ends := farthest_vertices(meshes, world)
	next :: proc(s: formats.Skeleton, bone: int) -> int {
		for b, child in s.bones[SWING_FIRST:] do if int(b.parent) == bone do return SWING_FIRST + child
		return -1
	}
	for first in SWING_FIRST ..< bones {
		parent := int(s.bones[first].parent)
		if parent >= SWING_FIRST && next(s, parent) == first do continue  // inside a chain
		spring: gltf.Spring
		for leg, group in LEG_BONES do if leg != parent do append(&spring.colliderGroups, group)
		if next(s, first) < 0 && parent >= FIRST_LEG_BONE do continue
		last := first
		for bone := first; bone >= 0; bone = next(s, bone) {
			append(&spring.joints, swing_joint(bone))
			last = bone
		}
		if end, found := ends[last].?; found {
			local := linalg.inverse(world[last]) * [4]f64{end.x, end.y, end.z, 1}
			append(&g.nodes, gltf.Node{name = fmt.tprintf("bone%d_end", last), translation = slice.clone([]f32{f32(local.x / MM), f32(local.y / MM), f32(local.z / MM)})})
			append(&g.nodes[last].children, len(g.nodes) - 1)
			append(&spring.joints, swing_joint(len(g.nodes) - 1))
		}
		if len(spring.joints) > 1 do append(&springs.springs, spring)
	}
	if len(springs.springs) > 0 do gltf.set_springs(g, springs)
}

@(private = "file")
swing_joint :: proc(node: int) -> gltf.Spring_Joint {
	return {node = node, hitRadius = SWING_HIT_RADIUS, stiffness = SWING_STIFFNESS, gravityPower = SWING_GRAVITY, dragForce = SWING_DRAG, gravityDir = {0, -1, 0}}
}

// Per bone, the vertex mostly on it farthest from it, file units; none for a bone no vertex is mostly on.
@(private = "file")
farthest_vertices :: proc(meshes: []formats.Mesh, world: []matrix[4, 4]f64) -> []Maybe([3]f64) {
	ends := make([]Maybe([3]f64), len(world))
	reach := make([]f64, len(world))
	for m in meshes do for p in m.polys do for joints, vertex in p.joints do for k in 0 ..< 4 {
		bone := int(joints[k])
		if p.weights[vertex][k] < 0.5 || bone >= len(world) do continue
		position := [3]f64{f64(p.positions[vertex].x), f64(p.positions[vertex].y), f64(p.positions[vertex].z)}
		if d := linalg.length(position - [3]f64{world[bone][0, 3], world[bone][1, 3], world[bone][2, 3]}); d > reach[bone] {
			reach[bone], ends[bone] = d, position
		}
	}
	return ends
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
	for h in BODY_BONES ..< len(s.bones) {
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

