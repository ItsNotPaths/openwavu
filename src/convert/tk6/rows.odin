// The rows of src/db/tk6/schema.sql from a motbin in sim numbers (sim_motbin). Values stay at their TK6 width.
package tk6_convert

import "core:fmt"
import "../../db"
import formats "../../formats/tk6"
import tk5_convert "../tk5"
import tk5_formats "../../formats/tk5"

@(private = "file")
List :: tk5_convert.List

@(private = "file")
Keys :: struct {
	using list_keys: tk5_convert.List_Keys,
	moves:           []string,
}

// Move flag columns by TK6 bit (schema move); bit 10 is move_ai.ai_follow_up_input.
FLAG_FOLLOW_UP_INPUT :: 10
@(rodata)
// (hole tk6-move-flags :tags (tk6 sim) :sev gap) the TK6 move flag bit to TK5 meaning map is a guess from data, seven bits stay unknown, and Xiaoyu's rides_partner is written as 0.
FLAG_COLUMNS := [32]string{
	"unknown_flag_0", "unknown_flag_1", "keeps_hips", "turns_at_end", "looks_at_opponent", "follows_floor", "unknown_flag_6",
	"blends_in_active", "unknown_flag_8", "reaction_continues", "", "practice_dummy_recovery", "unknown_flag_12",
	"string_move", "keeps_took_damage", "unknown_flag_15", "grounded_reaction", "unknown_flag_17", "forces_sword_trail",
	"no_sword_trail", "no_start_shift", "holds_face_expression", "keeps_root_yaw", "thrown_stays", "starts_on_partner",
	"throw_resync", "sets_hurt_lying", "no_leg_push", "guard_by_input", "hit_reaction", "no_blend_out", "no_blend_in",
}
UNKNOWN_STATE_BITS :: [?]u32{18, 20, 24}
UNKNOWN_ATTACK_BITS :: [?]u32{17, 23}
SIDE_BANDS :: 8  // header 0x12c, 4 u16 each

@(private)
write_rows :: proc(w: ^db.Writer, character, animation_owner: string, m: formats.Motbin, fallbacks: ^Fallbacks) -> (error: string) {
	keys := keys_of(character, m)
	tracking := seed_tracking(m)
	sheets := db.name_sheets(w)
	db.insert(w, "motbin", character, n(m.unknown_00), transmute([]byte)m.name, transmute([]byte)m.creator, m.date, m.full_date,
		m.unknown_12c)
	for target, slot in m.aliases {
		move, _ := move_ref(&keys, target)
		db.insert(w, "move_alias", character, n(slot), move)
	}
	if error = write_moves(w, &keys, animation_owner, sheets, m, &tracking, fallbacks); error != "" do return
	write_cancels(w, &keys, sheets, .Cancel, m, m.cancels, tracking.cancel_pick)
	write_cancels(w, &keys, sheets, .Group_Cancel, m, m.group_cancels, tracking.group_pick)
	for requirement, index in m.requirements {
		list, pos := tk5_convert.in_list(w, &keys, .Requirement, index)
		if is_end(m, .Requirement, index) {
			if requirement.parameter != 0 do return fmt.tprintf("%s requirement %d: an end row with param %d", character, index, requirement.parameter)
			continue  // the loader adds it
		}
		values := make([dynamic]db.Value)
		append(&values, list, pos, n(requirement.id))
		parameters := parameter_values(&keys, requirement.id, requirement.parameter)
		append(&values, ..parameters[:])
		db.insert(w, "requirement", ..values[:])
	}
	for condition, index in m.hit_conditions {
		list, pos := tk5_convert.in_list(w, &keys, .Hit_Condition, index)
		db.insert(w, "hit_condition", list, pos, tk5_convert.list_ref(&keys, .Requirement, condition.requirements),
			n(condition.unk_06), row_key(character, "reaction", condition.reaction))  // damage word at +6 (+4 is 0 in every file)
	}
	for reaction, index in m.reactions {
		values := make([dynamic]db.Value)
		append(&values, row_key(character, "reaction", index), character)
		for pushback in reaction.pushbacks do append(&values, row_key(character, "pushback", pushback))
		for word in reaction.unk_1c do append(&values, n(word))  // angle 0..5, yaw 0..3
		append(&values, n(reaction.vertical_pushback), n(reaction.unk_32))  // yaw 4, 5
		moves := [14]u16{reaction.move_standing, reaction.move_crouch, reaction.move_counter, reaction.move_crouch_counter,
			reaction.move_left, reaction.move_left_crouch, reaction.move_right, reaction.move_right_crouch, reaction.move_back,
			reaction.move_back_crouch, reaction.move_block, reaction.move_crouch_block, reaction.move_wall_slump, reaction.move_down}
		aliases: [len(moves)]db.Value
		for id, slot in moves {
			move: db.Value
			move, aliases[slot] = move_ref(&keys, id)
			append(&values, move)
		}
		append(&values, ..aliases[:])
		db.insert(w, "reaction", ..values[:])
	}
	for pushback, index in m.pushbacks {
		db.insert(w, "pushback", row_key(character, "pushback", index), character, n(pushback.unk_00), n(pushback.unk_02),
			n(pushback.unk_04), n(pushback.unk_06), tk5_convert.list_ref(&keys, .Pushback_Curve, pushback.extras))
	}
	for value, index in m.pushback_extras {
		list, pos := tk5_convert.in_list(w, &keys, .Pushback_Curve, index)
		db.insert(w, "pushback_curve", list, pos, n(value))
	}
	for property, index in m.extra_properties {
		list, pos := tk5_convert.in_list(w, &keys, .Extra_Prop, index)
		if is_end(m, .Extra_Prop, index) {
			if property != {} do return fmt.tprintf("%s extra property %d: an end row with values", character, index)
			continue
		}
		value := property.value
		if property.id == tk5_convert.PROP_FACING_MODE do value = u32(tk5_convert.row_index(&tracking, int(value)))
		values := make([dynamic]db.Value)
		append(&values, list, pos, n(property.frame), n(property.id))
		parameters := parameter_values(&keys, property.id, value)
		append(&values, ..parameters[:])
		db.insert(w, "extra_prop", ..values[:])
	}
	tk5_convert.write_tracking(w, character, sheets, &tracking)
	write_move_cameras(w, &keys, animation_owner, m)
	write_conditional_properties(w, &keys, .Start_Prop, m.start_properties)
	write_conditional_properties(w, &keys, .End_Prop, m.end_properties)
	for clip, index in m.voiceclips {
		list, pos := tk5_convert.in_list(w, &keys, .Voiceclip, index)
		if !is_end(m, .Voiceclip, index) do db.insert(w, "voiceclip", list, pos, n(clip))
	}
	for compare_id, index in m.table_16 {
		list, pos := tk5_convert.in_list(w, &keys, .Move_Pool, index)
		if !is_end(m, .Move_Pool, index) do db.insert(w, "move_pool", list, pos, n(compare_id))
	}
	for entry, slot in m.move_list {
		values := make([dynamic]db.Value)
		append(&values, character, n(slot), entry.name_japanese, entry.name_english, entry.name_reading)
		for text in entry.commands do append(&values, text)
		append(&values, entry.name_chinese)
		for word in entry.unknown_30 do append(&values, n(word))
		db.insert(w, "command_list", ..values[:])
	}
	for band in 0 ..< SIDE_BANDS {
		bytes := m.unknown_12c[band * 8:]
		db.insert(w, "side_band", character, n(band), n(tk5_formats.be_u16(bytes, 0)), n(tk5_formats.be_u16(bytes, 2)),
			n(tk5_formats.be_u16(bytes, 4)), n(tk5_formats.be_u16(bytes, 6)))
	}
	write_unknown_tables(w, character, m)
	return check_list_ends(&keys, m)
}

@(private = "file")
write_moves :: proc(w: ^db.Writer, keys: ^Keys, animation_owner: string, sheets: map[string]map[i64]string, m: formats.Motbin,
	tracking: ^tk5_convert.Tracking, fallbacks: ^Fallbacks) -> (error: string) {
	character := keys.char
	for move, index in m.moves {
		words := [tk5_convert.Move_Word]u32{.Vuln = move.vulnerability, .Hit_Level = move.hit_level, .Flags = move.flags}
		if left := unnamed_bits(words); left != {} do return fmt.tprintf("%s move %d: bits with no column %v", character, index, left)
		sim_codes := hitbox_of(move.unknown_48[0], fallbacks)
		hits, hits_ok := tk5_convert.hitbox_hits(sim_codes, NO_MOVESET)
		if !hits_ok do return fmt.tprintf("%s move %d: a hitbox on a special slot its row leaves unwritten", character, index)
		special_pairs(&hits, move.unknown_48[0])
		owner, animation_index := tk5_convert.anim_ref(character, animation_owner, move.animation)
		next, next_alias := move_ref(keys, move.transition)
		values := make([dynamic]db.Value)
		append(&values, keys.moves[index], character, fmt.tprintf("move_%d", index), db.Null{}, owner, n(animation_index), n(move.animation),
			tk5_convert.named(sheets["state_class"], words[.Vuln] >> tk5_convert.STATE_CLASS_SHIFT & 31))
		for bit in tk5_convert.STATE_BITS do append(&values, n(words[.Vuln] >> bit & 1))
		for bit in UNKNOWN_STATE_BITS do append(&values, n(words[.Vuln] >> bit & 1))
		append(&values, tk5_convert.named(sheets["attack_kind"], words[.Hit_Level] >> tk5_convert.ATTACK_KIND_SHIFT & 0xff))
		for bit in tk5_convert.ATTACK_BITS do append(&values, n(words[.Hit_Level] >> bit & 1))
		for bit in UNKNOWN_ATTACK_BITS do append(&values, n(words[.Hit_Level] >> bit & 1))
		window_start, window_end, hold_frame := move.unknown_28[0], move.unknown_28[1], move.unknown_28[2]
		hitbox, first_active, last_active, push := move.unknown_48[0], move.unknown_48[1], move.unknown_48[2], move.unknown_48[3]
		append(&values, tk5_convert.list_ref(keys, .Cancel, move.cancels), next, next_alias, n(move.unknown_1a), n(move.unknown_1c),
			n(push & 0xffff), tk5_convert.list_ref(keys, .Hit_Condition, move.hit_conditions), n(window_start), n(window_end),
			n(hold_frame), tk5_convert.list_ref(keys, .Voiceclip, move.voiceclips), tk5_convert.list_ref(keys, .Extra_Prop, move.extra_properties),
			tk5_convert.list_ref(keys, .Start_Prop, move.start_properties), tk5_convert.list_ref(keys, .End_Prop, move.end_properties))
		for column, bit in FLAG_COLUMNS do if column != "" do append(&values, n(move.flags >> u32(bit) & 1))
		default := tracking.default[index]
		append(&values, n(hitbox_bones(hitbox)), n(first_active), n(last_active), n(push >> 16),
			row_key(character, "tracking_row", default.row), row_key(character, "tracking_row", default.far_row),
			tk5_convert.named(sheets["tracking_far_source"], default.far_source), n(default.far_angle), n(0))
		kinds := sheets["hit_point_kind"]
		for pair in hits.pairs {
			append(&values, tk5_convert.named(kinds, pair.end.kind), n(pair.end.index), tk5_convert.named(kinds, pair.start.kind), n(pair.start.index))
		}
		append(&values, n(hits.attack_bones), n(hits.slots), n(hits.launches))
		db.insert(w, "move", ..values[:])

		ai := make([dynamic]db.Value)
		append(&ai, keys.moves[index])
		set := false
		for bit in tk5_convert.AI_BITS {
			value := bit.word == .Flags ? words[.Flags] >> FLAG_FOLLOW_UP_INPUT & 1 : words[bit.word] >> bit.bit & 1
			set ||= value != 0
			append(&ai, n(value))
		}
		if set do db.insert(w, "move_ai", ..ai[:])
	}
	return
}

NO_MOVESET :: -1  // not a TK5 move set: no TK5 special hitbox points

// The bits of each word that no column holds.
@(private = "file")
unnamed_bits :: proc(words: [tk5_convert.Move_Word]u32) -> (left: [tk5_convert.Move_Word]u32) {
	known: [tk5_convert.Move_Word]u32
	known[.Vuln] = 31 << tk5_convert.STATE_CLASS_SHIFT
	known[.Hit_Level] = 0xff << tk5_convert.ATTACK_KIND_SHIFT
	known[.Flags] = 0xffffffff
	for bit in tk5_convert.STATE_BITS do known[.Vuln] |= 1 << bit
	for bit in UNKNOWN_STATE_BITS do known[.Vuln] |= 1 << bit
	for bit in tk5_convert.ATTACK_BITS do known[.Hit_Level] |= 1 << bit
	for bit in UNKNOWN_ATTACK_BITS do known[.Hit_Level] |= 1 << bit
	for bit in tk5_convert.AI_BITS do if bit.word != .Flags do known[bit.word] |= 1 << bit.bit
	for word in tk5_convert.Move_Word do left[word] = words[word] &~ known[word]
	return
}

@(private = "file")
write_cancels :: proc(w: ^db.Writer, keys: ^Keys, sheets: map[string]map[i64]string, list: List, m: formats.Motbin,
	cancels: []formats.Cancel, picks: []u16) {
	transition_sheets := tk5_convert.TRANSITION_SHEETS
	for cancel, index in cancels {
		key, pos := tk5_convert.in_list(w, keys, list, index)
		kind, input, _ := cancel_input(m, cancel)
		code := u32(cancel.command >> 32)
		move, alias := move_ref(keys, cancel.move)
		kind_value, stick, group_list, tracking: db.Value = db.Null{}, db.Null{}, db.Null{}, db.Null{}
		if kind != "" do kind_value = kind
		if code >= COMMAND_STICK_FIRST && code <= COMMAND_STICK_LAST do stick = tk5_convert.named(sheets["stick_test"], code)
		if kind == "group" do move, alias, group_list = db.Null{}, db.Null{}, tk5_convert.list_ref(keys, .Group_Cancel, cancel.move)
		if picks[index] != 0 do tracking = row_key(keys.char, "tracking_override", picks[index] - 1)  // the game counts picks from 1
		extra := m.cancel_extras[cancel.extra]
		values := make([dynamic]db.Value)
		append(&values, key, pos, kind_value, input, stick, tk5_convert.list_ref(keys, .Requirement, cancel.requirements), move, alias, group_list)
		for field, place in tk5_convert.TRANSITION_FIELDS {
			append(&values, tk5_convert.named(sheets[transition_sheets[place]], extra >> field.shift & (1 << field.bits - 1)))
		}
		for flag in tk5_convert.EXTRA_FLAGS do append(&values, n(extra & flag != 0))
		append(&values, tracking)
		db.insert(w, tk5_convert.LIST_TABLES[list], ..values[:])
	}
}

@(private = "file")
write_conditional_properties :: proc(w: ^db.Writer, keys: ^Keys, list: List, properties: []formats.Property) {
	for property, index in properties {
		key, pos := tk5_convert.in_list(w, keys, list, index)
		if property.id == REQUIREMENT_LIST_END do continue
		values := make([dynamic]db.Value)
		append(&values, key, pos, tk5_convert.list_ref(keys, .Requirement, property.requirements), n(property.id))
		parameters := parameter_values(keys, property.id, property.value)
		append(&values, ..parameters[:])
		db.insert(w, tk5_convert.LIST_TABLES[list], ..values[:])
	}
}

// Camera shots of moves: the first move camera property of a move's list.
@(private = "file")
write_move_cameras :: proc(w: ^db.Writer, keys: ^Keys, animation_owner: string, m: formats.Motbin) {
	for move, index in m.moves {
		if move.extra_properties < 0 do continue
		for property in m.extra_properties[move.extra_properties:] {
			if property.frame == 0 do break
			if property.id != tk5_convert.PROP_MOVE_CAMERA do continue
			owner := property.value & tk5_convert.CONTAINER_BANK != 0 ? animation_owner : tk5_convert.embedded_owner(keys.char)
			db.insert(w, "move_camera", keys.moves[index], fmt.tprintf("%s/cameras", owner), n(property.value &~ tk5_convert.CONTAINER_BANK),
				n(property.frame & tk5_convert.FRAME_CODE))
			break
		}
	}
}

// Tables not decoded yet, as the file stores them; an empty one has no row.
@(private = "file")
write_unknown_tables :: proc(w: ^db.Writer, character: string, m: formats.Motbin) {
	put :: proc(bytes: ^[dynamic]byte, word: $T) {
		for shift := 8 * (size_of(T) - 1); shift >= 0; shift -= 8 do append(bytes, byte(word >> uint(shift)))
	}
	write :: proc(w: ^db.Writer, character: string, table: formats.Table, count: int, bytes: []byte) {
		if len(bytes) > 0 do db.insert(w, "unknown_table", character, n(formats.TABLE_LIST + 8 * int(table)), n(count), bytes)
	}
	table_17, table_18, table_23, table_24: [dynamic]byte
	for entry in m.table_17 {
		for word in entry.unknown_00 do put(&table_17, word)
		put(&table_17, entry.table_18)
	}
	for entry in m.table_18 do for value in entry do put(&table_18, value)
	for entry in m.table_23 do for value in entry do put(&table_23, value)
	for entry in m.table_24 {
		put(&table_24, entry.unknown_00)
		put(&table_24, entry.table_23)
	}
	write(w, character, .Table_17, len(m.table_17), table_17[:])
	write(w, character, .Table_18, len(m.table_18), table_18[:])
	for bytes, slot in m.unknown_tables {
		table := formats.Table(int(formats.Table.Table_20) + slot)
		write(w, character, table, m.tables[table].count, bytes)
	}
	write(w, character, .Table_23, len(m.table_23), table_23[:])
	write(w, character, .Table_24, len(m.table_24), table_24[:])
}

// The game's end row of a list. Counted lists (pushback curves, input extras) and hit conditions have none.
@(private = "file")
is_end :: proc(m: formats.Motbin, list: List, index: int) -> bool {
	#partial switch list {
	case .Cancel: return m.cancels[index].command >> 32 == COMMAND_END
	case .Group_Cancel: return m.group_cancels[index].command >> 32 == COMMAND_GROUP_END
	case .Requirement: return m.requirements[index].id == REQUIREMENT_LIST_END
	case .Extra_Prop: return m.extra_properties[index].frame == 0
	case .Start_Prop: return m.start_properties[index].id == REQUIREMENT_LIST_END
	case .End_Prop: return m.end_properties[index].id == REQUIREMENT_LIST_END
	case .Voiceclip: return m.voiceclips[index] == VOICECLIP_END
	case .Move_Pool: return m.table_16[index] == 0
	}
	return false
}

// Moves have no names in the file: a move's key is its index.
@(private = "file")
keys_of :: proc(character: string, m: formats.Motbin) -> (keys: Keys) {
	keys.char = character
	keys.moves = make([]string, len(m.moves))
	for &key, index in keys.moves do key = row_key(character, "move", index)
	counts := [List]int{
		.Cancel = len(m.cancels), .Group_Cancel = len(m.group_cancels), .Requirement = len(m.requirements),
		.Hit_Condition = len(m.hit_conditions), .Pushback_Curve = len(m.pushback_extras), .Extra_Prop = len(m.extra_properties),
		.Start_Prop = len(m.start_properties), .End_Prop = len(m.end_properties), .Voiceclip = len(m.voiceclips),
		.Move_Pool = len(m.table_16),
	}
	for count, list in counts do keys.lists[list] = make([]string, count)

	// Lists a move points to take its key.
	for move, index in m.moves {
		tk5_convert.mark(&keys, .Cancel, move.cancels, keys.moves[index])
		tk5_convert.mark(&keys, .Hit_Condition, move.hit_conditions, keys.moves[index])
		tk5_convert.mark(&keys, .Voiceclip, move.voiceclips, keys.moves[index])
		tk5_convert.mark(&keys, .Extra_Prop, move.extra_properties, keys.moves[index])
		tk5_convert.mark(&keys, .Start_Prop, move.start_properties, keys.moves[index])
		tk5_convert.mark(&keys, .End_Prop, move.end_properties, keys.moves[index])
	}
	for pushback, index in m.pushbacks do tk5_convert.mark(&keys, .Pushback_Curve, pushback.extras, row_key(character, "pushback", index))
	for list in ([][]formats.Cancel{m.cancels, m.group_cancels}) do for cancel in list {
		tk5_convert.mark(&keys, .Requirement, cancel.requirements)
		if cancel.command >> 32 == COMMAND_GROUP do tk5_convert.mark(&keys, .Group_Cancel, cancel.move)
	}
	for condition in m.hit_conditions do tk5_convert.mark(&keys, .Requirement, condition.requirements)
	for property in m.start_properties do tk5_convert.mark(&keys, .Requirement, property.requirements)
	for property in m.end_properties do tk5_convert.mark(&keys, .Requirement, property.requirements)
	for requirement in m.requirements {
		if tk5_convert.code_ref(u16(requirement.id)) == "move_pool" do tk5_convert.mark(&keys, .Move_Pool, requirement.parameter)
	}

	// Rows after an end row start a list of their own.
	for list in List {
		for index in 0 ..< len(keys.lists[list]) do if is_end(m, list, index) do tk5_convert.mark(&keys, list, index + 1)
		tk5_convert.mark(&keys, list, 0)
	}
	return
}

// A move id: a move by index, or alias n for 0x8000 + n.
@(private = "file")
move_ref :: proc(keys: ^Keys, id: $T) -> (move, alias: db.Value) {
	if int(id) >= ALIAS_BASE do return db.Null{}, n(int(id) - ALIAS_BASE)
	if int(id) < len(keys.moves) do return keys.moves[id], db.Null{}
	return row_key(keys.char, "move", id), db.Null{}
}

// A requirement param or property value: plain, or in the column of the table its code names (tk5_convert.CODE_REFS).
// Columns: value, move, alias, pushback, tracking_row, move_pool, compare_id.
@(private = "file")
parameter_values :: proc(keys: ^Keys, id, value: u32) -> (values: [7]db.Value) {
	for &cell in values do cell = db.Null{}
	switch tk5_convert.code_ref(u16(id)) {
	case "move": values[1], values[2] = move_ref(keys, value)
	case "pushback": values[3] = row_key(keys.char, "pushback", value)
	case "tracking_row": values[4] = row_key(keys.char, "tracking_row", value)
	case "move_pool": values[5] = tk5_convert.list_ref(keys, .Move_Pool, value)
	case "compare_id": values[6] = n(value)
	case: values[0] = n(value)
	}
	return
}

// The loader ends each list of LOADER_ENDS with an end row, so the game's lists must end with one too; only the last
// list of a table may run into the end of the table, where the game reads a zero row.
@(private = "file")
check_list_ends :: proc(keys: ^Keys, m: formats.Motbin) -> (error: string) {
	for list in tk5_convert.LOADER_ENDS {
		lists := keys.lists[list]
		for index in 0 ..< len(lists) - 1 do if lists[index + 1] != "" && !is_end(m, list, index) {
			return fmt.tprintf("%s %s %d: the list runs into the next one", keys.char, tk5_convert.LIST_TABLES[list], index)
		}
	}
	return ""
}

// The tracking the moves start, from the motion codes of the cancels that lead to them.
@(private = "file")
seed_tracking :: proc(m: formats.Motbin) -> tk5_convert.Tracking {
	seed_cancels :: proc(m: formats.Motbin, cancels: []formats.Cancel) -> []tk5_convert.Seed_Cancel {
		seeds := make([]tk5_convert.Seed_Cancel, len(cancels))
		for cancel, index in cancels {
			kind := tk5_convert.Seed_Kind.Plain
			switch cancel.command >> 32 {
			case COMMAND_END: kind = .End
			case COMMAND_GROUP: kind = .Group
			case COMMAND_GROUP_END: kind = .Group_End
			}
			seeds[index] = {kind, cancel.move, int(m.cancel_extras[cancel.extra] & tk5_convert.MOTION_CODE_MASK)}
		}
		return seeds
	}
	move_cancels := make([]u32, len(m.moves))
	for move, index in m.moves do move_cancels[index] = move.cancels
	aliases := make([]u32, len(m.aliases))
	for target, slot in m.aliases do aliases[slot] = u32(target)
	return tk5_convert.seed_tracking_of({seed_cancels(m, m.cancels), seed_cancels(m, m.group_cancels), move_cancels, aliases}, false)
}

row_key :: tk5_convert.row_key
n :: tk5_convert.n
