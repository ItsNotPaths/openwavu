// Move set (motbin, "COM" file), big endian: 0x270-byte header, then 25 tables. tk6decomp docs/data.md
// "Motbin", "Loader", "Move record". Records stay at their game index; index fields stay indices.
package tk6_formats

import tk5 "../tk5"

HEADER_SIZE :: 0x270  // header offsets are relative to the end of the header
ALIAS_COUNT :: 69
TABLE_LIST :: 0x174
BANK_LIST :: 0x23c
BANK_COUNT :: 6

REQUIREMENT_LIST_END :: 0x18d
// Cancel command high half (command >> 32).
CANCEL_LIST_END :: 0x8000
GROUP_CANCEL_JUMP :: 0x800b    // to group_cancels[move] [guess: data]
GROUP_CANCEL_RETURN :: 0x800c  // ends a group cancel list [guess: data]
INPUT_SEQUENCE_FIRST :: 0x800d // and up: input_sequences[high half - this] [guess: data]
// Animation id bank bits; the low 14 bits index the bank.
CONTAINER_BANK :: 0x4000
COMMON_BANK :: 0x8000
ANIM_INDEX :: 0x3fff

// Header table order. Embedded_Bank is "table 25": the MOTA bank embedded animation ids index.
Table :: enum {
	Reactions, Requirements, Hit_Conditions, Pushbacks, Pushback_Extras, Cancels, Group_Cancels, Cancel_Extras,
	Extra_Properties, Start_Properties, End_Properties, Moves, Voiceclips, Input_Sequences, Input_Extras,
	Table_16, Table_17, Table_18, Move_List, Table_20, Table_21, Table_22, Table_23, Table_24, Embedded_Bank,
}

// 0: not known (tables 20..22 are empty in every retail file).
@(rodata)
RECORD_SIZES := [Table]int {
	.Reactions = 0x50, .Requirements = 8, .Hit_Conditions = 0xc, .Pushbacks = 0xc, .Pushback_Extras = 2,
	.Cancels = 0x20, .Group_Cancels = 0x20, .Cancel_Extras = 4, .Extra_Properties = 0xc, .Start_Properties = 0xc,
	.End_Properties = 0xc, .Moves = 0x58, .Voiceclips = 4, .Input_Sequences = 8, .Input_Extras = 8, .Table_16 = 4,
	.Table_17 = 0x14, .Table_18 = 6, .Move_List = 0x40, .Table_20 = 0, .Table_21 = 0, .Table_22 = 0,
	.Table_23 = 0xc, .Table_24 = 8, .Embedded_Bank = 0,
}

Table_Place :: struct {
	start, count: int,  // start from the start of the data
}

Motbin :: struct {
	unknown_00:                     u16,  // the loader resolves animations only for 0..14 and 17
	loaded:                         u8,   // the loader's done flag
	drop_names:                     u8,   // set in every retail file: the loader drops the move names
	name, creator, date, full_date: string,
	aliases:                        [ALIAS_COUNT]u16,  // move 0x8000+n -> aliases[n]
	aliases_copy:                   [ALIAS_COUNT]u16,
	unknown_12c:                    []byte,  // header 0x12c..0x174
	tables:                         [Table]Table_Place,
	banks:                          [BANK_COUNT]int,  // header 0x23c, from the start of the data
	embedded_animation_count:       int,

	reactions:          []tk5.Reaction,
	requirements:       []Requirement,       // list ends at REQUIREMENT_LIST_END
	hit_conditions:     []tk5.Hit_Condition,
	pushbacks:          []tk5.Pushback,
	pushback_extras:    []u16,
	cancels:            []Cancel,            // list ends at CANCEL_LIST_END
	group_cancels:      []Cancel,            // list ends at GROUP_CANCEL_RETURN
	cancel_extras:      []u32,
	extra_properties:   []Extra_Property,    // list ends at a zero row
	start_properties:   []Property,          // list ends at id REQUIREMENT_LIST_END [guess: data]
	end_properties:     []Property,
	moves:              []Move,
	voiceclips:         []u32,               // list ends at 0xffffffff
	input_sequences:    []tk5.Input_Sequence, // inputs: input_extras index
	input_extras:       []Input_Extra,
	table_16:           []u32,
	table_17:           []Table_17_Entry,
	table_18:           [][3]u16,
	move_list:          []Move_List_Entry,
	unknown_tables:     [3][]byte,  // tables 20..22: the bytes up to the next table
	table_23:           [][3]u32,   // extra property shape
	table_24:           []Table_24_Entry,
}

Requirement :: struct {
	id, parameter: u32,
}

Cancel :: struct {
	command:        u64,
	requirements:   u32,  // requirement list
	extra:          u32,  // cancel_extras index
	window_start:   u32,
	window_end:     u32,
	starting_frame: u32,
	move:           u16,
	option:         u16,  // as stored; the loader recomputes it
}

Extra_Property :: struct {
	frame, id, value: u32,  // frame 0x8001 = frame 1
}

Property :: struct {
	requirements: u32,  // requirement list
	id, value:    u32,
}

Move :: struct {
	name, animation_name: u32,  // heap pointers of the convert tool, not offsets; the loader drops them
	animation:            u32,  // CONTAINER_BANK or COMMON_BANK bit, else the embedded bank
	vulnerability:        u32,
	hit_level:            u32,
	cancels:              u32,  // cancel list
	transition:           u16,
	unknown_1a:           u16,
	unknown_1c:           u32,
	hit_conditions:       u32,  // hit condition list
	animation_length:     u16,  // 0 in the file; the loader fills it
	unknown_26:           u16,
	unknown_28:           [3]u32,
	voiceclips:           i32,  // -1: none
	extra_properties:     i32,
	start_properties:     i32,
	end_properties:       i32,
	flags:                u32,  // as stored, before the loader reverses bits 6..30
	unknown_48:           [4]u32,
}

Input_Extra :: struct {
	unknown_00, unknown_04: u32,
}

Table_17_Entry :: struct {
	unknown_00: [4]u32,
	table_18:   u32,  // table_18 index
}

Table_24_Entry :: struct {
	unknown_00: u32,
	table_23:   u32,  // table_23 index
}

// Pause menu entry. UTF-8, button glyphs in U+E0xx.
Move_List_Entry :: struct {
	name_japanese, name_english, name_reading: string,
	commands:                                  [8]string,
	name_chinese:                              string,  // [guess]
	unknown_30:                                [4]u32,
}

is_motbin :: proc(data: []byte) -> bool {
	return len(data) >= HEADER_SIZE && tk5.be_u32(data, 0) == 1 && string(data[4:8]) == "COM\x00"
}

// Strings and unknown byte runs point into `data`.
read_motbin :: proc(data: []byte, allocator := context.allocator) -> (motbin: Motbin, ok: bool) {
	context.allocator = allocator
	if !is_motbin(data) do return
	motbin.unknown_00 = tk5.be_u16(data, 0)
	motbin.loaded, motbin.drop_names = data[2], data[3]
	motbin.name = motbin_string(data, tk5.be_u32(data, 0x08)) or_return
	motbin.creator = motbin_string(data, tk5.be_u32(data, 0x0c)) or_return
	motbin.date = motbin_string(data, tk5.be_u32(data, 0x10)) or_return
	motbin.full_date = motbin_string(data, tk5.be_u32(data, 0x14)) or_return
	for &alias, number in motbin.aliases do alias = tk5.be_u16(data, 0x18 + number * 2)
	for &alias, number in motbin.aliases_copy do alias = tk5.be_u16(data, 0xa2 + number * 2)
	motbin.unknown_12c = data[0x12c:TABLE_LIST]
	for &place, which in motbin.tables {
		header := TABLE_LIST + int(which) * 8
		place = {HEADER_SIZE + int(tk5.be_u32(data, header)), int(tk5.be_u32(data, header + 4))}
	}
	for &bank, number in motbin.banks do bank = HEADER_SIZE + int(tk5.be_u32(data, BANK_LIST + number * 8))
	motbin.embedded_animation_count = mota_count(data, motbin.tables[.Embedded_Bank].start) or_return

	records: []byte
	records = table(&motbin, data, .Reactions, &motbin.reactions) or_return
	for &reaction, number in motbin.reactions {
		record := records[number * 0x50:]
		for &pushback, slot in reaction.pushbacks do pushback = tk5.be_u32(record, slot * 4)
		for &unknown, slot in reaction.unk_1c do unknown = tk5.be_u16(record, 0x1c + slot * 2)
		reaction.vertical_pushback, reaction.unk_32 = tk5.be_u16(record, 0x30), tk5.be_u16(record, 0x32)
		moves := [14]^u16{
			&reaction.move_standing, &reaction.move_crouch, &reaction.move_counter, &reaction.move_crouch_counter,
			&reaction.move_left, &reaction.move_left_crouch, &reaction.move_right, &reaction.move_right_crouch,
			&reaction.move_back, &reaction.move_back_crouch, &reaction.move_block, &reaction.move_crouch_block,
			&reaction.move_wall_slump, &reaction.move_down,
		}
		for move, slot in moves do move^ = tk5.be_u16(record, 0x34 + slot * 2)
	}

	records = table(&motbin, data, .Requirements, &motbin.requirements) or_return
	for &requirement, number in motbin.requirements {
		requirement = {tk5.be_u32(records, number * 8), tk5.be_u32(records, number * 8 + 4)}
	}

	records = table(&motbin, data, .Hit_Conditions, &motbin.hit_conditions) or_return
	for &condition, number in motbin.hit_conditions {
		record := records[number * 0xc:]
		condition = {tk5.be_u32(record, 0), tk5.be_u16(record, 4), tk5.be_u16(record, 6), tk5.be_u32(record, 8)}
	}

	records = table(&motbin, data, .Pushbacks, &motbin.pushbacks) or_return
	for &pushback, number in motbin.pushbacks {
		record := records[number * 0xc:]
		pushback = {
			tk5.be_u16(record, 0), tk5.be_u16(record, 2), tk5.be_u16(record, 4), tk5.be_u16(record, 6),
			tk5.be_u32(record, 8),
		}
	}

	records = table(&motbin, data, .Pushback_Extras, &motbin.pushback_extras) or_return
	for &extra, number in motbin.pushback_extras do extra = tk5.be_u16(records, number * 2)

	records = table(&motbin, data, .Cancels, &motbin.cancels) or_return
	for &cancel, number in motbin.cancels do cancel = read_cancel(records[number * 0x20:])
	records = table(&motbin, data, .Group_Cancels, &motbin.group_cancels) or_return
	for &cancel, number in motbin.group_cancels do cancel = read_cancel(records[number * 0x20:])

	records = table(&motbin, data, .Cancel_Extras, &motbin.cancel_extras) or_return
	for &extra, number in motbin.cancel_extras do extra = tk5.be_u32(records, number * 4)

	records = table(&motbin, data, .Extra_Properties, &motbin.extra_properties) or_return
	for &property, number in motbin.extra_properties {
		record := records[number * 0xc:]
		property = {tk5.be_u32(record, 0), tk5.be_u32(record, 4), tk5.be_u32(record, 8)}
	}
	records = table(&motbin, data, .Start_Properties, &motbin.start_properties) or_return
	for &property, number in motbin.start_properties do property = read_property(records[number * 0xc:])
	records = table(&motbin, data, .End_Properties, &motbin.end_properties) or_return
	for &property, number in motbin.end_properties do property = read_property(records[number * 0xc:])

	records = table(&motbin, data, .Moves, &motbin.moves) or_return
	for &move, number in motbin.moves {
		record := records[number * 0x58:]
		move = {
			name = tk5.be_u32(record, 0x00), animation_name = tk5.be_u32(record, 0x04),
			animation = tk5.be_u32(record, 0x08), vulnerability = tk5.be_u32(record, 0x0c),
			hit_level = tk5.be_u32(record, 0x10), cancels = tk5.be_u32(record, 0x14),
			transition = tk5.be_u16(record, 0x18), unknown_1a = tk5.be_u16(record, 0x1a),
			unknown_1c = tk5.be_u32(record, 0x1c), hit_conditions = tk5.be_u32(record, 0x20),
			animation_length = tk5.be_u16(record, 0x24), unknown_26 = tk5.be_u16(record, 0x26),
			voiceclips = tk5.be_i32(record, 0x34), extra_properties = tk5.be_i32(record, 0x38),
			start_properties = tk5.be_i32(record, 0x3c), end_properties = tk5.be_i32(record, 0x40),
			flags = tk5.be_u32(record, 0x44),
		}
		for &unknown, slot in move.unknown_28 do unknown = tk5.be_u32(record, 0x28 + slot * 4)
		for &unknown, slot in move.unknown_48 do unknown = tk5.be_u32(record, 0x48 + slot * 4)
	}

	records = table(&motbin, data, .Voiceclips, &motbin.voiceclips) or_return
	for &voiceclip, number in motbin.voiceclips do voiceclip = tk5.be_u32(records, number * 4)

	records = table(&motbin, data, .Input_Sequences, &motbin.input_sequences) or_return
	for &sequence, number in motbin.input_sequences {
		record := records[number * 8:]
		sequence = {tk5.be_u16(record, 0), tk5.be_u16(record, 2), tk5.be_u32(record, 4)}
	}
	records = table(&motbin, data, .Input_Extras, &motbin.input_extras) or_return
	for &extra, number in motbin.input_extras {
		extra = {tk5.be_u32(records, number * 8), tk5.be_u32(records, number * 8 + 4)}
	}

	records = table(&motbin, data, .Table_16, &motbin.table_16) or_return
	for &entry, number in motbin.table_16 do entry = tk5.be_u32(records, number * 4)
	records = table(&motbin, data, .Table_17, &motbin.table_17) or_return
	for &entry, number in motbin.table_17 {
		record := records[number * 0x14:]
		for &unknown, slot in entry.unknown_00 do unknown = tk5.be_u32(record, slot * 4)
		entry.table_18 = tk5.be_u32(record, 0x10)
	}
	records = table(&motbin, data, .Table_18, &motbin.table_18) or_return
	for &entry, number in motbin.table_18 do for &value, slot in entry do value = tk5.be_u16(records, number * 6 + slot * 2)

	records = table(&motbin, data, .Move_List, &motbin.move_list) or_return
	for &entry, number in motbin.move_list {
		record := records[number * 0x40:]
		text: [12]string
		for &line, slot in text do line = motbin_string(data, tk5.be_u32(record, slot * 4)) or_return
		entry.name_japanese, entry.name_english, entry.name_reading = text[0], text[1], text[2]
		copy(entry.commands[:], text[3:11])
		entry.name_chinese = text[11]
		for &unknown, slot in entry.unknown_30 do unknown = tk5.be_u32(record, 0x30 + slot * 4)
	}

	for &bytes, slot in motbin.unknown_tables {
		start := motbin.tables[Table(int(Table.Table_20) + slot)].start
		end := motbin.tables[Table(int(Table.Table_20) + slot + 1)].start
		if start > end || end > len(data) do return
		bytes = data[start:end]
	}

	records = table(&motbin, data, .Table_23, &motbin.table_23) or_return
	for &entry, number in motbin.table_23 do for &value, slot in entry do value = tk5.be_u32(records, number * 0xc + slot * 4)
	records = table(&motbin, data, .Table_24, &motbin.table_24) or_return
	for &entry, number in motbin.table_24 do entry = {tk5.be_u32(records, number * 8), tk5.be_u32(records, number * 8 + 4)}
	return motbin, true
}

// Animation count of the MOTA bank at `start`: "MOTA", u32, u32 offset table start (0x14), u32 count.
mota_count :: proc(data: []byte, start: int) -> (count: int, ok: bool) {
	if start < 0 || start + 0x14 > len(data) || string(data[start:][:4]) != "MOTA" do return
	return int(tk5.be_u32(data, start + 0xc)), true
}

// Makes `output` from the table's header pair; returns the table bytes.
@(private = "file")
table :: proc(motbin: ^Motbin, data: []byte, which: Table, output: ^[]$Record) -> (records: []byte, ok: bool) {
	place := motbin.tables[which]
	size := RECORD_SIZES[which]
	if place.start + place.count * size > len(data) do return nil, false
	output^ = make([]Record, place.count)
	return data[place.start:][:place.count * size], true
}

@(private = "file")
read_cancel :: proc(record: []byte) -> Cancel {
	return {
		u64(tk5.be_u32(record, 0x00)) << 32 | u64(tk5.be_u32(record, 0x04)), tk5.be_u32(record, 0x08),
		tk5.be_u32(record, 0x0c), tk5.be_u32(record, 0x10), tk5.be_u32(record, 0x14), tk5.be_u32(record, 0x18),
		tk5.be_u16(record, 0x1c), tk5.be_u16(record, 0x1e),
	}
}

@(private = "file")
read_property :: proc(record: []byte) -> Property {
	return {tk5.be_u32(record, 0), tk5.be_u32(record, 4), tk5.be_u32(record, 8)}
}

@(private)
motbin_string :: proc(data: []byte, offset: u32) -> (string, bool) {
	start := HEADER_SIZE + int(offset)
	if start >= len(data) do return "", false
	return tk5.cstring_at(data, start), true
}
