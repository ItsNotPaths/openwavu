// TK6 numbers in the sim's numbers (tk6decomp docs/sim_contract.md). The sim is the TK5 sim fork: it keeps TK5 ids,
// plus a few new ones after them, and TK6's alias slots.
package tk6_convert

import tk5_convert "../tk5"

// What a converter did with a TK6 number the sim has no exact match for. Counts are by the TK6 number.
Fallback :: enum {
	Requirement_Open,      // the state it reads has no sim field: never true
	Requirement_Unknown,   // in no table: never true
	Requirement_Campaign,  // a Scenario Campaign or object test: never true in versus
	Property_Dropped,      // no sim meaning (effects, model layers, HUD, guesses)
	Property_Dead,         // read by nothing in the game
	Facing_Property_Dropped, // a facing mode in a start, end or requirement list, or the opponent's mode
	Facing_Nearest,        // a facing mode new in TK6: the nearest TK5 mode
	Motion_Nearest,        // a motion code new in TK6: the nearest TK5 code
	Motion_None,           // a motion code past the game's table: none
	Transition_Class_Start,  // a transition class with no sim class: start
	State_Class_Nearest,   // a state class with no sim class: invulnerable
	Command_Never,         // an input the command syntax can not hold: the cancel never matches
	Hitbox_Keep,           // a hitbox point code that is not a bone: the point stays
	Flow_State_Guessed,    // a game flow state test (by state)
	Frame_Truncated,       // a frame number wider than the sim's 16 bits, cut (by move record offset, property id, or 0 for cancels)
}

Fallbacks :: [Fallback]map[u32]int

@(private)
count :: proc(fallbacks: ^Fallbacks, kind: Fallback, number: u32) {
	counts := &fallbacks[kind]
	counts[number] += 1
}

delete_fallbacks :: proc(fallbacks: Fallbacks) {
	for counts in fallbacks do delete(counts)
}

@(private)
Run :: struct {first, last, sim: u32}

@(private)
Pair :: struct {tk6, sim: u32}

// --- requirements (contract 1)

REQUIREMENT_LIST_END :: 0x18d
REQUIREMENT_NEVER :: 77   // a TK5 id that is never true
REQUIREMENT_ALWAYS :: 0
REQUIREMENT_LINK_TARGET :: 0x14c
REQUIREMENT_FLOW_STATE :: 0x10a  // and 0x10b: the game's flow state (TK5 0xf1, 0xf2)
REQUIREMENT_FLOW_NEXT :: 0x10b

@(private, rodata)
REQUIREMENT_RUNS := [?]Run{
	{0x0, 0x0, 0}, {0x2, 0x27, 1}, {0x29, 0x2e, 39}, {0x31, 0x64, 45}, {0x68, 0x77, 97}, {0x80, 0x8e, 113},
	{0x8f, 0x95, 135}, {0x98, 0xa4, 142}, {0xa9, 0xab, 155}, {0xac, 0xb3, 159}, {0xb8, 0xbb, 168}, {0xbf, 0xc6, 172},
	{0xca, 0xd1, 180}, {0xd5, 0x11e, 188}, {0x122, 0x139, 262}, {0x143, 0x143, 286}, {0x15d, 0x180, 291},
}

// The ids new in TK6 that the sim reads (sim ids from 327 up).
@(private, rodata)
REQUIREMENT_NEW := [?]Pair{
	{0x144, 327}, {0x78, 328}, {0x79, 329}, {0x7a, 330}, {0x7b, 331}, {0x7c, 332}, {0x7d, 333}, {0x7e, 334}, {0x7f, 335},
	{0xbc, 336}, {0xbd, 337}, {0xbe, 338}, {0xc7, 339}, {0xc8, 340}, {0xc9, 341}, {0xd2, 342}, {0xd3, 343}, {0xd4, 344},
	{0x13a, 345}, {0xa5, 346}, {0xa6, 347}, {0xa7, 348}, {0xa8, 349},
	// the third facing hit copy: its twins
	{0x181, 292}, {0x182, 293}, {0x183, 294}, {0x184, 295}, {0x185, 298}, {0x186, 299}, {0x187, 300}, {0x188, 301},
	{0x189, 304}, {0x18a, 305}, {0x18b, 306}, {0x18c, 307},
	{0x1, REQUIREMENT_NEVER}, {0x28, REQUIREMENT_NEVER}, {0x11f, REQUIREMENT_NEVER}, {0x145, REQUIREMENT_ALWAYS},
}

// Own or opponent costume one of a pair: sim id, and the first costume of the pair as its param.
@(private, rodata)
REQUIREMENT_COSTUME_PAIRS := [?]struct {tk6, sim, costume: u32}{
	{0xb4, 350, 16}, {0xb5, 350, 18}, {0xb6, 351, 16}, {0xb7, 351, 18},
}

@(private, rodata)
REQUIREMENT_CAMPAIGN := [?]u32{0x146, 0x147, 0x148, 0x149, 0x14a, 0x14b, 0x157, 0x158, 0x15b, 0x15c}

// The state they read has no sim field.
@(private, rodata)
REQUIREMENT_OPEN := [?]Run{
	{0x2f, 0x30, 0}, {0x65, 0x67, 0}, {0x96, 0x97, 0}, {0x120, 0x121, 0}, {0x13b, 0x142, 0}, {0x14d, 0x156, 0},
	{0x159, 0x15a, 0},
}

// Flow states: TK6 state -> the TK5 state requirement_param reads [guess: by use counts]; others hold in no phase.
@(private, rodata)
FLOW_STATES := [?]Pair{{7, 9}, {10, 10}}

// The sim requirement id and param. Ids from 0x8000 on are properties (instant properties of a list).
@(private)
requirement_of :: proc(id, parameter: u32, fallbacks: ^Fallbacks) -> (sim_id, sim_parameter: u32) {
	if run_holds(REQUIREMENT_RUNS[:], id) {
		sim_id = run_value(REQUIREMENT_RUNS[:], id)
		if id == REQUIREMENT_FLOW_STATE || id == REQUIREMENT_FLOW_NEXT do return sim_id, flow_state(parameter, fallbacks)
		return sim_id, parameter
	}
	for pair in REQUIREMENT_NEW do if pair.tk6 == id do return pair.sim, parameter
	for pair in REQUIREMENT_COSTUME_PAIRS do if pair.tk6 == id do return pair.sim, pair.costume
	if id == REQUIREMENT_LINK_TARGET do return parameter == 0 ? REQUIREMENT_ALWAYS : REQUIREMENT_NEVER, parameter
	kind := Fallback.Requirement_Unknown
	for campaign in REQUIREMENT_CAMPAIGN do if campaign == id do kind = .Requirement_Campaign
	if run_holds(REQUIREMENT_OPEN[:], id) do kind = .Requirement_Open
	count(fallbacks, kind, id)
	return REQUIREMENT_NEVER, parameter
}

@(private)
flow_state :: proc(state: u32, fallbacks: ^Fallbacks) -> u32 {
	count(fallbacks, .Flow_State_Guessed, state)
	for pair in FLOW_STATES do if pair.tk6 == state do return pair.sim
	return 0
}

// --- properties (contract 2)

PROPERTY_FACING_MODE :: 0x808f           // sim 0x8071
PROPERTY_FACING_MODE_OPPONENT :: 0x8090  // sim 0x8072, no row translation
PROPERTY_STATE :: 0x8091                 // sim 0x8073: a vuln word, the state class in bits 11..15
PROPERTY_TRACK :: 0x81ea                 // in a cancel's requirement list: the sim's track marker
SIM_PROPERTY_TRACK :: 0x8162

@(private, rodata)
PROPERTY_RUNS := [?]Run{
	{0x8001, 0x8003, 0x8001}, {0x8005, 0x8008, 0x8004}, {0x800a, 0x800f, 0x8008}, {0x8011, 0x8012, 0x8014},
	{0x8013, 0x8014, 0x8011}, {0x8015, 0x8017, 0x8016}, {0x8018, 0x8018, 0x8013}, {0x801e, 0x801e, 0x8019},
	{0x801f, 0x8020, 0x801c}, {0x8021, 0x8022, 0x801a}, {0x8023, 0x8025, 0x801e}, {0x8028, 0x8028, 0x8021},
	{0x802a, 0x802a, 0x802c}, {0x802b, 0x802b, 0x802b}, {0x802d, 0x802d, 0x803a}, {0x8030, 0x8030, 0x8030},
	{0x8037, 0x8039, 0x802d}, {0x803a, 0x8040, 0x8031}, {0x8048, 0x8049, 0x8038}, {0x804f, 0x805e, 0x803b},
	{0x8068, 0x808d, 0x804b}, {0x808f, 0x8095, 0x8071}, {0x8097, 0x80a3, 0x8078}, {0x80a7, 0x80a9, 0x8085},
	{0x80ab, 0x80b8, 0x8088}, {0x80ba, 0x80c6, 0x8096}, {0x80cb, 0x80d4, 0x80a3}, {0x80d5, 0x80d5, 0x80b0},
	{0x80d6, 0x80d7, 0x80ad}, {0x80d8, 0x80e4, 0x80b2}, {0x80e5, 0x80e7, 0x80c0}, {0x80e8, 0x80e8, 0x80c6},
	{0x80e9, 0x80ea, 0x80c3}, {0x80ec, 0x80ef, 0x80c8}, {0x80f1, 0x80f3, 0x80cc}, {0x80fb, 0x80fe, 0x80f9},
	{0x80ff, 0x80ff, 0x80ff}, {0x8100, 0x8100, 0x80f5}, {0x8101, 0x8102, 0x80f3}, {0x8103, 0x8104, 0x80f6},
	{0x8107, 0x8108, 0x80e2}, {0x810d, 0x810e, 0x80e8}, {0x810f, 0x8116, 0x80eb},
	{0x8174, 0x81b5, 0x8107},  // set alias k (0x8174 + k, k < 33), restore alias k: the sim's slots are TK6's
	{0x81c1, 0x81ce, 0x8149},
	{0x81df, 0x81e0, 0x8157}, {0x81e3, 0x81e6, 0x8159}, {0x81e7, 0x81e8, 0x815e},
	// new sim ids: bound counter, juggle count clear, move variables H, I, J. Force rage (0x814e) drops: rage is health only.
	{0x8120, 0x8120, 0x8163}, {0x8121, 0x8121, 0x8164}, {0x805f, 0x8067, 0x8165},
	{PROPERTY_TRACK, PROPERTY_TRACK, SIM_PROPERTY_TRACK},
}

@(private, rodata)
PROPERTY_DEAD := [?]u32{0x8202, 0x8216}

// The sim property id; ok false: drop the row. `conditional`: in a start, end or requirement list.
@(private)
property_of :: proc(id: u32, conditional: bool, fallbacks: ^Fallbacks) -> (sim_id: u32, ok: bool) {
	switch {
	case id == PROPERTY_FACING_MODE_OPPONENT, id == PROPERTY_FACING_MODE && conditional:
		count(fallbacks, .Facing_Property_Dropped, id)
		return 0, false
	case run_holds(PROPERTY_RUNS[:], id):
		return run_value(PROPERTY_RUNS[:], id), true
	}
	dead := false
	for number in PROPERTY_DEAD do dead ||= number == id
	count(fallbacks, dead ? .Property_Dead : .Property_Dropped, id)
	return 0, false
}

// --- move aliases (contract 3): the sim has TK6's 69 slots, so a move id 0x8000 + n stays as it is.

ALIAS_BASE :: 0x8000

// --- transition words (contract 4): motion code bits 0..5, start alignment 6..9, class 10..13

MOTION_TABLE_SIZE :: 58  // codes past it are no motion (TK5 56)
MOTION_NO_MOVE :: 63

// TK6 motion code -> TK5 code, read from the motion code switch of both games (the facing mode each code sets).
// The six new codes (4, 6, 12, 14, 16, 21) take the TK5 code of the nearest mode; TK5 codes 39..42 have no TK6 code.
@(private, rodata)
MOTION_CODES := [MOTION_TABLE_SIZE]u8{
	0, 1, 2, 3, 3, 4, 4, 5, 6, 7, 8, 9, 9, 10, 10, 11, 11, 12, 13, 14, 15, 15,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
	43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55,
}

@(private, rodata)
MOTION_NEW := [?]u32{4, 6, 12, 14, 16, 21}

TRANSITION_CLASS_PASS :: 10  // TK6 "does not stop the scan", sim class 9
SIM_TRANSITION_CLASS_PASS :: 9
TRANSITION_CLASS_NO_MOVE :: 15

@(private)
transition_of :: proc(word: u32, fallbacks: ^Fallbacks) -> u32 {
	motion, align, class := word & 63, word >> 6 & 15, word >> 10 & 15
	sim_motion: u32
	switch {
	case motion == MOTION_NO_MOVE: sim_motion = MOTION_NO_MOVE
	case motion >= MOTION_TABLE_SIZE:
		count(fallbacks, .Motion_None, motion)
	case:
		sim_motion = u32(MOTION_CODES[motion])
		for new_code in MOTION_NEW do if new_code == motion do count(fallbacks, .Motion_Nearest, motion)
	}
	sim_class := class
	switch class {
	case TRANSITION_CLASS_PASS: sim_class = SIM_TRANSITION_CLASS_PASS
	case 0 ..= 8, TRANSITION_CLASS_NO_MOVE:
	case:
		count(fallbacks, .Transition_Class_Start, class)
		sim_class = 0
	}
	return word &~ 0x3fff | sim_class << 10 | align << 6 | sim_motion
}

// --- state classes (contract 5)

STATE_CLASS_SHIFT :: 11
STATE_CLASS_INVULNERABLE :: 20
STATE_CLASS_LAST :: 25  // the sim's last class

@(private)
state_word_of :: proc(word: u32, fallbacks: ^Fallbacks) -> u32 {
	class := word >> STATE_CLASS_SHIFT & 31
	sim_class := class
	switch class {
	case 0 ..= 0x14:
	case 0x17 ..= STATE_CLASS_LAST + 2: sim_class = class - 2
	case:
		count(fallbacks, .State_Class_Nearest, class)
		sim_class = STATE_CLASS_INVULNERABLE
	}
	return word &~ (31 << STATE_CLASS_SHIFT) | sim_class << STATE_CLASS_SHIFT
}

// --- facing modes (contract 6): TK6 mode -> the TK5 mode the TK5 rows take

FACING_FREE :: 12

// From the motion code switch: TK6 3 and 5 are TK5 2 and 3; 2, 4, 6, 13 are new (nearest TK5 mode).
@(private, rodata)
FACING_MODES := [18]u8{0, 1, 1, 2, 2, 3, 3, 4, 5, 6, 7, 8, 9, 9, 10, 11, 12, 13}

@(private, rodata)
FACING_NEW := [?]u32{2, 4, 6, 13}

FACING_SHIFTED_LAST :: 50  // 18..50 are TK5 14..46

@(private)
facing_mode_of :: proc(mode: u32, fallbacks: ^Fallbacks) -> u32 {
	for new_mode in FACING_NEW do if new_mode == mode do count(fallbacks, .Facing_Nearest, mode)
	switch {
	case mode < len(FACING_MODES): return u32(FACING_MODES[mode])
	case mode <= FACING_SHIFTED_LAST: return mode - 4
	}
	return FACING_FREE
}

// --- cancel commands (contract 7): the high u32 is the code, the low u32 the buttons, TK5's layout widened

COMMAND_END :: 0x8000
COMMAND_SPECIAL_LAST :: 0x8004   // dash forward, dash back, tap up, tap down: as TK5
COMMAND_STICK_FIRST :: 0x8005    // 0x8005..0x800a: a stick test (schema stick_test)
COMMAND_STICK_LAST :: 0x800a
COMMAND_GROUP :: 0x800b
COMMAND_GROUP_END :: 0x800c
COMMAND_SEQUENCE :: 0x800d       // and up: input sequence code - this

// --- move record fields (data "Move record", update "Move fields")

BONE_CODE_LAST :: 0x15     // hitbox point codes 0..0x15: bones, by TK6 bone record (skeleton.odin)
EFFECT_CODE :: 0x32        // '2': the effect hitbox
SIM_EFFECT_CODE :: tk5_convert.EFFECT_FIRST
SIM_KEEP_CODE :: 0xff      // any code the TK5 sim reads as "the point stays"

// A bone code as the sim's body slot; other codes stay. Kazuya's punches hit with codes 9 and 13 and his kicks with 16
// and 19: his hands and feet in TK6 record order, TK5's 8, 12, 16 and 20.
sim_bone_code :: proc(code: u32) -> u32 {return code <= BONE_CODE_LAST ? u32(BODY_SLOT[code]) : code}

// The four point codes of a move, bones as body slots.
@(private)
hitbox_bones :: proc(codes: u32) -> (sim_codes: u32) {
	for shift := u32(0); shift < 32; shift += 8 do sim_codes |= sim_bone_code(codes >> shift & 0xff) << shift
	return
}

// Four point codes in file order, as the TK5 codes that tk5_convert.hitbox_hits reads.
@(private)
hitbox_of :: proc(codes: u32, fallbacks: ^Fallbacks) -> (sim_codes: u32) {
	for shift := u32(24);; shift -= 8 {
		code := codes >> shift & 0xff
		sim_code := sim_bone_code(code)
		if code == EFFECT_CODE {
			sim_code = SIM_EFFECT_CODE
		} else if code > BONE_CODE_LAST {
			count(fallbacks, .Hitbox_Keep, code)
			sim_code = SIM_KEEP_CODE
		}
		sim_codes |= sim_code << shift
		if shift == 0 do return
	}
}

@(private)
run_holds :: proc(runs: []Run, number: u32) -> bool {
	for run in runs do if number >= run.first && number <= run.last do return true
	return false
}

@(private)
run_value :: proc(runs: []Run, number: u32) -> u32 {
	for run in runs do if number >= run.first && number <= run.last do return run.sim + number - run.first
	return 0
}
