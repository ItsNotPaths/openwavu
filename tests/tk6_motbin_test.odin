// Every TK6 move set loads, every index field hits its table and every list ends, so the importer can trust them.
// Needs ../tk6decomp/game; skips without it.
package tests

import "core:os"
import "core:testing"
import tk6 "../src/formats/tk6"

TK6_USRDIR :: "../tk6decomp/game/PS3_GAME/USRDIR"
TK6_ROSTER_SIZE :: 263

@(test)
tk6_roster_indices_hold :: proc(t: ^testing.T) {
	if !os.exists(TK6_USRDIR + "/TEKKEN.psarc") do return
	game, opened := tk6.open_game_files(TK6_USRDIR)
	if !testing.expect(t, opened, "game files not opened") do return
	defer tk6.close_game_files(&game)
	roster, listed := tk6.read_roster(game)
	if !testing.expect(t, listed, "roster not read") do return
	defer tk6.delete_roster(roster)
	testing.expect_value(t, len(roster), TK6_ROSTER_SIZE)

	for entry in roster {
		defer free_all(context.temp_allocator)
		data, read := tk6.read_file(game, entry.index, allocator = context.temp_allocator)
		if !testing.expectf(t, read, "%d %s: file not read", entry.index, entry.name) do continue
		motbin, parsed := tk6.read_motbin(data, context.temp_allocator)
		if !testing.expectf(t, parsed, "%d %s: motbin not read", entry.index, entry.name) do continue
		tables_tile(t, entry, motbin, len(data))
		indices_hold(t, entry, motbin)
		lists_end(t, entry, motbin)
	}
}

// Tables are 4-byte aligned.
@(private = "file")
tables_tile :: proc(t: ^testing.T, entry: tk6.Roster_Entry, motbin: tk6.Motbin, data_size: int) -> bool {
	for which in tk6.Table.Reactions ..< tk6.Table.Embedded_Bank {
		place, next := motbin.tables[which], motbin.tables[tk6.Table(int(which) + 1)].start
		size := tk6.RECORD_SIZES[which]
		if size == 0 do testing.expectf(t, place.count == 0, "%d %s: %v has records of unknown size", entry.index, entry.name, which) or_return
		end := place.start + place.count * size
		testing.expectf(t, end + (-end & 3) == next, "%d %s: %v does not end where the next table starts", entry.index, entry.name, which) or_return
	}
	bank_start := motbin.tables[.Embedded_Bank].start
	for bank in motbin.banks {
		testing.expectf(t, bank >= bank_start && bank <= data_size, "%d %s: bank at %x", entry.index, entry.name, bank) or_return
		bank_start = bank
	}
	return true
}

@(private = "file")
indices_hold :: proc(t: ^testing.T, entry: tk6.Roster_Entry, motbin: tk6.Motbin) -> bool {
	for move, number in motbin.moves {
		ok := index_in(move.cancels, motbin.cancels) && index_in(move.hit_conditions, motbin.hit_conditions) &&
			optional_in(move.voiceclips, motbin.voiceclips) && optional_in(move.extra_properties, motbin.extra_properties) &&
			optional_in(move.start_properties, motbin.start_properties) && optional_in(move.end_properties, motbin.end_properties) &&
			animation_valid(move.animation, motbin.embedded_animation_count)
		testing.expectf(t, ok, "%d %s: move %d = %v", entry.index, entry.name, number, move) or_return
	}
	cancel_tables := [2][]tk6.Cancel{motbin.cancels, motbin.group_cancels}
	for cancels in cancel_tables do for cancel, number in cancels {
		ok := index_in(cancel.requirements, motbin.requirements) && index_in(cancel.extra, motbin.cancel_extras) &&
			cancel_target_valid(motbin, cancel)
		testing.expectf(t, ok, "%d %s: cancel %d = %v", entry.index, entry.name, number, cancel) or_return
	}
	for condition, number in motbin.hit_conditions {
		ok := index_in(condition.requirements, motbin.requirements) && index_in(condition.reaction, motbin.reactions)
		testing.expectf(t, ok, "%d %s: hit condition %d = %v", entry.index, entry.name, number, condition) or_return
	}
	for reaction, number in motbin.reactions {
		for pushback in reaction.pushbacks do testing.expectf(t, index_in(pushback, motbin.pushbacks), "%d %s: reaction %d", entry.index, entry.name, number) or_return
		moves := [14]u16{
			reaction.move_standing, reaction.move_crouch, reaction.move_counter, reaction.move_crouch_counter,
			reaction.move_left, reaction.move_left_crouch, reaction.move_right, reaction.move_right_crouch,
			reaction.move_back, reaction.move_back_crouch, reaction.move_block, reaction.move_crouch_block,
			reaction.move_wall_slump, reaction.move_down,
		}
		for move in moves do testing.expectf(t, move_valid(motbin, move), "%d %s: reaction %d move %x", entry.index, entry.name, number, move) or_return
	}
	for alias, number in motbin.aliases {
		testing.expectf(t, int(alias) < len(motbin.moves), "%d %s: alias %d", entry.index, entry.name, number) or_return
	}
	for pushback, number in motbin.pushbacks {
		testing.expectf(t, index_in(pushback.extras, motbin.pushback_extras), "%d %s: pushback %d", entry.index, entry.name, number) or_return
	}
	property_tables := [2][]tk6.Property{motbin.start_properties, motbin.end_properties}
	for properties in property_tables do for property, number in properties {
		testing.expectf(t, index_in(property.requirements, motbin.requirements), "%d %s: property %d", entry.index, entry.name, number) or_return
	}
	for sequence, number in motbin.input_sequences {
		testing.expectf(t, index_in(sequence.inputs, motbin.input_extras), "%d %s: input sequence %d", entry.index, entry.name, number) or_return
	}
	for record, number in motbin.table_17 {
		testing.expectf(t, index_in(record.table_18, motbin.table_18), "%d %s: table 17 record %d", entry.index, entry.name, number) or_return
	}
	for record, number in motbin.table_24 {
		testing.expectf(t, index_in(record.table_23, motbin.table_23), "%d %s: table 24 record %d", entry.index, entry.name, number) or_return
	}
	return true
}

@(private = "file")
lists_end :: proc(t: ^testing.T, entry: tk6.Roster_Entry, motbin: tk6.Motbin) -> bool {
	for move, number in motbin.moves {
		ok := cancel_list_ends(motbin.cancels, move.cancels, tk6.CANCEL_LIST_END) &&
			list_ends(motbin.voiceclips, move.voiceclips, proc(clip: u32) -> bool {return clip == 0xffffffff}) &&
			list_ends(motbin.extra_properties, move.extra_properties, proc(property: tk6.Extra_Property) -> bool {return property == {}}) &&
			list_ends(motbin.start_properties, move.start_properties, property_list_end) &&
			list_ends(motbin.end_properties, move.end_properties, property_list_end)
		testing.expectf(t, ok, "%d %s: move %d has a list with no end", entry.index, entry.name, number) or_return
	}
	cancel_tables := [2][]tk6.Cancel{motbin.cancels, motbin.group_cancels}
	for cancels in cancel_tables do for cancel, number in cancels {
		testing.expectf(t, requirement_list_ends(motbin, cancel.requirements), "%d %s: cancel %d requirement list has no end", entry.index, entry.name, number) or_return
		if cancel.command >> 32 != tk6.GROUP_CANCEL_JUMP do continue
		ok := cancel_list_ends(motbin.group_cancels, u32(cancel.move), tk6.GROUP_CANCEL_RETURN)
		testing.expectf(t, ok, "%d %s: cancel %d group cancel list %d has no end", entry.index, entry.name, number, cancel.move) or_return
	}
	for condition, number in motbin.hit_conditions {
		testing.expectf(t, requirement_list_ends(motbin, condition.requirements), "%d %s: hit condition %d requirement list has no end", entry.index, entry.name, number) or_return
	}
	property_tables := [2][]tk6.Property{motbin.start_properties, motbin.end_properties}
	for properties in property_tables do for property, number in properties {
		testing.expectf(t, requirement_list_ends(motbin, property.requirements), "%d %s: property %d requirement list has no end", entry.index, entry.name, number) or_return
	}
	return true
}

@(private = "file")
index_in :: proc(index: u32, table: []$Record) -> bool {return int(index) < len(table)}

// -1: none.
@(private = "file")
optional_in :: proc(index: i32, table: []$Record) -> bool {return index == -1 || (index >= 0 && int(index) < len(table))}

// Exactly one bank: container, common, or the embedded one within its count.
@(private = "file")
animation_valid :: proc(animation: u32, embedded_count: int) -> bool {
	banks := animation & (tk6.CONTAINER_BANK | tk6.COMMON_BANK)
	if animation >> 16 != 0 || banks == tk6.CONTAINER_BANK | tk6.COMMON_BANK do return false
	return banks != 0 || int(animation & 0x3fff) < embedded_count
}

// A cancel goes to a move, a group cancel list, or reads an input sequence.
@(private = "file")
cancel_target_valid :: proc(motbin: tk6.Motbin, cancel: tk6.Cancel) -> bool {
	kind := cancel.command >> 32
	switch {
	case kind == tk6.CANCEL_LIST_END || kind == tk6.GROUP_CANCEL_RETURN: return true
	case kind == tk6.GROUP_CANCEL_JUMP: return index_in(u32(cancel.move), motbin.group_cancels)
	case kind >= tk6.INPUT_SEQUENCE_FIRST && !index_in(u32(kind - tk6.INPUT_SEQUENCE_FIRST), motbin.input_sequences): return false
	}
	return move_valid(motbin, cancel.move)
}

// A move index or an alias (0x8000 + n).
@(private = "file")
move_valid :: proc(motbin: tk6.Motbin, move: u16) -> bool {
	return int(move) < len(motbin.moves) || (move >= 0x8000 && move < 0x8000 + tk6.ALIAS_COUNT)
}

@(private = "file")
property_list_end :: proc(property: tk6.Property) -> bool {return property.id == tk6.REQUIREMENT_LIST_END}

// -1: no list.
@(private = "file")
list_ends :: proc(table: []$Record, start: i32, is_end: proc(record: Record) -> bool) -> bool {
	if start == -1 do return true
	if !optional_in(start, table) do return false
	for record in table[start:] do if is_end(record) do return true
	return false
}

@(private = "file")
requirement_list_ends :: proc(motbin: tk6.Motbin, start: u32) -> bool {
	if !index_in(start, motbin.requirements) do return false
	for requirement in motbin.requirements[start:] do if requirement.id == tk6.REQUIREMENT_LIST_END do return true
	return false
}

@(private = "file")
cancel_list_ends :: proc(cancels: []tk6.Cancel, start: u32, end_command: u64) -> bool {
	if !index_in(start, cancels) do return false
	for cancel in cancels[start:] do if cancel.command >> 32 == end_command do return true
	return false
}
