// Moveset rows (src/db/tk5/schema.sql) from a motbin. Values stay as stored, except the db edits of stock.odin.
package tk5_convert

import "core:fmt"
import "../../db"
import formats "../../formats/tk5"

CMD_GROUP :: 0x8005
CMD_SEQUENCE :: 0x8007  // 0x8007 + n reads input sequence n
ALIAS_BASE :: 0x8000    // move id 0x8000 + n: alias n
SIDE_BANDS :: 8  // header 0x140, 4 u16 each

// The motbin tables that hold lists.
List :: enum {Cancel, Group_Cancel, Requirement, Hit_Condition, Pushback_Curve, Extra_Prop, Start_Prop, End_Prop, Voiceclip, Move_Pool}
LIST_TABLES := [List]string{
	.Cancel = "cancel", .Group_Cancel = "group_cancel", .Requirement = "requirement", .Hit_Condition = "hit_condition",
	.Pushback_Curve = "pushback_curve", .Extra_Prop = "extra_prop", .Start_Prop = "start_prop", .End_Prop = "end_prop",
	.Voiceclip = "voiceclip", .Move_Pool = "move_pool",
}

// The keys of one character's rows. A list starts at every index that a row points to, and after every end row.
@(private = "file")
Keys :: struct {
	char:  string,
	moves: []string,
	lists: [List][]string,  // by game index: the key of the list that starts there, "" inside a list
}

// anim_owner: the owner of the character's anim container (shared by Kuma and Panda, ...). moveset: index of formats.CHARACTERS.
write_moveset_rows :: proc(w: ^db.Writer, char, anim_owner: string, moveset: int, m: formats.Motbin) -> (err: string) {
	context.allocator = context.temp_allocator
	if !check_facing_props(m) do return fmt.tprintf("%s: facing mode property 0x8072, or 0x8071 outside the extra properties", char)
	t := seed_tracking(m, char == "xiaoyu")
	k := keys_of(char, m)
	sheets := db.name_sheets(w)
	db.insert(w, "motbin", char, n(m.char_id), transmute([]byte)m.name, transmute([]byte)m.creator, m.date, m.full_date, m.unk_140)
	for id, i in m.aliases {
		move, _ := move_ref(&k, id)
		db.insert(w, "move_alias", char, n(i), move)
	}

	for mv, i in m.moves {
		owner, idx := anim_ref(char, anim_owner, mv.anim)
		hits, hits_ok := move_hits(mv, moveset)
		if !hits_ok do return fmt.tprintf("%s move %d: a hitbox on a special slot its row leaves unwritten", char, i)
		next, next_alias := move_ref(&k, mv.transition)
		words := [Move_Word]u32{.Vuln = mv.vuln, .Hit_Level = mv.hit_level, .Flags = live_flags(mv.flags)}
		if left := unnamed_bits(words); left != {} do return fmt.tprintf("%s move %d: bits with no column %v", char, i, left)
		values := make([dynamic]db.Value)
		append(&values, k.moves[i], char, mv.name, mv.anim_name, owner, n(idx), n(mv.anim),
			named(sheets["state_class"], words[.Vuln] >> STATE_CLASS_SHIFT & 31))
		for bit in STATE_BITS do append(&values, n(words[.Vuln] >> bit & 1))
		append(&values, named(sheets["attack_kind"], words[.Hit_Level] >> ATTACK_KIND_SHIFT & 0xff))
		for bit in ATTACK_BITS do append(&values, n(words[.Hit_Level] >> bit & 1))
		append(&values, list_ref(&k, .Cancel, mv.cancels), next, next_alias, n(mv.unk_1a), n(mv.unk_1c >> 16), n(mv.unk_1c & 0xffff),
			list_ref(&k, .Hit_Condition, mv.hit_conditions), n(mv.unk_26), n(mv.unk_28 >> 16), n(mv.unk_28 & 0xffff),
			list_ref(&k, .Voiceclip, mv.voiceclips), list_ref(&k, .Extra_Prop, mv.extra_props),
			list_ref(&k, .Start_Prop, mv.start_props), list_ref(&k, .End_Prop, mv.end_props))
		for bit in FLAG_BITS do append(&values, n(words[.Flags] >> bit & 1))
		append(&values, n(mv.hit_category), n(mv.active_first), n(mv.active_last), n(mv.unk_48 >> 16),
			row_key(char, "tracking_row", t.default[i].row), row_key(char, "tracking_row", t.default[i].far_row),
			named(sheets["tracking_far_source"], t.default[i].far_source), n(t.default[i].far_angle), n(rides_partner(mv)))
		kinds := sheets["hit_point_kind"]
		for pair in hits.pairs do append(&values, named(kinds, pair.end.kind), n(pair.end.index), named(kinds, pair.start.kind), n(pair.start.index))
		append(&values, n(hits.attack_bones), n(hits.slots), n(hits.launches))
		db.insert(w, "move", ..values[:])
		ai := make([dynamic]db.Value)
		append(&ai, k.moves[i])
		set := false
		for x in AI_BITS {
			bit := words[x.word] >> x.bit & 1
			set ||= bit != 0
			append(&ai, n(bit))
		}
		if set do db.insert(w, "move_ai", ..ai[:])
	}
	write_cancels(w, &k, sheets, .Cancel, m, m.cancels, t.cancel_pick)
	write_cancels(w, &k, sheets, .Group_Cancel, m, m.group_cancels, t.group_pick)
	for r, i in m.requirements {
		list, pos := in_list(w, &k, .Requirement, i)
		if is_end(m, .Requirement, i) {
			if r.param != 0 do return fmt.tprintf("%s requirement %d: an end row with param %d", char, i, r.param)
			continue  // the loader adds it
		}
		params := param_values(&k, r.id, requirement_param(r))
		values := make([dynamic]db.Value)
		append(&values, list, pos, n(r.id))
		append(&values, ..params[:])
		db.insert(w, "requirement", ..values[:])
	}
	for h, i in m.hit_conditions {
		list, pos := in_list(w, &k, .Hit_Condition, i)
		db.insert(w, "hit_condition", list, pos, list_ref(&k, .Requirement, h.requirements), n(h.damage),
			row_key(char, "reaction", h.reaction))
	}
	for r, i in m.reactions {
		values := make([dynamic]db.Value)
		append(&values, row_key(char, "reaction", i), char)
		for p in r.pushbacks do append(&values, row_key(char, "pushback", p))
		for u in r.unk_1c do append(&values, n(u))  // angle 0..5, yaw 0..3
		append(&values, n(r.vertical_pushback), n(r.unk_32))  // yaw 4, 5
		ids := [14]u16{r.move_standing, r.move_crouch, r.move_counter, r.move_crouch_counter, r.move_left, r.move_left_crouch,
			r.move_right, r.move_right_crouch, r.move_back, r.move_back_crouch, r.move_block, r.move_crouch_block, r.move_wall_slump, r.move_down}
		aliases: [len(ids)]db.Value
		for id, slot in ids {
			move: db.Value
			move, aliases[slot] = move_ref(&k, id)
			append(&values, move)
		}
		append(&values, ..aliases[:])
		db.insert(w, "reaction", ..values[:])
	}
	for p, i in m.pushbacks {
		db.insert(w, "pushback", row_key(char, "pushback", i), char, n(p.unk_00), n(p.unk_02), n(p.unk_04),
			list_ref(&k, .Pushback_Curve, p.extras))
	}
	for v, i in m.pushback_extras {
		list, pos := in_list(w, &k, .Pushback_Curve, i)
		db.insert(w, "pushback_curve", list, pos, n(v))
	}
	for x, i in m.extra_props {
		list, pos := in_list(w, &k, .Extra_Prop, i)
		if is_end(m, .Extra_Prop, i) {
			if x != {} do return fmt.tprintf("%s extra property %d: an end row with values", char, i)
			continue
		}
		params := param_values(&k, x.unk_02, prop_value(&t, x))
		values := make([dynamic]db.Value)
		append(&values, list, pos, n(x.unk_00), n(x.unk_02))
		append(&values, ..params[:])
		db.insert(w, "extra_prop", ..values[:])
	}
	write_tracking(w, char, sheets, &t)
	write_props(w, &k, .Start_Prop, m)
	write_props(w, &k, .End_Prop, m)
	for v, i in m.voiceclips {
		list, pos := in_list(w, &k, .Voiceclip, i)
		if !is_end(m, .Voiceclip, i) do db.insert(w, "voiceclip", list, pos, n(v))
	}
	for id, i in m.move_pool {
		list, pos := in_list(w, &k, .Move_Pool, i)
		if !is_end(m, .Move_Pool, i) do db.insert(w, "move_pool", list, pos, n(id))
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
	return check_list_ends(&k, m)
}

VOICECLIP_END :: 0xffff

// The game's end row of a list. Counted lists (pushback curves, input extras) and hit conditions have none.
is_end :: proc(m: formats.Motbin, list: List, i: int) -> bool {
	#partial switch list {
	case .Cancel: return m.cancels[i].command >> 16 == CMD_END
	case .Group_Cancel: return m.group_cancels[i].command >> 16 == CMD_GROUP_END
	case .Requirement: return m.requirements[i].id == REQUIREMENT_END
	case .Extra_Prop: return m.extra_props[i].unk_00 == 0
	case .Start_Prop: return m.start_props[i] == {}
	case .End_Prop: return m.end_props[i] == {}
	case .Voiceclip: return m.voiceclips[i] == VOICECLIP_END
	case .Move_Pool: return m.move_pool[i] == 0
	}
	return false
}

// Lists whose end row the db leaves out; the loader adds it back (voiceclips are not loaded).
LOADER_ENDS :: bit_set[List]{.Requirement, .Extra_Prop, .Start_Prop, .End_Prop, .Voiceclip, .Move_Pool}

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

// Move keys are the move names; a missing or repeated name takes the game index.
@(private = "file")
keys_of :: proc(char: string, m: formats.Motbin) -> (k: Keys) {
	k.char = char
	k.moves = make([]string, len(m.moves))
	seen := make(map[string]bool)
	for mv, i in m.moves {
		k.moves[i] = mv.name == "" || mv.name in seen ? row_key(char, mv.name == "" ? "move" : mv.name, i) : fmt.tprintf("%s/%s", char, mv.name)
		seen[mv.name] = true
	}
	counts := [List]int{
		.Cancel = len(m.cancels), .Group_Cancel = len(m.group_cancels), .Requirement = len(m.requirements),
		.Hit_Condition = len(m.hit_conditions), .Pushback_Curve = len(m.pushback_extras), .Extra_Prop = len(m.extra_props),
		.Start_Prop = len(m.start_props), .End_Prop = len(m.end_props), .Voiceclip = len(m.voiceclips),
		.Move_Pool = len(m.move_pool),
	}
	for count, list in counts do k.lists[list] = make([]string, count)

	// Lists a move points to take its key.
	for mv, i in m.moves {
		mark(&k, .Cancel, mv.cancels, k.moves[i])
		mark(&k, .Hit_Condition, mv.hit_conditions, k.moves[i])
		mark(&k, .Voiceclip, mv.voiceclips, k.moves[i])
		mark(&k, .Extra_Prop, mv.extra_props, k.moves[i])
		mark(&k, .Start_Prop, mv.start_props, k.moves[i])
		mark(&k, .End_Prop, mv.end_props, k.moves[i])
	}
	for p, i in m.pushbacks do mark(&k, .Pushback_Curve, p.extras, row_key(char, "pushback", i))
	for c in m.cancels do mark_cancel(&k, c)
	for c in m.group_cancels do mark_cancel(&k, c)
	for h in m.hit_conditions do mark(&k, .Requirement, h.requirements)
	for p in m.start_props do mark(&k, .Requirement, p.requirements)
	for p in m.end_props do mark(&k, .Requirement, p.requirements)
	for r in m.requirements do if code_ref(r.id) == "move_pool" do mark(&k, .Move_Pool, r.param)
	for u in m.unknown_tables do if u.header == 0x238 {
		for i in 0 ..< u.count do mark(&k, .Extra_Prop, formats.be_u32(u.data, i * 8 + 4))
	}

	// Rows after an end row start a list of their own.
	for list in List {
		for i in 0 ..< len(k.lists[list]) do if is_end(m, list, i) do mark(&k, list, i + 1)
		mark(&k, list, 0)
	}
	return
}

@(private = "file")
mark_cancel :: proc(k: ^Keys, c: formats.Cancel) {
	mark(k, .Requirement, c.requirements)
	if c.command >> 16 == CMD_GROUP do mark(k, .Group_Cancel, c.move)
}

// The first key given to a list start wins; without one the list is named by its table and game index.
@(private = "file")
mark :: proc(k: ^Keys, list: List, index: $T, key := "") {
	keys := k.lists[list]
	i := int(index)
	if i < 0 || i >= len(keys) || keys[i] != "" do return
	keys[i] = key if key != "" else row_key(k.char, LIST_TABLES[list], i)
}

// The list row i is in and its place there. A row that starts a list adds the list.
@(private = "file")
in_list :: proc(w: ^db.Writer, k: ^Keys, list: List, i: int) -> (key, pos: db.Value) {
	keys := k.lists[list]
	start := i
	for keys[start] == "" do start -= 1
	if start == i do db.insert(w, fmt.tprintf("%s_list", LIST_TABLES[list]), keys[i], k.char)
	return keys[start], n(i - start)
}

// A list reference: NULL for none (-1); an index past the table keeps its game name, which no list has.
@(private = "file")
list_ref :: proc(k: ^Keys, list: List, index: $T) -> db.Value {
	i := int(index)
	if i < 0 do return db.Null{}
	if i < len(k.lists[list]) do return k.lists[list][i]
	return row_key(k.char, LIST_TABLES[list], i)
}

// A move id: a move by game index, or alias n for 0x8000 + n.
@(private = "file")
move_ref :: proc(k: ^Keys, id: $T) -> (move, alias: db.Value) {
	if int(id) >= ALIAS_BASE do return db.Null{}, n(int(id) - ALIAS_BASE)
	if int(id) < len(k.moves) do return k.moves[id], db.Null{}
	return row_key(k.char, "move", id), db.Null{}
}

@(private = "file")
row_key :: proc(char, table: string, index: $T) -> string {return fmt.tprintf("%s/%s/%d", char, table, index)}

// A requirement param or property value: plain, or in the column of the table its code names (CODE_REFS).
// Columns: value, move, alias, pushback, tracking_row, move_pool, compare_id.
@(private = "file")
param_values :: proc(k: ^Keys, code, value: u16) -> (values: [7]db.Value) {
	for &v in values do v = db.Null{}
	switch code_ref(code) {
	case "move": values[1], values[2] = move_ref(k, value)
	case "pushback": values[3] = row_key(k.char, "pushback", value)
	case "tracking_row": values[4] = row_key(k.char, "tracking_row", value)
	case "move_pool": values[5] = list_ref(k, .Move_Pool, value)
	case "compare_id": values[6] = n(value)
	case: values[0] = n(value)
	}
	return
}

// A move's packed words as columns (schema move, move_ai): the bits each column takes, in schema order.
Move_Word :: enum {Vuln, Hit_Level, Flags}
Word_Bit :: struct {word: Move_Word, bit: u32}
STATE_CLASS_SHIFT :: 11  // vuln bits 11..15: state_class
ATTACK_KIND_SHIFT :: 8   // hit_level bits 8..15: attack_kind
STATE_BITS :: [?]u32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
ATTACK_BITS :: [?]u32{0, 1, 2, 3, 4}
FLAG_BITS :: [?]u32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19, 21, 23, 24, 26, 28, 30}  // flags in the loader order (live_flags)
AI_BITS :: [?]Word_Bit{  // not final: the stock CPU's inputs
	{.Vuln, 16}, {.Vuln, 17}, {.Vuln, 19}, {.Vuln, 21}, {.Vuln, 22}, {.Vuln, 23},
	{.Hit_Level, 16}, {.Hit_Level, 18}, {.Hit_Level, 19}, {.Hit_Level, 20}, {.Hit_Level, 21}, {.Hit_Level, 22}, {.Flags, 27},
}
DEAD_BITS :: [Move_Word]u32{.Vuln = 1 << 18 | 1 << 20 | 1 << 24, .Hit_Level = 1 << 17 | 1 << 23, .Flags = 1 << 20 | 1 << 22 | 1 << 25 | 1 << 29}  // read by nothing

// The bits of each word that no column holds and that the game reads.
@(private = "file")
unnamed_bits :: proc(words: [Move_Word]u32) -> (left: [Move_Word]u32) {
	known := DEAD_BITS
	known[.Vuln] |= 31 << STATE_CLASS_SHIFT
	known[.Hit_Level] |= 0xff << ATTACK_KIND_SHIFT
	for bit in STATE_BITS do known[.Vuln] |= 1 << bit
	for bit in ATTACK_BITS do known[.Hit_Level] |= 1 << bit
	for bit in FLAG_BITS do known[.Flags] |= 1 << bit
	for x in AI_BITS do known[x.word] |= 1 << x.bit
	for word in Move_Word do left[word] = words[word] &~ known[word]
	return
}

// A cancel's extradata: the transition word (class, start alignment, motion code), the flags, the word unlock.
TRANSITION_SHEETS :: [3]string{"transition", "start_align", "motion"}
TRANSITION_FIELDS :: [3]struct {shift, bits: u32}{{10, 4}, {6, 4}, {0, 6}}
EXTRA_FLAGS :: [4]u32{1 << 15, 1 << 14, 1 << 16, 1 << 17}  // turn, no_blend_out, no_root_fix, root_hips

@(private = "file")
write_cancels :: proc(w: ^db.Writer, k: ^Keys, sheets: map[string]map[i64]string, list: List, m: formats.Motbin,
	cancels: []formats.Cancel, picks: []u16) {
	transition_sheets := TRANSITION_SHEETS
	for c, i in cancels {
		key, pos := in_list(w, k, list, i)
		kind, input := cancel_input(m, c)
		move, alias := move_ref(k, c.move)
		kind_value, group_list, tracking: db.Value = db.Null{}, db.Null{}, db.Null{}
		if kind != "" do kind_value = kind
		if kind == "group" do move, alias, group_list = db.Null{}, db.Null{}, list_ref(k, .Group_Cancel, c.move)
		if picks[i] != 0 do tracking = row_key(k.char, "tracking_override", picks[i] - 1)  // the game counts picks from 1
		extra := m.cancel_extras[c.extra]
		values := make([dynamic]db.Value)
		append(&values, key, pos, kind_value, input, list_ref(k, .Requirement, c.requirements), move, alias, group_list)
		for field, f in TRANSITION_FIELDS {
			append(&values, named(sheets[transition_sheets[f]], extra >> field.shift & (1 << field.bits - 1)))
		}
		for flag in EXTRA_FLAGS do append(&values, n(extra & flag != 0))
		append(&values, tracking)
		db.insert(w, LIST_TABLES[list], ..values[:])
	}
}

@(private = "file")
write_tracking :: proc(w: ^db.Writer, char: string, sheets: map[string]map[i64]string, t: ^Tracking) {
	phase, when_, far := sheets["tracking_phase"], sheets["tracking_when"], sheets["tracking_far_source"]
	for r, i in t.rows {
		db.insert(w, "tracking_row", row_key(char, "tracking_row", i), char, named(sheets["tracking_law"], r.law), named(phase, r.start),
			named(sheets["tracking_target"], r.target), n(r.stock_mode), named(sheets["tracking_gate"], r.gate.kind), n(r.gate.until),
			n(r.gate.min_distance), n(r.rate.normal), n(r.rate.late), n(r.rate.air), n(r.rate.late_from), n(r.rate.frames),
			named(sheets["tracking_halving"], r.rate.halving), n(r.rate.by_distance),
			n(r.limit.total), n(r.limit.sweep[0]), n(r.limit.sweep[1]), n(r.limit.sweep[2]), n(r.limit.sweep[3]),
			named(when_, r.end.yaw_when), named(when_, r.end.pivot_when), n(r.end.grace), named(phase, r.end.phase))
	}
	for o, i in t.overrides {
		db.insert(w, "tracking_override", row_key(char, "tracking_override", i), char, row_key(char, "tracking_row", o.row),
			row_key(char, "tracking_row", o.far_row), named(far, o.far_source), n(o.far_angle))
	}
	for f, i in t.fixed {
		db.insert(w, "tracking_fixed", char, n(i), row_key(char, "tracking_row", f.row), row_key(char, "tracking_row", f.far_row),
			named(far, f.far_source), n(f.far_angle))
	}
}

@(private = "file")
write_props :: proc(w: ^db.Writer, k: ^Keys, list: List, m: formats.Motbin) {
	for x, i in (list == .Start_Prop ? m.start_props : m.end_props) {
		key, pos := in_list(w, k, list, i)
		if is_end(m, list, i) do continue
		id := u16(x.unk_04 >> 16)
		params := param_values(k, id, u16(x.unk_04 & 0xffff))
		values := make([dynamic]db.Value)
		append(&values, key, pos, list_ref(k, .Requirement, x.requirements), n(id))
		append(&values, ..params[:])
		db.insert(w, LIST_TABLES[list], ..values[:])
	}
}

// The loader ends each list of LOADER_ENDS with an end row, so the game's lists must end with one too; only the last
// list of a table may run into the end of the table, where the game reads a zero row.
@(private = "file")
check_list_ends :: proc(k: ^Keys, m: formats.Motbin) -> (err: string) {
	for list in LOADER_ENDS {
		keys := k.lists[list]
		for i in 0 ..< len(keys) - 1 do if keys[i + 1] != "" && !is_end(m, list, i) {
			return fmt.tprintf("%s %s %d: the list runs into the next one", k.char, LIST_TABLES[list], i)
		}
	}
	return ""
}

n :: proc(v: $T) -> db.Value {return i64(v)}

// The name of a code in its name sheet; NULL when the sheet has none, so the row fails NOT NULL.
named :: proc(names: map[i64]string, code: $T) -> db.Value {
	if name, ok := names[i64(code)]; ok do return name
	return db.Null{}
}
