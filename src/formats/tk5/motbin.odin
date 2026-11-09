// Moveset (motbin), big endian: 0x274-byte header, then tables. data.md §4, code-map.md.
// Records stay at their game index. Index fields point into other tables; lists run to an end marker.
package tk5_formats

import "core:unicode/utf16"

MOTBIN_BASE :: 0x274  // header offsets are relative to the end of the header
ALIAS_COUNT :: 37

Motbin :: struct {
	char_id:                        u16,
	name, creator, date, full_date: string,  // raw bytes, SJIS
	aliases:                        [ALIAS_COUNT]u32,  // move id 0x8000+n -> aliases[n]
	unk_140:                        []byte,  // header 0x140..0x188
	bank_offsets:                   [6]int,  // embedded mota banks, from the start of the data

	reactions:       []Reaction,
	requirements:    []Requirement,     // list ends at id 0x147
	hit_conditions:  []Hit_Condition,   // list ends at a row whose requirement list is only 0x147 [likely: 36 starts break it]
	pushbacks:       []Pushback,
	pushback_extras: []u16,             // list length: pushback.unk_04 [guess]
	cancels:         []Cancel,          // list ends at command high half 0x8000
	group_cancels:   []Cancel,          // list ends at command high half 0x8006 (return)
	cancel_extras:   []u32,
	extra_props:     []Extra_Prop,      // list ends at a zero row
	start_props:     []Prop,            // list ends at a zero row [likely]
	end_props:       []Prop,            // list ends at a zero row [likely, no data]
	moves:           []Move,
	voiceclips:      []u16,             // list ends at 0xffff
	input_sequences: []Input_Sequence,
	input_extras:    []Input_Extra,     // list length: input_sequence.unk_02 [guess]
	move_pool:       []u16,             // list ends at 0
	command_list:    []Command_List_Entry,
	unknown_tables:  []Unknown_Table,
}

Reaction :: struct {
	pushbacks:         [7]u32,  // pushback idx
	unk_1c:            [10]u16,
	vertical_pushback: u16,
	unk_32:            u16,
	move_standing, move_crouch, move_counter, move_crouch_counter: u16,
	move_left, move_left_crouch, move_right, move_right_crouch:    u16,
	move_back, move_back_crouch, move_block, move_crouch_block:    u16,
	move_wall_slump, move_down:                                     u16,
}

Requirement :: struct {
	id, param: u16,
}

Hit_Condition :: struct {
	requirements: u32,  // requirement list
	damage:       u16,
	unk_06:       u16,
	reaction:     u32,
}

Pushback :: struct {
	unk_00, unk_02, unk_04, unk_06: u16,
	extras:                         u32,  // pushback_extra list
}

// 0x8000xxxx ends a list; 0x8005xxxx jumps to group_cancels[move], 0x8006 returns; >= 0x8007 input_sequences[hi - 0x8007].
Cancel :: struct {
	command:      u32,
	requirements: u32,  // requirement list
	move:         u16,
	unk_0a:       u16,
	extra:        u32,  // cancel_extra idx
	window_start: u16,
	window_end:   u16,
	start_frame:  u16,
	option:       u16,
}

Extra_Prop :: struct {
	unk_00, unk_02: u16,
	unk_04:         u32,
}

Prop :: struct {
	requirements: u32,
	unk_04:       u32,
}

Move :: struct {
	name, anim_name: string,  // raw bytes
	anim:            u32,     // 0x4000: character bank 0, else 0x8000: common bank, else embedded bank 0; low 14 bits index
	vuln:            u32,
	hit_level:       u32,
	cancels:         u32,  // cancel list
	transition:      u16,
	unk_1a:          u16,
	unk_1c:          u32,
	hit_conditions:  u32,  // hit_condition list
	unk_24:          u16,  // anim length, 0 in the file; the loader fills it
	unk_26:          u16,
	unk_28:          u32,
	voiceclips:      i32,  // -1: none
	extra_props:     i32,
	start_props:     i32,
	end_props:       i32,
	flags:           u32,  // as stored, before the loader permutes the bits
	hit_category:    u32,  // 4 category bytes
	active_first:    u16,
	active_last:     u16,
	unk_48:          u32,
}

Input_Sequence :: struct {
	unk_00, unk_02: u16,
	inputs:         u32,  // input_extra list
}

Input_Extra :: struct {
	unk_00, unk_02: u16,
}

// Pause menu entry. Strings are UTF-8 (UTF-16 BE in the file), button glyphs in U+E0xx.
Command_List_Entry :: struct {
	name_ja, name_en, name_ja2: string,
	commands:                   [8]string,
	unk_2c:                     [4]u32,
}

// Header 0x208..0x238 tables that are not decoded: the bytes up to the next table.
Unknown_Table :: struct {
	header: int,
	count:  int,
	data:   []byte,
}

UNKNOWN_TABLE_HEADERS :: [?]int{0x208, 0x210, 0x220, 0x228, 0x230, 0x238}

// Strings and unknown tables point into `data`.
// Embedded bank `slot` of an unpacked motbin; not ok for an empty slot (type word 0).
embedded_bank :: proc(m: Motbin, data: []byte, slot: int) -> (bank: []byte, ok: bool) {
	start := m.bank_offsets[slot]
	if start + 2 > len(data) || le_u16(data, start) == 0 do return
	return data[start:], true
}

read_motbin :: proc(data: []byte, allocator := context.allocator) -> (m: Motbin, ok: bool) {
	context.allocator = allocator
	d := data
	if len(d) < MOTBIN_BASE || string(d[4:7]) != "COM" do return {}, false

	m.char_id = be_u16(d, 0)
	m.name = motbin_string(d, be_u32(d, 0x08)) or_return
	m.creator = motbin_string(d, be_u32(d, 0x0c)) or_return
	m.date = motbin_string(d, be_u32(d, 0x10)) or_return
	m.full_date = motbin_string(d, be_u32(d, 0x14)) or_return
	for &a, i in m.aliases do a = be_u32(d, 0x18 + i * 4)
	m.unk_140 = d[0x140:0x188]
	for &b, i in m.bank_offsets do b = MOTBIN_BASE + int(be_u32(d, 0x240 + i * 8))

	r: []byte
	r = table(d, 0x188, 0x50, &m.reactions) or_return
	for &x, i in m.reactions {
		b := r[i * 0x50:]
		for &p, j in x.pushbacks do p = be_u32(b, j * 4)
		for &u, j in x.unk_1c do u = be_u16(b, 0x1c + j * 2)
		x.vertical_pushback, x.unk_32 = be_u16(b, 0x30), be_u16(b, 0x32)
		moves := [14]^u16{
			&x.move_standing, &x.move_crouch, &x.move_counter, &x.move_crouch_counter,
			&x.move_left, &x.move_left_crouch, &x.move_right, &x.move_right_crouch,
			&x.move_back, &x.move_back_crouch, &x.move_block, &x.move_crouch_block,
			&x.move_wall_slump, &x.move_down,
		}
		for p, j in moves do p^ = be_u16(b, 0x34 + j * 2)
	}

	r = table(d, 0x190, 4, &m.requirements) or_return
	for &x, i in m.requirements do x = {be_u16(r, i * 4), be_u16(r, i * 4 + 2)}

	r = table(d, 0x198, 0xc, &m.hit_conditions) or_return
	for &x, i in m.hit_conditions {
		b := r[i * 0xc:]
		x = {be_u32(b, 0), be_u16(b, 4), be_u16(b, 6), be_u32(b, 8)}
	}

	r = table(d, 0x1a0, 0xc, &m.pushbacks) or_return
	for &x, i in m.pushbacks {
		b := r[i * 0xc:]
		x = {be_u16(b, 0), be_u16(b, 2), be_u16(b, 4), be_u16(b, 6), be_u32(b, 8)}
	}

	r = table(d, 0x1a8, 2, &m.pushback_extras) or_return
	for &x, i in m.pushback_extras do x = be_u16(r, i * 2)

	r = table(d, 0x1b0, 0x18, &m.cancels) or_return
	for &x, i in m.cancels do x = read_cancel(r[i * 0x18:])
	r = table(d, 0x1b8, 0x18, &m.group_cancels) or_return
	for &x, i in m.group_cancels do x = read_cancel(r[i * 0x18:])

	r = table(d, 0x1c0, 4, &m.cancel_extras) or_return
	for &x, i in m.cancel_extras do x = be_u32(r, i * 4)

	r = table(d, 0x1c8, 8, &m.extra_props) or_return
	for &x, i in m.extra_props do x = {be_u16(r, i * 8), be_u16(r, i * 8 + 2), be_u32(r, i * 8 + 4)}
	r = table(d, 0x1d0, 8, &m.start_props) or_return
	for &x, i in m.start_props do x = {be_u32(r, i * 8), be_u32(r, i * 8 + 4)}
	r = table(d, 0x1d8, 8, &m.end_props) or_return
	for &x, i in m.end_props do x = {be_u32(r, i * 8), be_u32(r, i * 8 + 4)}

	r = table(d, 0x1e0, 0x4c, &m.moves) or_return
	for &x, i in m.moves {
		b := r[i * 0x4c:]
		x = {
			anim = be_u32(b, 0x08), vuln = be_u32(b, 0x0c), hit_level = be_u32(b, 0x10),
			cancels = be_u32(b, 0x14), transition = be_u16(b, 0x18), unk_1a = be_u16(b, 0x1a),
			unk_1c = be_u32(b, 0x1c), hit_conditions = be_u32(b, 0x20), unk_24 = be_u16(b, 0x24),
			unk_26 = be_u16(b, 0x26), unk_28 = be_u32(b, 0x28), voiceclips = be_i32(b, 0x2c),
			extra_props = be_i32(b, 0x30), start_props = be_i32(b, 0x34), end_props = be_i32(b, 0x38),
			flags = be_u32(b, 0x3c), hit_category = be_u32(b, 0x40), active_first = be_u16(b, 0x44),
			active_last = be_u16(b, 0x46), unk_48 = be_u32(b, 0x48),
		}
		x.name = motbin_string(d, be_u32(b, 0x00)) or_return
		x.anim_name = motbin_string(d, be_u32(b, 0x04)) or_return
	}

	r = table(d, 0x1e8, 2, &m.voiceclips) or_return
	for &x, i in m.voiceclips do x = be_u16(r, i * 2)

	r = table(d, 0x1f0, 8, &m.input_sequences) or_return
	for &x, i in m.input_sequences do x = {be_u16(r, i * 8), be_u16(r, i * 8 + 2), be_u32(r, i * 8 + 4)}
	r = table(d, 0x1f8, 4, &m.input_extras) or_return
	for &x, i in m.input_extras do x = {be_u16(r, i * 4), be_u16(r, i * 4 + 2)}

	r = table(d, 0x200, 2, &m.move_pool) or_return
	for &x, i in m.move_pool do x = be_u16(r, i * 2)

	r = table(d, 0x218, 0x3c, &m.command_list) or_return
	for &x, i in m.command_list {
		b := r[i * 0x3c:]
		text: [11]string
		for &s, j in text do s = motbin_wstring(d, be_u32(b, j * 4)) or_return
		x.name_ja, x.name_en, x.name_ja2 = text[0], text[1], text[2]
		copy(x.commands[:], text[3:])
		for &u, j in x.unk_2c do u = be_u32(b, 0x2c + j * 4)
	}

	m.unknown_tables = make([]Unknown_Table, len(UNKNOWN_TABLE_HEADERS))
	for h, i in UNKNOWN_TABLE_HEADERS {
		start, count := MOTBIN_BASE + int(be_u32(d, h)), int(be_u32(d, h + 4))
		end := count == 0 ? start : next_table_start(d, start)
		if end > len(d) do return {}, false
		m.unknown_tables[i] = {h, count, d[start:end]}
	}
	return m, true
}

@(private = "file")
read_cancel :: proc(b: []byte) -> Cancel {
	return {
		be_u32(b, 0x00), be_u32(b, 0x04), be_u16(b, 0x08), be_u16(b, 0x0a), be_u32(b, 0x0c),
		be_u16(b, 0x10), be_u16(b, 0x12), be_u16(b, 0x14), be_u16(b, 0x16),
	}
}

// Makes `out` from the {offset, count} pair at header `h`; returns the table bytes.
@(private = "file")
table :: proc(d: []byte, h: int, size: int, out: ^[]$T) -> (records: []byte, ok: bool) {
	start, count := MOTBIN_BASE + int(be_u32(d, h)), int(be_u32(d, h + 4))
	if start + count * size > len(d) do return nil, false
	out^ = make([]T, count)
	return d[start:][:count * size], true
}

// Smallest table or embedded bank start after `start`.
@(private = "file")
next_table_start :: proc(d: []byte, start: int) -> int {
	end := len(d)
	for h := 0x188; h < 0x240; h += 8 do if s := MOTBIN_BASE + int(be_u32(d, h)); s > start do end = min(end, s)
	for i in 0 ..< 6 do if s := MOTBIN_BASE + int(be_u32(d, 0x240 + i * 8)); s > start do end = min(end, s)
	return end
}

@(private = "file")
motbin_string :: proc(d: []byte, off: u32) -> (string, bool) {
	start := MOTBIN_BASE + int(off)
	if start >= len(d) do return "", false
	return cstring_at(d, start), true
}

// UTF-16 BE up to a 0 unit -> UTF-8.
@(private = "file")
motbin_wstring :: proc(d: []byte, off: u32) -> (string, bool) {
	start := MOTBIN_BASE + int(off)
	end := start
	for end + 2 <= len(d) && be_u16(d, end) != 0 do end += 2
	if end + 2 > len(d) do return "", false
	units := make([]u16, (end - start) / 2, context.temp_allocator)
	for &u, i in units do u = be_u16(d, start + i * 2)
	buf := make([]byte, len(units) * 3)
	n := utf16.decode_to_utf8(buf, units)
	return string(buf[:n]), true
}
