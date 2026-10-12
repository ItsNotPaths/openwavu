// Moveset rows (src/db/tk5/schema.sql) from a motbin. Values stay as stored.
package tk5_convert

import "core:fmt"
import "../../db"
import formats "../../formats/tk5"

CMD_GROUP :: 0x8005

// anim_owner: the owner of the character's anim container (shared by Kuma and Panda, ...).
write_moveset_rows :: proc(w: ^db.Writer, char, anim_owner: string, m: formats.Motbin) {
	context.allocator = context.temp_allocator
	db.insert(w, "motbin", char, n(m.char_id), transmute([]byte)m.name, transmute([]byte)m.creator, m.date, m.full_date, m.unk_140)
	for move, i in m.aliases do db.insert(w, "move_alias", char, n(i), n(move))

	// List starts: every index that a row points to.
	requirement_starts := starts(len(m.requirements))
	cancel_starts := starts(len(m.cancels))
	group_starts := starts(len(m.group_cancels))
	hit_starts := starts(len(m.hit_conditions))
	pushback_extra_starts := starts(len(m.pushback_extras))
	extra_prop_starts := starts(len(m.extra_props))
	start_prop_starts := starts(len(m.start_props))
	end_prop_starts := starts(len(m.end_props))
	voiceclip_starts := starts(len(m.voiceclips))
	input_starts := starts(len(m.input_extras))
	pool_starts := starts(len(m.move_pool))

	for c in m.cancels {
		mark(requirement_starts, c.requirements)
		if c.command >> 16 == CMD_GROUP do mark(group_starts, c.move)
	}
	for c in m.group_cancels {
		mark(requirement_starts, c.requirements)
		if c.command >> 16 == CMD_GROUP do mark(group_starts, c.move)
	}
	for h in m.hit_conditions do mark(requirement_starts, h.requirements)
	for p in m.start_props do mark(requirement_starts, p.requirements)
	for p in m.end_props do mark(requirement_starts, p.requirements)
	for p in m.pushbacks do mark(pushback_extra_starts, p.extras)
	for s in m.input_sequences do mark(input_starts, s.inputs)
	for mv in m.moves {
		mark(cancel_starts, mv.cancels)
		mark(hit_starts, mv.hit_conditions)
		mark(voiceclip_starts, mv.voiceclips)
		mark(extra_prop_starts, mv.extra_props)
		mark(start_prop_starts, mv.start_props)
		mark(end_prop_starts, mv.end_props)
	}
	for t in m.unknown_tables do if t.header == 0x238 {
		for i in 0 ..< t.count do mark(extra_prop_starts, formats.be_u32(t.data, i * 8 + 4))
	}
	for id, i in m.move_pool do if id == 0 && i + 1 < len(m.move_pool) do pool_starts[i + 1] = true  // 0 ends a pool

	for mv, i in m.moves {
		owner, idx := anim_ref(char, anim_owner, mv.anim)
		db.insert(w, "move", char, n(i), mv.name, mv.anim_name, owner, n(idx), n(mv.anim),
			n(mv.vuln), n(mv.hit_level), n(mv.cancels), n(mv.transition), n(mv.hit_conditions),
			opt(mv.voiceclips), opt(mv.extra_props), opt(mv.start_props), opt(mv.end_props),
			n(mv.flags), n(mv.hit_category), n(mv.active_first), n(mv.active_last),
			n(mv.unk_1a), n(mv.unk_1c), n(mv.unk_24), n(mv.unk_26), n(mv.unk_28), n(mv.unk_48))
	}
	write_cancels(w, "cancel", char, m.cancels, cancel_starts)
	write_cancels(w, "group_cancel", char, m.group_cancels, group_starts)
	for v, i in m.cancel_extras do db.insert(w, "cancel_extra", char, n(i), n(v))
	for r, i in m.requirements {
		l, p := list_of(requirement_starts, i)
		db.insert(w, "requirement", char, n(l), n(p), n(r.id), n(r.param))
	}
	for h, i in m.hit_conditions {
		l, p := list_of(hit_starts, i)
		db.insert(w, "hit_condition", char, n(l), n(p), n(h.requirements), n(h.damage), n(h.unk_06), n(h.reaction))
	}
	for r, i in m.reactions {
		values := make([dynamic]db.Value)
		append(&values, char, n(i))
		for p in r.pushbacks do append(&values, n(p))
		for u in r.unk_1c do append(&values, n(u))
		append(&values, n(r.vertical_pushback), n(r.unk_32),
			n(r.move_standing), n(r.move_crouch), n(r.move_counter), n(r.move_crouch_counter),
			n(r.move_left), n(r.move_left_crouch), n(r.move_right), n(r.move_right_crouch),
			n(r.move_back), n(r.move_back_crouch), n(r.move_block), n(r.move_crouch_block),
			n(r.move_wall_slump), n(r.move_down))
		db.insert(w, "reaction", ..values[:])
	}
	for p, i in m.pushbacks do db.insert(w, "pushback", char, n(i), n(p.unk_00), n(p.unk_02), n(p.unk_04), n(p.unk_06), n(p.extras))
	for v, i in m.pushback_extras {
		l, p := list_of(pushback_extra_starts, i)
		db.insert(w, "pushback_extra", char, n(l), n(p), n(v))
	}
	for x, i in m.extra_props {
		l, p := list_of(extra_prop_starts, i)
		db.insert(w, "extra_prop", char, n(l), n(p), n(x.unk_00), n(x.unk_02), n(x.unk_04))
	}
	write_props(w, "start_prop", char, m.start_props, start_prop_starts)
	write_props(w, "end_prop", char, m.end_props, end_prop_starts)
	for v, i in m.voiceclips {
		l, p := list_of(voiceclip_starts, i)
		db.insert(w, "voiceclip", char, n(l), n(p), n(v))
	}
	for s, i in m.input_sequences do db.insert(w, "input_sequence", char, n(i), n(s.unk_00), n(s.unk_02), n(s.inputs))
	for x, i in m.input_extras {
		l, p := list_of(input_starts, i)
		db.insert(w, "input_extra", char, n(l), n(p), n(x.unk_00), n(x.unk_02))
	}
	for id, i in m.move_pool {
		l, p := list_of(pool_starts, i)
		db.insert(w, "move_pool", char, n(l), n(p), n(id))
	}
	for c, i in m.command_list {
		values := make([dynamic]db.Value)
		append(&values, char, n(i), c.name_ja, c.name_en, c.name_ja2)
		for s in c.commands do append(&values, s)
		for u in c.unk_2c do append(&values, n(u))
		db.insert(w, "command_list", ..values[:])
	}
	// (hole side-bands-import :tags importer :sev gap) the motbin+0x140 side band table (8 records of 4 u16) is not exported; the sim reads it in 0x18ae4.
	// (hole motbin-unknown-tables :tags importer :sev polish) motbin tables 0x208..0x238 are stored as raw blobs.
	for t in m.unknown_tables do db.insert(w, "unknown_table", char, n(t.header), n(t.count), t.data)
}

// 0x4000: the character's container bank 0; else 0x8000: common bank; else embedded bank 0.
// (hole embedded-anims :tags importer) embedded bank 0 (motbin header 0x240) is not empty: dragunov, jinpachi, kuma, panda, marduk and wang have one (type 0x64, 9/7/3/3/1/1 anims), exactly the ids of the 24 moves. Nothing writes it as anims/<char>/embedded yet: call write_bank with data[m.bank_offsets[0]:] after write_moveset_rows (make_dir must make the nested owner).
anim_ref :: proc(char, container_owner: string, anim: u32) -> (owner: string, idx: int) {
	idx = int(anim & 0x3fff)
	switch {
	case anim & 0x4000 != 0: return container_owner, idx
	case anim & 0x8000 != 0: return "common", idx
	}
	return embedded_owner(char), idx
}

embedded_owner :: proc(char: string) -> string {return fmt.tprintf("%s/embedded", char)}

@(private = "file")
write_cancels :: proc(w: ^db.Writer, table, char: string, cancels: []formats.Cancel, list_starts: []bool) {
	for c, i in cancels {
		l, p := list_of(list_starts, i)
		db.insert(w, table, char, n(l), n(p), n(c.command), n(c.requirements), n(c.move), n(c.unk_0a),
			n(c.extra), n(c.window_start), n(c.window_end), n(c.start_frame), n(c.option))
	}
}

@(private = "file")
write_props :: proc(w: ^db.Writer, table, char: string, props: []formats.Prop, list_starts: []bool) {
	for x, i in props {
		l, p := list_of(list_starts, i)
		db.insert(w, table, char, n(l), n(p), n(x.requirements), n(x.unk_04))
	}
}

// A list starts at index 0 and at every marked index.
@(private = "file")
starts :: proc(count: int) -> []bool {
	s := make([]bool, count)
	if count > 0 do s[0] = true
	return s
}

@(private = "file")
mark :: proc(s: []bool, index: $T) {
	if i := int(index); i >= 0 && i < len(s) do s[i] = true
}

// The list of row i is the nearest start at or below i.
@(private = "file")
list_of :: proc(s: []bool, i: int) -> (list, pos: int) {
	list = i
	for !s[list] do list -= 1
	return list, i - list
}

@(private = "file")
n :: proc(v: $T) -> db.Value {return i64(v)}

// -1: none.
@(private = "file")
opt :: proc(v: i32) -> db.Value {return v < 0 ? db.Null{} : i64(v)}
