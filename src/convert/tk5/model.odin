// Character parts and stage scenes as glb: skinned meshes, PNG textures, metres, Y up.
package tk5_convert

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "../../convert"
import formats "../../formats/tk5"

BODY_BONES :: 23  // animated by the 23 channels; the rest are helpers

Textures :: map[u32]formats.Texture  // by hash, MIF placeholders already resolved

// skeleton: nil for unskinned (stage) geometry. matrices: per mesh, row vectors in file units, or nil.
write_model :: proc(path: string, meshes: []formats.Mesh, textures: Textures, skeleton: Maybe(formats.Skeleton), matrices: []Maybe([16]f32) = nil) -> (ok: bool) {
	context.allocator = context.temp_allocator
	g: convert.Gltf
	scene: convert.Scene
	skin: Maybe(int)
	if s, has := skeleton.?; has {
		append(&scene.nodes, ..add_skin(&g, s, max_joint(meshes) + 1)[:])
		skin = 0
	}
	materials := make(map[u32]int)
	for mesh, mesh_index in meshes {
		out := convert.Mesh{name = mesh.name}
		for p in mesh.polys {
			prim := convert.Primitive{attributes = make(map[string]int)}
			prim.attributes["POSITION"] = convert.add_accessor(&g, metres(p.positions), "VEC3", convert.ARRAY_BUFFER, with_bounds = true)
			if p.normals != nil do prim.attributes["NORMAL"] = convert.add_accessor(&g, unit(p.normals), "VEC3", convert.ARRAY_BUFFER)
			if p.uvs != nil do prim.attributes["TEXCOORD_0"] = convert.add_accessor(&g, finite(p.uvs), "VEC2", convert.ARRAY_BUFFER)
			if p.colors != nil do prim.attributes["_COLOR"] = convert.add_accessor(&g, p.colors, "VEC4", convert.ARRAY_BUFFER)  // 1.0 = neutral, can exceed 1
			if skin != nil && p.joints != nil {
				prim.attributes["JOINTS_0"] = convert.add_accessor(&g, used_joints(p.joints, p.weights), "VEC4", convert.ARRAY_BUFFER)
				prim.attributes["WEIGHTS_0"] = convert.add_accessor(&g, normalized(p.weights), "VEC4", convert.ARRAY_BUFFER)
			}
			prim.indices = convert.add_accessor(&g, flat(p.triangles), "SCALAR", convert.ELEMENT_ARRAY_BUFFER)
			if len(p.materials) > 0 do prim.material = material(&g, &materials, textures, p.materials)
			append(&out.primitives, prim)
		}
		append(&g.meshes, out)
		node := convert.Node{name = mesh.name, mesh = len(g.meshes) - 1, skin = skin}
		if matrices != nil {
			if m, has := matrices[mesh_index].?; has && m != IDENTITY {
				node.transform = make([]f32, 16)
				copy(node.transform, m[:])  // row vectors in file order = column major
				for k in 12 ..< 15 do node.transform[k] /= f32(MM)
			}
		}
		append(&g.nodes, node)
		append(&scene.nodes, len(g.nodes) - 1)
	}
	append(&g.scenes, scene)
	return convert.write_glb(&g, path)
}

// One glTF material per first-pass texture; every pass goes to extras as stored.
@(private = "file")
material :: proc(g: ^convert.Gltf, cache: ^map[u32]int, textures: Textures, passes: []formats.Material) -> int {
	hash: u32 = len(passes[0].textures) > 0 ? passes[0].textures[0].hash : 0
	if m, seen := cache[hash]; seen do return m
	out: convert.Material
	out.doubleSided = true
	if t, has := textures[hash]; has {
		rgba, decoded := formats.decode_rgba(t, context.temp_allocator)
		if decoded {
			out.pbrMetallicRoughness.baseColorTexture = convert.Texture_Ref{convert.add_png(g, fmt.tprintf("%08x", hash), convert.encode_png(rgba, t.width, t.height))}
			// (hole texture-alpha-re :tags importer) any texel alpha < 128 makes the material cut-out; some costume textures (kazuya pants) use alpha for something else, likely a colour mask, and draw see-through.
			for i := 3; i < len(rgba); i += 4 do if rgba[i] < 128 {out.alphaMode = "MASK"; break}
		}
	}
	extras := make(json.Object)
	pass_values := make(json.Array)
	for p in passes {
		v, _ := json.marshal(p, allocator = context.temp_allocator)
		parsed, _ := json.parse(v)
		append(&pass_values, parsed)
	}
	extras["tk5_passes"] = pass_values
	out.extras = extras
	append(&g.materials, out)
	cache[hash] = len(g.materials) - 1
	return cache[hash]
}

// Joint nodes in bind pose plus the skin. Returns the root nodes.
// (hole helper-joint-re :tags port) TK5 SPLJNT block (section 8) and kkhelperjoint (0x1e96c4) are not decoded: twist rules and swing params (king tail, kazuya belt ends) for the helper and costume joints.
// (hole mop-joints :tags importer :needs helper-joint-re) costume joints past the skeleton (MOP, model section 13) get an identity bind under bone 0; cloth does not animate.
@(private = "file")
add_skin :: proc(g: ^convert.Gltf, s: formats.Skeleton, joints: int) -> (roots: [dynamic]int) {
	bones := len(s.bones)
	world := make([]matrix[4, 4]f64, max(bones, joints))
	copy(world, world_matrices(s))
	parents := make([]int, len(world))
	copy(parents, helper_parents(s, world[:bones]))
	for i in bones ..< len(world) do world[i], parents[i] = 1, 0
	for i in 0 ..< len(world) {
		m := parents[i] < 0 ? world[i] : linalg.inverse(world[parents[i]]) * world[i]
		name := i < bones ? fmt.tprintf("bone%d", i) : fmt.tprintf("mop%d", i)
		node := convert.Node{name = name, translation = translation_metres(m), rotation = rotation(m)}
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
	sk := convert.Skin{inverseBindMatrices = convert.add_accessor(g, inverse, "MAT4"), skeleton = roots[0]}
	for i in 0 ..< len(world) do append(&sk.joints, i)
	append(&g.skins, sk)
	return roots
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

