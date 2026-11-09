// NDP3 (Namco NUD) meshes, big endian, mm. Layout from Smash Forge NUD.cs; tk5decomp tools/ndp3.py.
package tk5_formats

Material_Texture :: struct {
	hash:                   u32,
	map_mode:               u16,
	wrap_s, wrap_t:         u8,
	min_filter, mag_filter: u8,
	mip_detail:             u8,
}

Material_Property :: struct {
	name:   string,  // NUDef_Diffuse, NU_mEnvMap, ...
	values: []f32,
}

// One render pass. Fields as stored; the glTF writer puts them in extras.
Material :: struct {
	flags:                      u32,
	src_factor, dst_factor:     u16,
	alpha_test, alpha_function: u8,
	ref_alpha, cull_mode:       u16,
	unk_14, unk_18, unk_1c:     u32,
	textures:                   []Material_Texture,
	properties:                 []Material_Property,
}

BLEND_MODES :: 11  // rows of the game's blend table; a pass's dst_factor picks one

// A row of the game's blend table (set by 0x288ae8): GL blend factor and equation enums, alpha left out.
Blend_Mode :: struct {source, equation, destination: u16}

read_blend_modes :: proc(eboot: []byte, build: Build) -> (modes: [BLEND_MODES]Blend_Mode, ok: bool) {
	at := elf_offset(eboot, build.blend_modes) or_return
	if at + 6 * BLEND_MODES > len(eboot) do return
	for &mode, row in modes do mode = {be_u16(eboot, at + 6 * row), be_u16(eboot, at + 6 * row + 2), be_u16(eboot, at + 6 * row + 4)}
	return modes, true
}

Poly :: struct {
	positions: [][3]f32,
	normals:   [][3]f32,  // nil: none stored
	uvs:       [][2]f32,  // first UV set, nil: none
	colors:    [][4]f32,  // 1.0 = neutral: bytes / 128, halves as stored; nil: none
	joints:    [][4]u16,
	weights:   [][4]f32,
	triangles: [][3]u16,
	materials: []Material,  // texprop 1..4
}

Mesh :: struct {
	name:        string,
	single_bind: i16,
	polys:       []Poly,
}

@(private = "file")
Layout :: struct {
	normal_type, bone_type, color_type, uv_count, uv_type: int,
	normal_off, bone_off, vertex_size:                     int,
	color_off, uv_off, uv_size:                            int,
}

@(private = "file")
layout :: proc(vsize, uvsize: u8) -> (l: Layout, ok: bool) {
	l.normal_type, l.bone_type = int(vsize & 0xf), int(vsize & 0xf0)
	l.uv_count, l.color_type, l.uv_type = int(uvsize >> 4), int(uvsize & 0xe), int(uvsize & 1)
	l.normal_off = 12
	switch l.normal_type {  // bytes after the position; normal at normal_off
	case 0: l.vertex_size = 16
	case 1: l.normal_off, l.vertex_size = 16, 32
	case 2, 3: l.normal_off, l.vertex_size = 16, 64
	case 4: l.vertex_size = 16  // stages: 4 bytes, not a normal
	case 6: l.vertex_size = 20
	case 7: l.vertex_size = 36
	case: return {}, false
	}
	l.bone_off = l.vertex_size
	switch l.bone_type {
	case 0:
	case 0x10: l.vertex_size += 32
	case 0x20: l.vertex_size += 16
	case 0x40: l.vertex_size += 8
	case: return {}, false
	}
	switch l.color_type {
	case 0:
	case 2: l.uv_off = 4
	case 4: l.uv_off = 8
	case: return {}, false
	}
	l.uv_size = l.uv_off + l.uv_count * (l.uv_type == 0 ? 4 : 8)
	return l, true
}

@(private = "file")
be_f16 :: proc(b: []byte, off: int) -> f32 {return f32(transmute(f16)be_u16(b, off))}

read_ndp3 :: proc(d: []byte, allocator := context.allocator) -> (meshes: []Mesh, ok: bool) {
	context.allocator = allocator
	if len(d) < 0x30 || string(d[:4]) != "NDP3" do return nil, false
	count := int(be_u16(d, 0x0a))
	poly_base := int(be_i32(d, 0x10)) + 0x30
	vert_base := poly_base + int(be_i32(d, 0x14))
	vadd_base := vert_base + int(be_i32(d, 0x18))
	name_base := vadd_base + int(be_i32(d, 0x1c))

	meshes = make([]Mesh, count)
	off := 0x30
	for &m in meshes {
		m.name = cstring_at(d, name_base + int(be_i32(d, off + 0x20)))
		m.single_bind = be_i16(d, off + 0x28)
		m.polys = make([]Poly, be_u16(d, off + 0x2a))
		off += 0x30
	}
	for &m in meshes {
		for &p in m.polys {
			read_poly(d, off, m.single_bind, poly_base, vert_base, vadd_base, name_base, &p) or_return
			off += 0x30
		}
	}
	return meshes, true
}

@(private = "file")
read_poly :: proc(d: []byte, h: int, single_bind: i16, poly_base, vert_base, vadd_base, name_base: int, p: ^Poly) -> bool {
	n := int(be_u16(d, h + 0x0c))
	l := layout(d[h + 0x0e], d[h + 0x0f]) or_return
	index_count := int(be_u16(d, h + 0x20))
	strip := be_u16(d, h + 0x22) >> 8 == 0

	// Bound polys keep UVs and vertices apart; unbound ones interleave them.
	v_base, v_stride := vert_base + int(be_i32(d, h + 0x04)), l.vertex_size + l.uv_size
	uv_base, uv_stride := v_base + l.vertex_size, v_stride
	if l.bone_type != 0 {
		uv_base, uv_stride = v_base, l.uv_size
		v_base, v_stride = vadd_base + int(be_i32(d, h + 0x08)), l.vertex_size
	}
	if n > 0 && (v_base + (n - 1) * v_stride + l.vertex_size > len(d) || uv_base + (n - 1) * uv_stride + l.uv_size > len(d)) do return false

	p.positions = make([][3]f32, n)
	has_normal := l.normal_type != 0 && l.normal_type != 4
	if has_normal do p.normals = make([][3]f32, n)
	if l.uv_count > 0 do p.uvs = make([][2]f32, n)
	if l.color_type != 0 do p.colors = make([][4]f32, n)
	p.joints = make([][4]u16, n)
	p.weights = make([][4]f32, n)

	for i in 0 ..< n {
		v := v_base + i * v_stride
		for k in 0 ..< 3 do p.positions[i][k] = be_f32(d, v + 4 * k)
		if has_normal {
			for k in 0 ..< 3 {
				p.normals[i][k] = l.normal_type >= 6 ? be_f16(d, v + l.normal_off + 2 * k) : be_f32(d, v + l.normal_off + 4 * k)
			}
		}
		b := v + l.bone_off
		switch l.bone_type {
		case 0x10: for k in 0 ..< 4 do p.joints[i][k], p.weights[i][k] = u16(be_i32(d, b + 4 * k)), be_f32(d, b + 16 + 4 * k)
		case 0x20: for k in 0 ..< 4 do p.joints[i][k], p.weights[i][k] = be_u16(d, b + 2 * k), be_f16(d, b + 8 + 2 * k)
		case 0x40: for k in 0 ..< 4 do p.joints[i][k], p.weights[i][k] = u16(d[b + k]), f32(d[b + 4 + k]) / 255
		case: p.joints[i][0], p.weights[i][0] = u16(max(single_bind, 0)), 1
		}
		u := uv_base + i * uv_stride
		for k in 0 ..< 4 {
			switch l.color_type {
			case 2: p.colors[i][k] = f32(d[u + k]) / 128
			case 4: p.colors[i][k] = be_f16(d, u + 2 * k)
			}
		}
		if l.uv_count > 0 {
			for k in 0 ..< 2 do p.uvs[i][k] = l.uv_type == 0 ? be_f16(d, u + l.uv_off + 2 * k) : be_f32(d, u + l.uv_off + 4 * k)
		}
	}

	idx := poly_base + int(be_i32(d, h))
	if idx + index_count * 2 > len(d) do return false
	tris := make([dynamic][3]u16, 0, index_count)
	if strip {
		flip := false
		for i in 0 ..< max(index_count - 2, 0) {
			a, b, c := be_u16(d, idx + 2 * i), be_u16(d, idx + 2 * i + 2), be_u16(d, idx + 2 * i + 4)
			if a == 0xffff || b == 0xffff || c == 0xffff {
				flip = false
				continue
			}
			if a != b && b != c && a != c do append(&tris, flip ? [3]u16{a, c, b} : [3]u16{a, b, c})
			flip = !flip
		}
	} else {
		for i := 0; i + 3 <= index_count; i += 3 {
			append(&tris, [3]u16{be_u16(d, idx + 2 * i), be_u16(d, idx + 2 * i + 2), be_u16(d, idx + 2 * i + 4)})
		}
	}
	p.triangles = tris[:]

	materials := make([dynamic]Material, 0, 4)
	for k in 0 ..< 4 {
		at := int(be_i32(d, h + 0x10 + 4 * k))
		if at == 0 do continue
		append(&materials, read_material(d, at, name_base) or_return)
	}
	p.materials = materials[:]
	return true
}

@(private = "file")
read_material :: proc(d: []byte, at, name_base: int) -> (m: Material, ok: bool) {
	if at + 0x20 > len(d) do return {}, false
	m = {
		flags          = be_u32(d, at),
		src_factor     = be_u16(d, at + 0x08),
		dst_factor     = be_u16(d, at + 0x0c),
		alpha_test     = d[at + 0x0e],
		alpha_function = d[at + 0x0f],
		ref_alpha      = be_u16(d, at + 0x10),
		cull_mode      = be_u16(d, at + 0x12),
		unk_14         = be_u32(d, at + 0x14),
		unk_18         = be_u32(d, at + 0x18),
		unk_1c         = be_u32(d, at + 0x1c),
	}
	m.textures = make([]Material_Texture, be_u16(d, at + 0x0a))
	for &t, i in m.textures {
		r := at + 0x20 + 0x18 * i
		if r + 0x18 > len(d) do return {}, false
		t = {be_u32(d, r), be_u16(d, r + 0x0a), d[r + 0x0c], d[r + 0x0d], d[r + 0x0e], d[r + 0x0f], d[r + 0x10]}
	}
	props := make([dynamic]Material_Property)
	r := at + 0x20 + 0x18 * len(m.textures)
	for {
		if r + 0x10 > len(d) do return {}, false
		size, count := int(be_u32(d, r)), int(be_u32(d, r + 0x08))
		if r + 0x10 + 4 * count > len(d) do return {}, false
		values := make([]f32, count)
		for &v, k in values do v = be_f32(d, r + 0x10 + 4 * k)
		append(&props, Material_Property{cstring_at(d, name_base + int(be_u32(d, r + 4))), values})
		if size == 0 do break
		r += size
	}
	m.properties = props[:]
	return m, true
}
