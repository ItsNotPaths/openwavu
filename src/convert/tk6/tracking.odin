// Tracking rows by TK6 facing mode and the TK6 motion codes that pick them (tk6decomp docs/sim_contract.md 6, data.md
// "Facing modes"; the motion code switch at 0x1af958 in FUN_001aee6c, the mode cases at 0x1bb118 in FUN_001ba9f4).
// The rows and the seed are the TK5 converter's (src/convert/tk5/tracking.odin) in TK6 numbers.
package tk6_convert

import tk5_convert "../tk5"

Track :: tk5_convert.Track
Tracking :: tk5_convert.Tracking
Facing_Row :: tk5_convert.Facing_Row
Seed_Cancel :: tk5_convert.Seed_Cancel
Seed_Source :: tk5_convert.Seed_Source

FACING_REAIM :: 10
FACING_FREE :: 16
FACING_STOCK :: 51  // modes 0..50; a mode past them acts as FACING_FREE

// TK5 mode -> TK6 mode, for the TK5 modes below 14 (14 and up are TK6 mode - 4).
@(private, rodata)
TK6_OF_TK5_MODE := [14]int{0, 1, 3, 5, 7, 8, 9, 10, 11, 12, 14, 15, 16, 17}

@(private)
tk6_mode :: proc(tk5_mode: int) -> int {return tk5_mode < len(TK6_OF_TK5_MODE) ? TK6_OF_TK5_MODE[tk5_mode] : tk5_mode + 4}

// The TK5 row of a mode TK6 kept, or the row of a new mode: 2 is mode 1 aimed at the opponent's live angle and keeping
// the move yaw (it goes on to mode 17); 4 and 6 are 3 and 5 that carry the move yaw along; 13 eases in on the opponent.
facing_row :: proc(mode: int) -> (row: Facing_Row) {
	switch mode {
	case 2:
		row = tk5_convert.stock_row(1)
		row.target = .Opponent
		row.end.yaw_when = .Never
		row.end.phase = .Scripted
	case 4, 6:
		row = tk5_convert.stock_row(mode == 4 ? 2 : 3)
		row.end.yaw_when = .Always
	case 13:
		row.law, row.target = .Ease_In, .Opponent
		row.rate.normal, row.rate.frames = 12, 16
	case 18 ..< FACING_STOCK: row = tk5_convert.stock_row(mode - 4)
	case 0 ..< 18:
		for tk6, tk5_mode in TK6_OF_TK5_MODE do if tk6 == mode do row = tk5_convert.stock_row(tk5_mode)
	case: row = tk5_convert.stock_row(tk5_convert.FREE_MODE)
	}
	row.stock_mode = u8(mode)
	return
}

// Row of a TK6 mode in the character's table, added on first use.
facing_row_index :: proc(tracking: ^Tracking, mode: int) -> u8 {
	row := facing_row(mode < FACING_STOCK ? mode : FACING_FREE)
	for existing, index in tracking.rows do if existing == row do return u8(index)
	append(&tracking.rows, row)
	return u8(len(tracking.rows) - 1)
}

// TK6 motion code -> (mode, far mode, far source); ok false for the codes without a mode. The new codes set a mode and
// nothing else; the others set the TK5 twin's mode.
@(private = "file")
code_modes :: proc(code: int) -> (mode, far_mode: int, source: tk5_convert.Far_Source, ok: bool) {
	switch code {
	case 4: return 6, FACING_REAIM, .Opp_Angle, true
	case 6: return 4, FACING_REAIM, .Opp_Angle, true
	case 12: return 6, 0, .Never, true
	case 14: return 4, 0, .Never, true
	case 16: return 2, 0, .Never, true
	case 21: return 13, 0, .Never, true
	}
	if code < 0 || code >= MOTION_TABLE_SIZE do return
	tk5_mode, tk5_far, far_source, has := tk5_code_modes(int(MOTION_CODES[code]))
	if !has do return
	return tk6_mode(tk5_mode), tk6_mode(tk5_far), far_source, true
}

// The TK5 converter's table (src/convert/tk5/tracking.odin code_modes), TK5 codes and modes.
@(private = "file")
tk5_code_modes :: proc(code: int) -> (mode, far_mode: int, source: tk5_convert.Far_Source, ok: bool) {
	FREE :: tk5_convert.FREE_MODE
	REAIM :: tk5_convert.REAIM_MODE
	switch code {
	case 1, 14, 19 ..= 23, 25 ..= 32: return FREE, 0, .Never, true
	case 2 ..= 4: return 6 - code, REAIM, .Opp_Angle, true
	case 5 ..= 7: return 9 - code, REAIM, .Angle_84, true
	case 8: return 4, 0, .Never, true
	case 9: return 3, 0, .Never, true
	case 10: return 2, 0, .Never, true
	case 11: return 1, 0, .Never, true
	case 12: return 6, 0, .Never, true
	case 13: return 5, 0, .Never, true
	case 15: return 9, 0, .Never, true
	case 16, 17: return tk5_convert.SWEEP_MODE, 0, .Never, true
	case 18: return 10, 0, .Never, true
	case 24: return 8, 0, .Never, true
	case 33 ..= 42: return code - 33 + 14, 0, .Never, true
	case 43: return 24, 0, .Never, true
	case 44: return 25, 0, .Never, true
	case 45: return 26, 0, .Never, true
	case 46 ..= 48: return code - 19, 26, .Opp_Angle, true
	case 49: return 30, 0, .Never, true
	case 50: return 31, 0, .Never, true
	case 51 ..= 53: return code - 19, 31, .Opp_Angle, true
	case 54: return 35, 0, .Never, true
	case 55: return 46, 0, .Never, true
	}
	return
}

// Codes that script a turn in the sim (turn frames, pushback, juggle): the sim forces the free phase for them.
@(private = "file")
is_scripted_code :: proc(code: int) -> bool {
	if code < 0 || code >= MOTION_TABLE_SIZE do return false
	tk5_code := MOTION_CODES[code]
	return tk5_code == 14 || (tk5_code >= 19 && tk5_code <= 23) || (tk5_code >= 25 && tk5_code <= 32)
}

MOTION_CARRY :: 3   // the carry rewrite of the transition filter (FUN_001ab9e8; TK5 2)
MOTION_GUARD :: 30  // the guard reaction (TK5 24)

@(private = "file")
code_tracking :: proc(tracking: ^Tracking, code: int) -> Track {
	mode, far_mode, source, ok := code_modes(code)
	if !ok do return {}
	row := facing_row_index(tracking, mode)
	if source == .Never do return {row = row}
	return {row, facing_row_index(tracking, far_mode), source, tk5_convert.BEHIND_ANGLE}
}

@(private = "file")
Entry_Key :: struct {
	group: bool,
	index: int,
}

@(private = "file")
Entry :: struct {
	key:     Entry_Key,
	dest:    int,   // move index, -1 none
	track:   Track,
	tracked: bool,  // false for a code without a mode, or a scripted one
	alias:   bool,  // the move is an alias: it resolves in the table of the fighter that runs it
}

@(private = "file")
Vote :: struct {
	track: Track,
	count: int,
}

// The default of a move is the tracking most source moves reach it with (a group entry counts once per move that scans it).
// Ties go to a row other than hold, then to the lower row, then to the first seen. An alias entry always carries its tracking.
seed_tracking_of :: proc(source: Seed_Source) -> (tracking: Tracking) {
	context.allocator = context.temp_allocator
	append(&tracking.rows, facing_row(0))
	entries := make([dynamic]Entry)
	for group in ([]bool{false, true}) {
		list := group ? source.group_cancels : source.cancels
		for cancel, index in list {
			if cancel.kind == .Group || cancel.kind == .Group_End do continue
			entry := Entry{key = {group, index}, dest = resolve_move(source, cancel.move), alias = cancel.move & 0x8000 != 0}
			if _, _, _, ok := code_modes(cancel.motion); ok && !is_scripted_code(cancel.motion) {
				entry.track, entry.tracked = code_tracking(&tracking, cancel.motion), true
			}
			append(&entries, entry)
		}
	}
	weight := make(map[Entry_Key]int)
	for first in source.move_cancels do for key in scanned_entries(source, int(first)) do weight[key] += 1
	votes := make(map[int][dynamic]Vote)
	for entry in entries {
		if entry.dest < 0 || !entry.tracked do continue
		if entry.dest not_in votes do votes[entry.dest] = make([dynamic]Vote)
		list := &votes[entry.dest]
		found := false
		for &vote in list^ do if vote.track == entry.track {
			vote.count += max(weight[entry.key], 1)
			found = true
		}
		if !found do append(list, Vote{entry.track, max(weight[entry.key], 1)})
	}
	tracking.default = make([]Track, len(source.move_cancels))
	for dest, list in votes {
		best := list[0]
		for vote in list[1:] do if better_vote(vote, best) do best = vote
		tracking.default[dest] = best.track
	}
	tracking.cancel_pick = make([]u16, len(source.cancels))
	tracking.group_pick = make([]u16, len(source.group_cancels))
	for entry in entries {
		if !entry.tracked || (!entry.alias && (entry.dest < 0 || entry.track == tracking.default[entry.dest])) do continue
		index := -1
		for override, at in tracking.overrides do if override == entry.track do index = at
		if index < 0 {
			append(&tracking.overrides, entry.track)
			index = len(tracking.overrides) - 1
		}
		picks := entry.key.group ? tracking.group_pick : tracking.cancel_pick
		picks[entry.key.index] = u16(index + 1)
	}
	tracking.fixed = {code_tracking(&tracking, MOTION_CARRY), code_tracking(&tracking, MOTION_GUARD)}
	return
}

@(private = "file")
better_vote :: proc(vote, best: Vote) -> bool {
	if vote.count != best.count do return vote.count > best.count
	vote_hold, best_hold := vote.track == {}, best.track == {}
	if vote_hold != best_hold do return !vote_hold
	return vote.track.row < best.track.row
}

// Move index of a move id (plain, or 0x8000 | alias); -1 if it names nothing.
@(private = "file")
resolve_move :: proc(source: Seed_Source, id: u16) -> int {
	index := int(id)
	if id & 0x8000 != 0 {
		alias := int(id & 0x7fff)
		if alias >= len(source.aliases) do return -1
		index = int(source.aliases[alias])
	}
	return index < len(source.move_cancels) ? index : -1
}

// The entries a move scans from cancel `first`, groups inlined; the end entry too (it names the move that follows).
@(private = "file")
scanned_entries :: proc(source: Seed_Source, first: int) -> []Entry_Key {
	out := make([dynamic]Entry_Key, context.temp_allocator)
	for index := first; index >= 0 && index < len(source.cancels); index += 1 {
		kind := source.cancels[index].kind
		if kind == .Group {
			for group := int(source.cancels[index].move); group < len(source.group_cancels) && source.group_cancels[group].kind != .Group_End; group += 1 {
				append(&out, Entry_Key{true, group})
			}
		} else {
			append(&out, Entry_Key{false, index})
		}
		if kind == .End do break
	}
	return out[:]
}
