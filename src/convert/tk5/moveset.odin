// Moveset rows (src/db/tk5/schema.sql) from a motbin. Values stay as stored, except the db edits of stock.odin.
package tk5_convert

import "core:fmt"
import "../../db"
import formats "../../formats/tk5"

CMD_GROUP :: 0x8005
CMD_SEQUENCE :: 0x8007  // 0x8007 + n reads input sequence n
SIDE_BANDS :: 8  // header 0x140, 4 u16 each

// anim_owner: the owner of the character's anim container (shared by Kuma and Panda, ...). moveset: index of formats.CHARACTERS.
write_moveset_rows :: proc(w: ^db.Writer, char, anim_owner: string, moveset: int, m: formats.Motbin) -> (err: string) {
	context.allocator = context.temp_allocator
	if !check_facing_props(m) do return fmt.tprintf("%s: facing mode property 0x8072, or 0x8071 outside the extra properties", char)
	t := seed_tracking(m, char == "xiaoyu")
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
	for u in m.unknown_tables do if u.header == 0x238 {
		for i in 0 ..< u.count do mark(extra_prop_starts, formats.be_u32(u.data, i * 8 + 4))
	}
	for id, i in m.move_pool do if id == 0 && i + 1 < len(m.move_pool) do pool_starts[i + 1] = true  // 0 ends a pool

	for mv, i in m.moves {
		owner, idx := anim_ref(char, anim_owner, mv.anim)
		hits, hits_ok := move_hits(mv, moveset)
		if !hits_ok do return fmt.tprintf("%s move %d: a hitbox on a special slot its row leaves unwritten", char, i)
		values := make([dynamic]db.Value)
		append(&values, char, n(i), mv.name, mv.anim_name, owner, n(idx), n(mv.anim), n(mv.vuln), n(mv.hit_level), n(mv.cancels),
			n(mv.transition), n(mv.unk_1a), n(mv.unk_1c >> 16), n(mv.unk_1c & 0xffff), n(mv.hit_conditions),
			n(mv.unk_26), n(mv.unk_28 >> 16), n(mv.unk_28 & 0xffff),
			n(mv.voiceclips), n(mv.extra_props), n(mv.start_props), n(mv.end_props),
			n(live_flags(mv.flags)), n(mv.hit_category), n(mv.active_first), n(mv.active_last), n(mv.unk_48 >> 16), n(mv.unk_48 & 0xffff),
			n(t.default[i].row), n(t.default[i].far_row), n(t.default[i].far_source), n(t.default[i].far_angle), n(rides_partner(mv)))
		for pair in hits.pairs do append(&values, n(pair.end.kind), n(pair.end.index), n(pair.start.kind), n(pair.start.index))
		append(&values, n(hits.attack_bones), n(hits.slots), n(hits.launches))
		db.insert(w, "move", ..values[:])
	}
	write_cancels(w, "cancel", char, m, m.cancels, t.cancel_pick, cancel_starts)
	write_cancels(w, "group_cancel", char, m, m.group_cancels, t.group_pick, group_starts)
	for r, i in m.requirements {
		l, p := list_of(requirement_starts, i)
		db.insert(w, "requirement", char, n(l), n(p), n(r.id), n(requirement_param(r)))
	}
	for h, i in m.hit_conditions {
		l, p := list_of(hit_starts, i)
		db.insert(w, "hit_condition", char, n(l), n(p), n(h.requirements), n(h.damage), n(h.unk_06), n(h.reaction))
	}
	for r, i in m.reactions {
		values := make([dynamic]db.Value)
		append(&values, char, n(i))
		for p in r.pushbacks do append(&values, n(p))
		for u in r.unk_1c do append(&values, n(u))  // angle 0..5, yaw 0..3
		append(&values, n(r.vertical_pushback), n(r.unk_32),  // yaw 4, 5
			n(r.move_standing), n(r.move_crouch), n(r.move_counter), n(r.move_crouch_counter),
			n(r.move_left), n(r.move_left_crouch), n(r.move_right), n(r.move_right_crouch),
			n(r.move_back), n(r.move_back_crouch), n(r.move_block), n(r.move_crouch_block),
			n(r.move_wall_slump), n(r.move_down))
		db.insert(w, "reaction", ..values[:])
	}
	for p, i in m.pushbacks do db.insert(w, "pushback", char, n(i), n(p.unk_00), n(p.unk_02), n(p.unk_04), n(p.unk_06), n(p.extras))
	for v, i in m.pushback_extras {
		l, p := list_of(pushback_extra_starts, i)
		db.insert(w, "pushback_curve", char, n(l), n(p), n(v))
	}
	for x, i in m.extra_props {
		l, p := list_of(extra_prop_starts, i)
		db.insert(w, "extra_prop", char, n(l), n(p), n(x.unk_00), n(x.unk_02), n(prop_value(&t, x)), n(x.unk_04 & 0xffff))
	}
	write_tracking(w, char, &t)
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
	for i in 0 ..< SIDE_BANDS {
		b := m.unk_140[i * 8:]
		db.insert(w, "side_band", char, n(i), n(formats.be_u16(b, 0)), n(formats.be_u16(b, 2)), n(formats.be_u16(b, 4)), n(formats.be_u16(b, 6)))
	}
	// (hole motbin-unknown-tables :tags importer :sev polish) motbin tables 0x208..0x238 are stored as raw blobs.
	for u in m.unknown_tables do db.insert(w, "unknown_table", char, n(u.header), n(u.count), u.data)
	return ""
}

// 0x4000: the character's container bank 0; else 0x8000: common bank; else embedded bank 0.
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
write_cancels :: proc(w: ^db.Writer, table, char: string, m: formats.Motbin, cancels: []formats.Cancel, picks: []u16, list_starts: []bool) {
	for c, i in cancels {
		l, p := list_of(list_starts, i)
		code := c.command >> 16
		move, group_list, sequence, tracking: db.Value = n(c.move), db.Null{}, db.Null{}, db.Null{}
		if code == CMD_GROUP do move, group_list = db.Null{}, n(c.move)
		if code >= CMD_SEQUENCE do code, sequence = CMD_SEQUENCE, n(code - CMD_SEQUENCE)
		if picks[i] != 0 do tracking = n(picks[i] - 1)  // the game counts picks from 1
		db.insert(w, table, char, n(l), n(p), n(code), n(c.command & 0xffff), n(c.requirements), move, group_list, n(c.unk_0a),
			n(m.cancel_extras[c.extra]), n(c.window_start), n(c.window_end), n(c.start_frame), n(cancel_option(m, c)), tracking, sequence)
	}
}

@(private = "file")
write_tracking :: proc(w: ^db.Writer, char: string, t: ^Tracking) {
	for r, i in t.rows {
		db.insert(w, "tracking_row", char, n(i), n(r.law), n(r.start), n(r.target), n(r.stock_mode),
			n(r.gate.kind), n(r.gate.until), n(r.gate.min_distance),
			n(r.rate.normal), n(r.rate.late), n(r.rate.air), n(r.rate.late_from), n(r.rate.frames), n(r.rate.halving), n(r.rate.by_distance),
			n(r.limit.total), n(r.limit.sweep[0]), n(r.limit.sweep[1]), n(r.limit.sweep[2]), n(r.limit.sweep[3]),
			n(r.end.yaw_when), n(r.end.pivot_when), n(r.end.grace), n(r.end.phase))
	}
	for o, i in t.overrides do db.insert(w, "tracking_override", char, n(i), n(o.row), n(o.far_row), n(o.far_source), n(o.far_angle))
	for f, i in t.fixed do db.insert(w, "tracking_fixed", char, n(i), n(f.row), n(f.far_row), n(f.far_source), n(f.far_angle))
}

@(private = "file")
write_props :: proc(w: ^db.Writer, table, char: string, props: []formats.Prop, list_starts: []bool) {
	for x, i in props {
		l, p := list_of(list_starts, i)
		db.insert(w, table, char, n(l), n(p), n(x.requirements), n(x.unk_04 >> 16), n(x.unk_04 & 0xffff))
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
