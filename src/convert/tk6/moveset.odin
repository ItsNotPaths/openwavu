// Moveset rows for the TK6 sim (src/db/tk6/schema.sql): the TK6 motbin with its numbers rewritten into the sim's
// (ids.odin), in the TK6 records and at their full width, then written as rows (rows.odin).
package tk6_convert

import "core:slice"
import "../../db"
import formats "../../formats/tk6"
import tk5_convert "../tk5"

VOICECLIP_END :: 0xffffffff

// fallbacks: counts of what had no exact sim match, kept in the caller's allocator.
write_moveset_rows :: proc(w: ^db.Writer, character, animation_owner: string, motbin: formats.Motbin, fallbacks: ^Fallbacks) -> (error: string) {
	for &counts in fallbacks do if counts == nil do counts = make(map[u32]int)
	context.allocator = context.temp_allocator
	return write_rows(w, character, animation_owner, sim_motbin(motbin, fallbacks), fallbacks)
}

@(private = "file")
Converter :: struct {
	motbin:     formats.Motbin,
	fallbacks:  ^Fallbacks,
	never_used: bool,  // a cancel took the never list
}

// Kept rows of a table whose rows may drop: kept[old] is the new index of row old, or of the next kept row.
@(private = "file")
Kept :: []u32

// The motbin in sim numbers: the same tables and records; ids rewritten, rows with no sim meaning dropped.
// (hole tk6-heihachi-hellsweep-grounded :tags (tk6 importer fighter-detail) :sev gap) Heihachi's 1+2, then his hellsweep on the opponent lying after it: the sweep sometimes passes through the grounded opponent (no hit, no damage; inconsistent, any opponent, input as fast as allowed); the sweep, the victim's launched and lying chain and the down-hit reactions all match TK5's rows, and hit.c is the same, so check timing (the 56-frame launched move) and the hurtboxes.
sim_motbin :: proc(motbin: formats.Motbin, fallbacks: ^Fallbacks) -> (sim: formats.Motbin) {
	converter := Converter{motbin = motbin, fallbacks = fallbacks}
	sim = motbin
	requirements, requirement_kept := sim_requirements(&converter)
	extra_kept, start_kept, end_kept: Kept
	sim.extra_properties, extra_kept = sim_extra_properties(&converter)
	start_lists := make([]i32, len(motbin.moves))
	end_lists := make([]i32, len(motbin.moves))
	for move, index in motbin.moves do start_lists[index], end_lists[index] = move.start_properties, move.end_properties
	sim.start_properties, start_kept = sim_conditional_properties(&converter, motbin.start_properties, start_lists, requirement_kept)
	sim.end_properties, end_kept = sim_conditional_properties(&converter, motbin.end_properties, end_lists, requirement_kept)

	never_list := u32(len(requirements))
	sim.cancels = sim_cancels(&converter, motbin.cancels, requirement_kept, never_list)
	sim.group_cancels = sim_cancels(&converter, motbin.group_cancels, requirement_kept, never_list)
	if converter.never_used {
		append(&requirements, formats.Requirement{REQUIREMENT_NEVER, 0}, formats.Requirement{REQUIREMENT_LIST_END, 0})
	}
	sim.requirements = requirements[:]
	sim.cancel_extras = make([]u32, len(motbin.cancel_extras))
	for word, index in motbin.cancel_extras do sim.cancel_extras[index] = transition_of(word, fallbacks)

	sim.moves = make([]formats.Move, len(motbin.moves))
	for move, index in motbin.moves do sim.moves[index] = sim_move(&converter, move, {extra_kept, start_kept, end_kept})
	sim.hit_conditions = slice.clone(motbin.hit_conditions)
	for &condition in sim.hit_conditions do condition.requirements = requirement_kept[condition.requirements]
	return
}

// Requirement lists hold requirements and instant properties; dropped properties leave the list.
@(private = "file")
sim_requirements :: proc(converter: ^Converter) -> (rows: [dynamic]formats.Requirement, kept: Kept) {
	kept = make(Kept, len(converter.motbin.requirements) + 1)
	for requirement, index in converter.motbin.requirements {
		kept[index] = u32(len(rows))
		switch {
		case requirement.id == REQUIREMENT_LIST_END:
			append(&rows, requirement)
		case requirement.id < ALIAS_BASE:
			id, parameter := requirement_of(requirement.id, requirement.parameter, converter.fallbacks)
			append(&rows, formats.Requirement{id, parameter_of(converter, requirement.id, id, parameter)})
		case:
			id, ok := property_of(requirement.id, true, converter.fallbacks)
			if ok do append(&rows, formats.Requirement{id, parameter_of(converter, requirement.id, id, requirement.parameter)})
		}
	}
	kept[len(converter.motbin.requirements)] = u32(len(rows))
	return
}

// A zero row ends a list.
@(private = "file")
sim_extra_properties :: proc(converter: ^Converter) -> (rows: []formats.Extra_Property, kept: Kept) {
	properties := converter.motbin.extra_properties
	kept = make(Kept, len(properties) + 1)
	sim_rows := make([dynamic]formats.Extra_Property)
	for property, index in properties {
		kept[index] = u32(len(sim_rows))
		if property == {} {
			append(&sim_rows, property)
			continue
		}
		id := property_of(property.id, false, converter.fallbacks) or_continue
		fit(converter, property.frame, property.id)
		append(&sim_rows, formats.Extra_Property{property.frame, id, parameter_of(converter, property.id, id, property.value)})
	}
	kept[len(properties)] = u32(len(sim_rows))
	return sim_rows[:], kept
}

// A start or end property list ends at id REQUIREMENT_LIST_END. TK6 lists may share a tail (a move starts inside
// another's list); the rows hold whole lists, so each list a move starts is copied out on its own.
@(private = "file")
sim_conditional_properties :: proc(converter: ^Converter, properties: []formats.Property, starts: []i32, requirement_kept: Kept) -> (sim: []formats.Property, kept: Kept) {
	rows := make([dynamic]formats.Property)
	kept = make(Kept, len(properties) + 1)
	copied := make([]bool, len(properties))
	for start in starts {
		if start < 0 || copied[start] do continue
		copied[start] = true
		kept[start] = u32(len(rows))
		for property in properties[start:] {
			if property.id == REQUIREMENT_LIST_END {
				append(&rows, property)
				break
			}
			id := property_of(property.id, true, converter.fallbacks) or_continue
			value := parameter_of(converter, property.id, id, property.value)
			append(&rows, formats.Property{requirement_kept[property.requirements], id, value})
		}
	}
	return rows[:], kept
}

// A cancel the command text can not hold keeps its place and takes the never list (appended after the requirements).
@(private = "file")
sim_cancels :: proc(converter: ^Converter, cancels: []formats.Cancel, requirement_kept: Kept, never_list: u32) -> []formats.Cancel {
	rows := make([]formats.Cancel, len(cancels))
	for cancel, index in cancels {
		_, _, readable := cancel_input(converter.motbin, cancel)
		if !readable do count(converter.fallbacks, .Command_Never, u32(cancel.command >> 32))
		converter.never_used ||= !readable
		for frame in ([]u32{cancel.window_start, cancel.window_end, cancel.starting_frame}) do fit(converter, frame, 0)
		rows[index] = cancel
		rows[index].requirements = readable ? requirement_kept[cancel.requirements] : never_list
	}
	return rows
}

// Move frames the sim keeps in 16 bits: window start and landing frame +0x28, +0x30, active frames +0x4c, +0x50.
@(private = "file")
sim_move :: proc(converter: ^Converter, move: formats.Move, property_kept: [3]Kept) -> (sim: formats.Move) {
	sim = move
	sim.vulnerability = state_word_of(move.vulnerability, converter.fallbacks)
	sim.extra_properties = kept_index(property_kept[0], move.extra_properties)
	sim.start_properties = kept_index(property_kept[1], move.start_properties)
	sim.end_properties = kept_index(property_kept[2], move.end_properties)
	fit(converter, move.unknown_28[0], 0x28)
	fit(converter, move.unknown_28[2], 0x30)
	fit(converter, move.unknown_48[1], 0x4c)
	fit(converter, move.unknown_48[2], 0x50)
	return
}

// -1: none.
@(private = "file")
kept_index :: proc(kept: Kept, index: i32) -> i32 {return index < 0 ? -1 : i32(kept[index])}

// A requirement param or property value in sim terms: a facing mode, a state or a hit bone rewritten, the rest as stored.
@(private = "file")
parameter_of :: proc(converter: ^Converter, tk6_id, sim_id, value: u32) -> u32 {
	if tk5_convert.code_ref(u16(sim_id)) == "tracking_row" do return facing_mode_of(value, converter.fallbacks)
	if tk6_id == PROPERTY_STATE do return state_word_of(value, converter.fallbacks)
	if tk5_convert.is_category_requirement(u16(sim_id)) do return sim_bone_code(value)
	return value
}

// Counts a frame that is neither unsigned nor signed 16 bits: the sim holds it in 16.
@(private = "file")
fit :: proc(converter: ^Converter, frame: u32, number: u32) {
	if frame > 0xffff && frame < 0xffff8000 do count(converter.fallbacks, .Frame_Truncated, number)
}
