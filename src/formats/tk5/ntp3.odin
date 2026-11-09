// NTP3 (Namco NUT) textures, version 0x0100, big endian. Layout from Smash Forge NUT.cs; tk5decomp tools/ntp3.py.
// The game uses DXT5 only; DXT1, DXT3 and ARGB8 decode too. MIF maps 0x104n placeholders to 0x001n frames.
package tk5_formats

import "core:strings"

Texture :: struct {
	hash:          u32,
	width, height: int,
	format:        u8,     // 0 DXT1, 1 DXT3, 2 DXT5, 14/17 ARGB8
	data:          []byte, // top mip
}

// `d` is an NTP3 section; an LZ one (starts ff "NTP3") goes through unlz first.
read_ntp3 :: proc(d: []byte, allocator := context.allocator) -> (textures: []Texture, ok: bool) {
	if len(d) < 0x10 || string(d[:4]) != "NTP3" || be_u16(d, 4) >= 0x200 do return nil, false
	textures = make([]Texture, be_u16(d, 6), allocator)
	h := 0x10
	for &t in textures {
		if h + 0x30 > len(d) do return nil, false
		total, data_size, header_size := int(be_i32(d, h)), int(be_i32(d, h + 8)), int(be_u16(d, h + 0x0c))
		mips := d[h + 0x11]
		mip0 := mips == 1 ? data_size : int(be_i32(d, h + 0x30))
		gidx := -1
		for i := h; i + 12 <= min(h + header_size, len(d)); i += 1 {
			if string(d[i:][:4]) == "GIDX" {gidx = i; break}
		}
		if gidx < 0 || h + header_size + mip0 > len(d) do return nil, false
		t = {
			hash   = be_u32(d, gidx + 8),
			width  = int(be_u16(d, h + 0x14)),
			height = int(be_u16(d, h + 0x16)),
			format = d[h + 0x13],
			data   = d[h + header_size:][:mip0],
		}
		h += total
	}
	return textures, true
}

// MIF section, LE words: a placeholder 0x104nxxxx followed by its frame 0 0x001nxxxx. First pair wins.
read_mif_swaps :: proc(section: []byte, swaps: ^map[u32]u32) -> (ok: bool) {
	if len(section) < 4 || string(section[:4]) != "MIF\x00" do return false
	for i := 0; i + 8 <= len(section) & ~int(3); i += 4 {
		a, b := le_u32(section, i), le_u32(section, i + 4)
		if a >> 20 == 0x104 && b >> 20 == 0x001 && a not_in swaps do swaps[a] = b
	}
	return true
}

// One entry of a costume's CHARMOTHS block: the meshes (NDP3 mesh indices) a move set shows. The first entry, move set
// MOVESET_EVERYONE, lists the meshes hidden by default (Mokujin's sword and tail). The game applies it at 0x1382e8.
Moveset_Meshes :: struct {
	moveset: int,
	meshes:  []u8,
}

MOVESET_EVERYONE :: -1

// The CHARMOTHS block of a MIF section; none when it has no block.
read_mif_moveset_meshes :: proc(section: []byte, allocator := context.allocator) -> (entries: []Moveset_Meshes, ok: bool) {
	BLOCK_DATA :: 0x10  // from the block name: name, version, size
	name := strings.index(string(section), "CHARMOTHS\x00")
	if name < 0 do return nil, true
	at := name + BLOCK_DATA
	if at >= len(section) do return
	list := make([dynamic]Moveset_Meshes, allocator)
	count := int(section[at])
	at += 1
	for _ in 0 ..< count {
		if at + 2 > len(section) do return
		moveset, mesh_count := int(i8(section[at])), int(section[at + 1])
		at += 2
		if at + mesh_count > len(section) do return
		append(&list, Moveset_Meshes{moveset, section[at:][:mesh_count]})
		at += mesh_count
	}
	return list[:], true
}

decode_rgba :: proc(t: Texture, allocator := context.allocator) -> (rgba: []byte, ok: bool) {
	w, h := t.width, t.height
	block_size: int
	switch t.format {
	case 0: block_size = 8
	case 1, 2: block_size = 16
	case 14, 17:
		if len(t.data) < w * h * 4 do return nil, false
		rgba = make([]byte, w * h * 4, allocator)
		for i in 0 ..< w * h do rgba[4 * i + 0], rgba[4 * i + 1], rgba[4 * i + 2], rgba[4 * i + 3] = t.data[4 * i + 1], t.data[4 * i + 2], t.data[4 * i + 3], t.data[4 * i]
		return rgba, true
	case: return nil, false
	}
	bw, bh := (w + 3) / 4, (h + 3) / 4
	if len(t.data) < bw * bh * block_size do return nil, false
	rgba = make([]byte, w * h * 4, allocator)
	for by in 0 ..< bh {
		for bx in 0 ..< bw {
			block := t.data[(by * bw + bx) * block_size:][:block_size]
			px: [16][4]u8
			switch t.format {
			case 0: decode_bc1(block, &px)
			case 1: decode_bc1(block[8:], &px); decode_bc2_alpha(block, &px)
			case 2: decode_bc1(block[8:], &px); decode_bc3_alpha(block, &px)
			}
			for i in 0 ..< 16 {
				x, y := bx * 4 + i % 4, by * 4 + i / 4
				if x < w && y < h do copy(rgba[(y * w + x) * 4:][:4], px[i][:])
			}
		}
	}
	return rgba, true
}

// Integer rounding as texture2ddecoder (AssetStudio bcn.cpp), so the RGBA matches ntp3.py.
@(private = "file")
decode_bc1 :: proc(b: []byte, px: ^[16][4]u8) {
	rgb565 :: proc(v: u16) -> [3]int {
		return {int((v >> 8 & 0xf8) | (v >> 13)), int((v >> 3 & 0xfc) | (v >> 9 & 3)), int(u8(v << 3) | u8(v >> 2 & 7))}
	}
	q0, q1 := le_u16(b, 0), le_u16(b, 2)
	c0, c1 := rgb565(q0), rgb565(q1)
	c: [4][3]int = {c0, c1, {}, {}}
	if q0 > q1 {
		c[2] = (c0 * 2 + c1) / 3
		c[3] = (c0 + c1 * 2) / 3
	} else {
		c[2] = (c0 + c1) / 2
	}
	bits := le_u32(b, 4)
	for i in 0 ..< 16 {
		k := c[bits >> uint(2 * i) & 3]
		px[i] = {u8(k[0]), u8(k[1]), u8(k[2]), 255}
	}
}

@(private = "file")
decode_bc2_alpha :: proc(b: []byte, px: ^[16][4]u8) {
	for i in 0 ..< 16 do px[i][3] = (b[i / 2] >> uint(4 * (i % 2)) & 0xf) * 17
}

@(private = "file")
decode_bc3_alpha :: proc(b: []byte, px: ^[16][4]u8) {
	a: [8]int = {int(b[0]), int(b[1]), 0, 0, 0, 0, 0, 0}
	if a[0] > a[1] {
		for k in 2 ..< 8 do a[k] = (a[0] * (8 - k) + a[1] * (k - 1)) / 7
	} else {
		for k in 2 ..< 6 do a[k] = (a[0] * (6 - k) + a[1] * (k - 1)) / 5
		a[7] = 255
	}
	bits := u64(b[2]) | u64(b[3]) << 8 | u64(b[4]) << 16 | u64(b[5]) << 24 | u64(b[6]) << 32 | u64(b[7]) << 40
	for i in 0 ..< 16 do px[i][3] = u8(a[bits >> uint(3 * i) & 7])
}
