package tests

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import formats "../src/formats/tk5"

// motbin.py CHARS order: entry 39 + 2 * i.
MOTBIN_NAMES :: [?]string{
	"paul", "law", "lei", "king", "yoshimitsu", "nina", "hwoarang", "xiaoyu", "christie", "jin",
	"julia", "kuma", "bryan", "heihachi", "kazuya", "lee", "steve", "marduk", "jack5", "roger",
	"anna", "wang", "ganryu", "asuka", "bruce", "baek", "devil_jin", "raven", "feng", "armor_king",
	"lili", "dragunov", "panda", "eddy", "jinpachi", "jinpachi2",
}

read_motbin_entry :: proc(f: ^os.File, table: []formats.Entry, index: int) -> (m: formats.Motbin, ok: bool) {
	e := table[index]
	stored := make([]byte, e.stored_size, context.temp_allocator)
	os.read_at(f, stored, formats.entry_offset(e))
	packed := formats.unpack_entry(e, stored, context.temp_allocator) or_return
	data := formats.unlz(packed, context.temp_allocator) or_return
	return formats.read_motbin(data, context.temp_allocator)
}

@(test)
motbin_matches_reference :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)

	for name, i in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		ref_bytes, rerr := os.read_entire_file(fmt.tprintf(TK5 + "/extract/chars/%s.json", name), context.temp_allocator)
		if rerr != nil do continue
		ref, jerr := json.parse(ref_bytes, parse_integers = true, allocator = context.temp_allocator)
		if !testing.expectf(t, jerr == nil, "%s: reference json", name) do continue
		m, read := read_motbin_entry(f, table, formats.MOTBIN_FIRST + 2 * i)
		if !testing.expectf(t, read, "%s: motbin not read", name) do continue
		compare_motbin(t, name, &m, ref.(json.Object))

		small, small_ok := read_motbin_entry(f, table, formats.MOTBIN_FIRST + 2 * i + 1)
		testing.expectf(t, small_ok && len(small.moves) > 0 && small.moves[0].name == "motOrigin", "%s: small motbin", name)
	}
}

@(private = "file")
compare_motbin :: proc(t: ^testing.T, name: string, m: ^formats.Motbin, ref: json.Object) {
	h := ref["header"].(json.Object)
	testing.expectf(t, i64(m.char_id) == h["char_id"].(json.Integer), "%s: char_id", name)
	header := [?][2]string{{"creator", m.creator}, {"date", m.date}, {"fulldate", m.full_date}}
	for kv in header {
		if is_ascii(kv[1]) do testing.expectf(t, kv[1] == h[kv[0]].(json.String), "%s: header %s", name, kv[0])
	}
	for a, i in h["aliases"].(json.Array) do testing.expectf(t, i64(m.aliases[i]) == a.(json.Integer), "%s: alias %d", name, i)

	check :: proc(t: ^testing.T, name, tbl: string, ref: json.Object, count: int, keys: []string, got: proc(m: ^formats.Motbin, i: int) -> []i64, m: ^formats.Motbin) {
		rows := ref[tbl].(json.Array)
		if !testing.expectf(t, len(rows) == count, "%s: %s count %d, want %d", name, tbl, count, len(rows)) do return
		for row, i in rows {
			want := flatten(row.(json.Object), keys)
			if !testing.expectf(t, slice_equal(got(m, i), want), "%s: %s[%d] = %v, want %v", name, tbl, i, got(m, i), want) do return
		}
	}

	check(t, name, "reactions", ref, len(m.reactions), {"pushbacks", "u", "vertical_pushback", "u2",
		"standing", "crouch", "ch", "crouch_ch", "left", "left_crouch", "right", "right_crouch",
		"back", "back_crouch", "block", "crouch_block", "wallslump", "downed"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.reactions[i]
		out := make([dynamic]i64, context.temp_allocator)
		for p in x.pushbacks do append(&out, i64(p))
		for u in x.unk_1c do append(&out, i64(u))
		append(&out, i64(x.vertical_pushback), i64(x.unk_32),
			i64(x.move_standing), i64(x.move_crouch), i64(x.move_counter), i64(x.move_crouch_counter),
			i64(x.move_left), i64(x.move_left_crouch), i64(x.move_right), i64(x.move_right_crouch),
			i64(x.move_back), i64(x.move_back_crouch), i64(x.move_block), i64(x.move_crouch_block),
			i64(x.move_wall_slump), i64(x.move_down))
		return out[:]
	}, m)
	check(t, name, "requirements", ref, len(m.requirements), {"req", "param"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.requirements[i]
		return ints(x.id, x.param)
	}, m)
	check(t, name, "hit_conditions", ref, len(m.hit_conditions), {"requirements", "damage", "u", "reaction"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.hit_conditions[i]
		return ints(x.requirements, x.damage, x.unk_06, x.reaction)
	}, m)
	check(t, name, "pushbacks", ref, len(m.pushbacks), {"val1", "val2", "val3", "u", "extra"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.pushbacks[i]
		return ints(x.unk_00, x.unk_02, x.unk_04, x.unk_06, x.extras)
	}, m)
	check(t, name, "pushback_extras", ref, len(m.pushback_extras), {"value"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		return ints(m.pushback_extras[i])
	}, m)
	CANCEL_KEYS :: []string{"command", "requirements", "move", "u", "extra", "window_start", "window_end", "starting_frame", "option"}
	check(t, name, "cancels", ref, len(m.cancels), CANCEL_KEYS, proc(m: ^formats.Motbin, i: int) -> []i64 {
		return cancel_ints(m.cancels[i])
	}, m)
	check(t, name, "group_cancels", ref, len(m.group_cancels), CANCEL_KEYS, proc(m: ^formats.Motbin, i: int) -> []i64 {
		return cancel_ints(m.group_cancels[i])
	}, m)
	check(t, name, "cancel_extras", ref, len(m.cancel_extras), {"value"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		return ints(m.cancel_extras[i])
	}, m)
	check(t, name, "extra_props", ref, len(m.extra_props), {"type", "id", "value"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.extra_props[i]
		return ints(x.unk_00, x.unk_02, x.unk_04)
	}, m)
	check(t, name, "start_props", ref, len(m.start_props), {"requirements", "value"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.start_props[i]
		return ints(x.requirements, x.unk_04)
	}, m)
	check(t, name, "end_props", ref, len(m.end_props), {"requirements", "value"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.end_props[i]
		return ints(x.requirements, x.unk_04)
	}, m)
	check(t, name, "moves", ref, len(m.moves), {"anim", "vuln", "hitlevel", "cancel", "transition", "u1a", "u1c",
		"hit_condition", "anim_len", "u26", "u28", "voiceclip", "extra_prop", "start_prop", "end_prop", "flags3c"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.moves[i]
		return ints(x.anim, x.vuln, x.hit_level, x.cancels, x.transition, x.unk_1a, x.unk_1c, x.hit_conditions,
			x.unk_24, x.unk_26, x.unk_28, x.voiceclips, x.extra_props, x.start_props, x.end_props, x.flags)
	}, m)
	for row, i in ref["moves"].(json.Array) {
		r, x := row.(json.Object), m.moves[i]
		u40 := fmt.tprintf("%08x%04x%04x%08x", x.hit_category, x.active_first, x.active_last, x.unk_48)
		ok := x.name == r["name"].(json.String) && x.anim_name == r["anim_name"].(json.String) && u40 == r["u40"].(json.String)
		if !testing.expectf(t, ok, "%s: move %d strings or +0x40", name, i) do break
	}
	check(t, name, "voiceclips", ref, len(m.voiceclips), {"value"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		return ints(m.voiceclips[i])
	}, m)
	check(t, name, "input_sequences", ref, len(m.input_sequences), {"u1", "u2", "extra"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.input_sequences[i]
		return ints(x.unk_00, x.unk_02, x.inputs)
	}, m)
	check(t, name, "input_extras", ref, len(m.input_extras), {"u1", "u2"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.input_extras[i]
		return ints(x.unk_00, x.unk_02)
	}, m)
	check(t, name, "table_200", ref, len(m.move_pool), {"value"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		return ints(m.move_pool[i])
	}, m)
	check(t, name, "movelist", ref, len(m.command_list), {"u"}, proc(m: ^formats.Motbin, i: int) -> []i64 {
		x := m.command_list[i].unk_2c
		return ints(x[0], x[1], x[2], x[3])
	}, m)
	for row, i in ref["movelist"].(json.Array) {
		x := m.command_list[i]
		got: [11]string
		got[0], got[1], got[2] = x.name_ja, x.name_en, x.name_ja2
		copy(got[3:], x.commands[:])
		for s, j in row.(json.Object)["text"].(json.Array) {
			testing.expectf(t, got[j] == s.(json.String), "%s: movelist %d text %d", name, i, j)
		}
	}

	// Undecoded tables: motbin.py keeps 0x208, 0x210 and 0x238 as raw records.
	for u in m.unknown_tables {
		raw: strings.Builder
		strings.builder_init(&raw, context.temp_allocator)
		switch u.header {
		case 0x208:
			for r in ref["table_208"].(json.Array) do fmt.sbprintf(&raw, "%s%08x", r.(json.Object)["raw"].(json.String), r.(json.Object)["table_210"].(json.Integer))
		case 0x210:
			for r in ref["table_210"].(json.Array) do strings.write_string(&raw, r.(json.Object)["raw"].(json.String))
		case 0x238:
			for r in ref["table_238"].(json.Array) do fmt.sbprintf(&raw, "%08x%08x", r.(json.Object)["u"].(json.Integer), r.(json.Object)["extra_prop"].(json.Integer))
		case:
			continue
		}
		testing.expectf(t, string(hex.encode(u.data, context.temp_allocator)) == strings.to_string(raw), "%s: table %x raw bytes", name, u.header)
	}
}

@(private = "file")
cancel_ints :: proc(x: formats.Cancel) -> []i64 {
	return ints(x.command, x.requirements, x.move, x.unk_0a, x.extra, x.window_start, x.window_end, x.start_frame, x.option)
}

@(private = "file")
ints :: proc(args: ..any) -> []i64 {
	out := make([]i64, len(args), context.temp_allocator)
	for a, i in args {
		switch v in a {
		case u16: out[i] = i64(v)
		case u32: out[i] = i64(v)
		case i32: out[i] = i64(v)
		}
	}
	return out
}

// The reference row's values in key order; arrays are spread.
@(private = "file")
flatten :: proc(row: json.Object, keys: []string) -> []i64 {
	out := make([dynamic]i64, context.temp_allocator)
	for k in keys {
		#partial switch v in row[k] {
		case json.Integer: append(&out, v)
		case json.Array: for e in v do append(&out, e.(json.Integer))
		}
	}
	return out[:]
}

@(private = "file")
slice_equal :: proc(a, b: []i64) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

@(private = "file")
is_ascii :: proc(s: string) -> bool {
	for c in transmute([]byte)s do if c > 127 do return false
	return true
}
