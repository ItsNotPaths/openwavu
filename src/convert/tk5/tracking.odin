// Tracking (facing) rows of the stock game and the translation of its mode numbers (tk5decomp tools/tracking.py;
// docs/rewrite.md Db edits). The game picks a mode byte by the motion code (transition & 63) of the cancel or reaction
// that starts a move, or by property 0x8071. The db holds a table of rows per character, a default tracking per move,
// and an override per cancel entry where its stock tracking differs from the move's default. Units: degrees, frames.
package tk5_convert

import formats "../../formats/tk5"

Facing_Phase :: enum u8 {Running, Free, Reaim, Scripted}
Facing_Law :: enum u8 {Hold, Home, Settle, Sweep, Ease_Out, Ease_In, Leave}
Facing_Target :: enum u8 {None, Opponent, Behind, Reference, Side, Stage_Centre, Start_Spot}
Facing_When :: enum u8 {Never, Always, Unless_Anim_Changed}
Gate_Kind :: enum u8 {None, Skip, Spread, Spread_Early}
Halving :: enum u8 {None, All, Late}
Far_Source :: enum u8 {Never, Opp_Angle, Angle_84}

Facing_Row :: struct {
	law:        Facing_Law,
	start:      Facing_Phase,
	target:     Facing_Target,
	stock_mode: u8,
	gate:       struct {kind: Gate_Kind, until, min_distance: i32},
	rate:       struct {normal, late, air, late_from, frames: i32, halving: Halving, by_distance: bool},
	limit:      struct {total: i32, sweep: [4]i32},  // sweep by sector: front, left, back, right
	end:        struct {yaw_when, pivot_when: Facing_When, grace: i32, phase: Facing_Phase},
}

// The tracking a move starts: a row, and the row used instead when the angle named by far_source is above far_angle.
Track :: struct {
	row, far_row: u8,
	far_source:   Far_Source,
	far_angle:    u16,
}

Tracking :: struct {
	rows:        [dynamic]Facing_Row,  // row 0 is hold
	default:     []Track,              // per move
	cancel_pick: []u16,                // per cancel: 1 + override index, 0 none
	group_pick:  []u16,
	overrides:   [dynamic]Track,
	fixed:       [2]Track,             // a carried cancel the sim rewrites to code 2; a guarding reaction (code 24)
}

BEHIND_ANGLE :: 20387  // 0x4fa3: "opponent behind" for the codes that pick by angle at move start
STOCK_MODES :: 47      // 0..46; the game acts on a mode above 46 like on 12
FREE_MODE :: 12
REAIM_MODE :: 7
SWEEP_MODE :: 11
MOTION_CODE_MASK :: 0x3f
PROP_FACING_MODE :: 0x8071
PROP_FACING_MODE_OTHER :: 0x8072
CMD_GROUP_END :: 0x8006
CMD_END :: 0x8000

stock_row :: proc(mode: int) -> (r: Facing_Row) {
	r.stock_mode = u8(mode)
	ground :: proc(r: ^Facing_Row, target: Facing_Target, halving: Halving) {
		r.law, r.target = .Home, target
		r.gate = {.Spread_Early, 8, 0}
		r.rate = {3, 14, 1, 8, 0, halving, false}
		r.limit.total = 120
		r.end.phase = .Reaim
	}
	switch mode {
	case 1:
		r.law, r.target = .Home, .Reference
		r.rate = {30, 30, 30, 0, 0, .None, false}
		r.limit.total = 180
		r.end = {.Always, .Never, 0, .Reaim}
	case 2: ground(&r, .Opponent, .None)
	case 3: ground(&r, .Opponent, .All)
	case 4:
		r.law, r.target = .Home, .Opponent
		r.gate.kind = .Skip
		r.rate = {2, 3, 1, 8, 0, .None, false}
		r.limit.total = 20
		r.end.phase = .Reaim
	case 5: ground(&r, .Behind, .None)
	case 6: ground(&r, .Behind, .All)
	case REAIM_MODE: r.start = .Reaim
	case 8:
		r.law, r.target = .Ease_Out, .Reference
		r.rate.normal = 5
	case 9:
		r.law, r.target = .Ease_In, .Reference
		r.rate.normal, r.rate.frames = 10, 8
	case 10:
		r.law, r.target = .Leave, .Start_Spot
		r.gate.min_distance = 1200
		r.rate.normal = 8
		r.end.pivot_when = .Always
	case SWEEP_MODE: r = sweep_row(25)
	case FREE_MODE: r.start = .Free
	case 13: r.start = .Scripted
	case 14 ..= 25:  // settle in 40, 30, 20, 10, 5 frames, or by the distance of the fighters
		closes := [6]i32{40, 30, 20, 10, 5, 0}
		r.law, r.target = .Settle, mode < 20 ? .Opponent : .Side
		r.rate.frames = closes[(mode - 14) % 6]
		r.rate.by_distance = r.rate.frames == 0
		r.end.pivot_when = .Unless_Anim_Changed
	case 26 ..= 45:
		rates := [5]i32{3, 4, 7, 14, 23}
		block, kind := (mode - 26) / 5, (mode - 26) % 5
		r.law, r.target = .Home, .Opponent
		r.gate.kind = block % 2 == 0 ? .Spread : .None
		r.rate = {rates[kind], 0, 1, 9, 0, .Late, false}
		r.limit.total = rates[kind] == 23 ? 180 : 120
		end_when := block < 2 ? Facing_When.Never : .Unless_Anim_Changed
		r.end = {end_when, end_when, 3, .Scripted}
	case 46:
		r.law, r.target = .Settle, .Stage_Centre
		r.rate.frames = 5
	}
	return
}

sweep_row :: proc(back: i32) -> (r: Facing_Row) {
	r.law, r.target, r.stock_mode = .Sweep, .Reference, SWEEP_MODE
	r.rate.frames = 5
	r.limit.sweep = {25, 25, back, 25}
	r.end.pivot_when = .Always
	return
}

// Row of a stock mode in the character's table, added on first use. Xiaoyu's sweep swings -10 degrees in the back sector.
row_index :: proc(t: ^Tracking, mode: int, xiaoyu_sweep := false) -> u8 {
	mode := mode < STOCK_MODES ? mode : FREE_MODE
	r := xiaoyu_sweep ? sweep_row(-10) : stock_row(mode)
	for existing, i in t.rows do if existing == r do return u8(i)
	append(&t.rows, r)
	return u8(len(t.rows) - 1)
}

// Motion code -> (mode, far mode, far source); ok false for the codes without a mode (0, 56..63).
@(private = "file")
code_modes :: proc(code: int) -> (mode, far_mode: int, source: Far_Source, ok: bool) {
	switch code {
	case 1, 14, 19 ..= 23, 25 ..= 32: return FREE_MODE, 0, .Never, true
	case 2 ..= 4: return 6 - code, REAIM_MODE, .Opp_Angle, true
	case 5 ..= 7: return 9 - code, REAIM_MODE, .Angle_84, true
	case 8: return 4, 0, .Never, true
	case 9: return 3, 0, .Never, true
	case 10: return 2, 0, .Never, true
	case 11: return 1, 0, .Never, true
	case 12: return 6, 0, .Never, true
	case 13: return 5, 0, .Never, true
	case 15: return 9, 0, .Never, true
	case 16, 17: return SWEEP_MODE, 0, .Never, true
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
is_scripted_code :: proc(code: int) -> bool {return code == 14 || (code >= 19 && code <= 23) || (code >= 25 && code <= 32)}

@(private = "file")
is_sweep_code :: proc(code: int) -> bool {return code == 16 || code == 17}

code_tracking :: proc(t: ^Tracking, code: int, xiaoyu := false) -> Track {
	mode, far_mode, source, ok := code_modes(code)
	if !ok do return {}
	row := row_index(t, mode, xiaoyu && is_sweep_code(code))
	if source == .Never do return {row = row}
	return {row, row_index(t, far_mode), source, BEHIND_ANGLE}
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
seed_tracking :: proc(m: formats.Motbin, xiaoyu: bool) -> (t: Tracking) {
	context.allocator = context.temp_allocator
	append(&t.rows, stock_row(0))
	entries := make([dynamic]Entry)
	for group in ([]bool{false, true}) {
		list := group ? m.group_cancels : m.cancels
		for c, i in list {
			if hi := c.command >> 16; hi == CMD_GROUP || hi == CMD_GROUP_END do continue
			code := int(m.cancel_extras[c.extra] & MOTION_CODE_MASK)
			e := Entry{key = {group, i}, dest = resolve_move(m, c.move), alias = c.move & 0x8000 != 0}
			if _, _, _, ok := code_modes(code); ok && !is_scripted_code(code) {
				e.track, e.tracked = code_tracking(&t, code, xiaoyu), true
			}
			append(&entries, e)
		}
	}
	weight := make(map[Entry_Key]int)
	for mv in m.moves do for key in scanned_entries(m, int(mv.cancels)) do weight[key] += 1
	votes := make(map[int][dynamic]Vote)
	for e in entries {
		if e.dest < 0 || !e.tracked do continue
		if e.dest not_in votes do votes[e.dest] = make([dynamic]Vote)
		list := &votes[e.dest]
		found := false
		for &v in list^ do if v.track == e.track {
			v.count += max(weight[e.key], 1)
			found = true
		}
		if !found do append(list, Vote{e.track, max(weight[e.key], 1)})
	}
	t.default = make([]Track, len(m.moves))
	for dest, list in votes {
		best := list[0]
		for v in list[1:] do if better_vote(v, best) do best = v
		t.default[dest] = best.track
	}
	t.cancel_pick = make([]u16, len(m.cancels))
	t.group_pick = make([]u16, len(m.group_cancels))
	for e in entries {
		if !e.tracked || (!e.alias && (e.dest < 0 || e.track == t.default[e.dest])) do continue
		index := -1
		for o, i in t.overrides do if o == e.track do index = i
		if index < 0 {
			append(&t.overrides, e.track)
			index = len(t.overrides) - 1
		}
		picks := e.key.group ? t.group_pick : t.cancel_pick
		picks[e.key.index] = u16(index + 1)
	}
	t.fixed = {code_tracking(&t, 2), code_tracking(&t, 24)}
	return
}

@(private = "file")
better_vote :: proc(v, best: Vote) -> bool {
	if v.count != best.count do return v.count > best.count
	v_hold, best_hold := v.track == {}, best.track == {}
	if v_hold != best_hold do return !v_hold
	return v.track.row < best.track.row
}

// Move index of a move id (plain, or 0x8000 | alias); -1 if it names nothing.
@(private = "file")
resolve_move :: proc(m: formats.Motbin, id: u16) -> int {
	index := int(id)
	if id & 0x8000 != 0 {
		alias := int(id & 0x7fff)
		if alias >= len(m.aliases) do return -1
		index = int(m.aliases[alias])
	}
	return index < len(m.moves) ? index : -1
}

// The entries a move scans from cancel `first`, groups inlined; the end entry too (it names the move that follows).
@(private = "file")
scanned_entries :: proc(m: formats.Motbin, first: int) -> []Entry_Key {
	out := make([dynamic]Entry_Key, context.temp_allocator)
	for i := first; i >= 0 && i < len(m.cancels); i += 1 {
		hi := m.cancels[i].command >> 16
		if hi == CMD_GROUP {
			for g := int(m.cancels[i].move); g < len(m.group_cancels) && m.group_cancels[g].command >> 16 != CMD_GROUP_END; g += 1 {
				append(&out, Entry_Key{true, g})
			}
		} else {
			append(&out, Entry_Key{false, i})
		}
		if hi == CMD_END do break
	}
	return out[:]
}

// Property 0x8072 (sets the target's mode) has no row translation; 0x8071 is rewritten in the extra properties only.
check_facing_props :: proc(m: formats.Motbin) -> (ok: bool) {
	for p in m.start_props do if p.unk_04 >> 16 == PROP_FACING_MODE || p.unk_04 >> 16 == PROP_FACING_MODE_OTHER do return false
	for r in m.requirements do if r.id == PROP_FACING_MODE || r.id == PROP_FACING_MODE_OTHER do return false
	for x in m.extra_props do if x.unk_02 == PROP_FACING_MODE_OTHER do return false
	return true
}

// Extra property value, the high half the sim reads: 0x8071 holds the game's mode number, the db holds a row of the character table.
prop_value :: proc(t: ^Tracking, x: formats.Extra_Prop) -> u16 {
	value := u16(x.unk_04 >> 16)
	return x.unk_02 == PROP_FACING_MODE ? u16(row_index(t, int(value))) : value
}
