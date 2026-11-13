// TK6 numbers in the sim's numbers (tk6decomp docs/sim_contract.md). The sim is the TK5 sim fork: it keeps TK5 ids,
// plus a few new ones after them, and TK6's alias slots.
package tk6_convert

import tk5_convert "../tk5"

// What a converter did with a TK6 number the sim has no exact match for. Counts are by the TK6 number.
Fallback :: enum {
	// (hole tk6-open-requirements :tags (tk6 sim) :sev gap) never true still: 0x13b..0x13d, 0x142 (218 versus uses: worn customize item kinds, the item moves; the sim has only default costumes and no item kinds), 0x97 (42: a wall break fired, needs breaks); the rest sit behind scenario tests or only in campaign sets (tk6decomp requirements.md "Open ids in versus").
	Requirement_Open,      // the state it reads has no sim field: never true
	Requirement_Unknown,   // in no table: never true
	Requirement_Campaign,  // a Scenario Campaign or object test: never true in versus
	// (hole tk6-dropped-properties :tags (tk6 sim) :sev gap) dropped but read by sim code: 0x8096 (9 uses: P+0x210 picks how 8 body points of FUN_001d62fc are built; their readers are not found), 0x808e (27: P+0x250 bit 49, readers not found), Raven's 0x81ba..0x81c0 (his clone, an extra object the sim does not have); 0x80c8/0x80c9 only reach the floor break fall (FUN_001ac074); the rest are effects, model layers, camera, HUD or stats (tk6decomp properties.md "Dropped ids by use").
	Property_Dropped,      // no sim meaning (effects, model layers, HUD, guesses)
	Property_Dead,         // read by nothing in the game
	Facing_Property_Dropped, // a facing mode in a start, end or requirement list, or the opponent's mode
	Motion_None,           // a motion code past the game's table: none
	Transition_Class_Start,  // a transition class with no sim class: start
	Command_Never,         // an input the command syntax can not hold: the cancel never matches
	// (hole tk6-special-hit-points :tags (tk6 sim) :sev gap) codes 0x16..0x1a (100 versus uses) are model locators the sim has no model for, 0x1b/0x1c skeleton bones 0x4a/0x49 (Alisa), 0x31 (101: the shot point, block +0xc8, built by the shot mode +0xc4 like TK5's hitscan and projectile; the importer writes no shot rows), and the per-character blocks 0x2c..0x2e (Yoshimitsu's sword nodes), 0x2f, 0x30, 0x33, 0x36..0x3c (Kuma, Roger, NANCY, Azazel, Alisa) are not built: the point stays (tk6decomp sim_contract.md 9.7).
	Hitbox_Keep,           // a hitbox point code that is not a bone: the point stays
	// (hole tk6-flow-states :tags (tk6 sim) :sev polish) game modes 9, 13, 14, 16, 17 hold in no phase; 14 and 16 send the round-start stand into a move that holds itself, when is open.
	Flow_State_Guessed,    // a game flow state test (by state)
	Frame_Truncated,       // a frame number wider than the sim's 16 bits, cut (by move record offset, property id, or 0 for cancels)
	// (hole tk6-throw-clip-shots :tags (tk6 importer look) :sev polish) 12 roster throw picks play a clip of the thrower's camera bank (Steve, Roger, Zafina, Azazel, Alisa) and 8 use shot ids 7..10 (yaw from the thrower's facing); both keep the fight camera.
	Throw_Shot_Unbuilt,    // a throw camera pick the presenter has no code for, by kind << 16 | shot id: the fight camera stays
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
REQUIREMENT_PARAM_ZERO :: 0x109  // TK5 0xf0 battle state test; TK6 tests only param == 0 (every start and win pose cancel)
REQUIREMENT_FLOW_STATE :: 0x10a  // the game mode (TK5 0xf1, the flow state)

// Round flow tests TK6 dropped (never true), and 0x111, a question to a game object: false in versus, or every intro
// would be the game over kneel [guess]. tk6decomp docs/requirements.md.
@(private, rodata)
REQUIREMENT_DROPPED := [?]u32{0x108, 0x10b, 0x10e, 0x111, 0x112, 0x116, 0x117, 0x118, 0x119, 0x11a}

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
	{0x2f, 352},  // hit since the move started
	{0x13e, 353}, {0x13f, 354}, {0x140, 355}, {0x141, 356},  // Yoshimitsu's two part swaps (properties 0x8144, 0x8145)
	// the third facing hit copy: as its twin, but an attack the opponent hides counts unless its hit is harmless
	{0x181, 357}, {0x182, 358}, {0x183, 359}, {0x184, 360}, {0x185, 361}, {0x186, 362}, {0x187, 363}, {0x188, 364},
	{0x189, 365}, {0x18a, 366}, {0x18b, 367}, {0x18c, 368},
	{0x1, REQUIREMENT_NEVER}, {0x28, REQUIREMENT_NEVER}, {0x11f, REQUIREMENT_NEVER}, {0x145, REQUIREMENT_ALWAYS},
}

// Own or opponent costume one of a pair: sim id, and the first costume of the pair as its param.
@(private, rodata)
REQUIREMENT_COSTUME_PAIRS := [?]struct {tk6, sim, costume: u32}{
	{0xb4, 350, 16}, {0xb5, 350, 18}, {0xb6, 351, 16}, {0xb7, 351, 18},
}

@(private, rodata)
REQUIREMENT_CAMPAIGN := [?]u32{0x146, 0x147, 0x148, 0x149, 0x14a, 0x14b, 0x157, 0x158, 0x15b, 0x15c}

// The state they read has no sim field (tk6decomp docs/requirements.md "Open ids in versus").
@(private, rodata)
REQUIREMENT_OPEN := [?]Run{
	{0x30, 0x30, 0}, {0x65, 0x67, 0}, {0x96, 0x97, 0}, {0x120, 0x121, 0}, {0x13b, 0x13d, 0}, {0x142, 0x142, 0},
	{0x14d, 0x156, 0}, {0x159, 0x15a, 0},
}

// The phases a TK6 game mode stands for, as the sim's phase test (tk5_convert.requirement_param). The round end
// (FUN_002099f4) sets 7 when the match is over (win poses) and 10 when a round follows (round loss poses) [proven].
// Other modes hold in no phase.
@(private, rodata)
FLOW_PHASES := [?]struct {mode: u32, every, first: tk5_convert.Phase}{{7, .Match_End, .None}, {10, .Flashback, .Round_End}}

// The sim requirement id and param. Ids from 0x8000 on are properties (instant properties of a list).
@(private)
requirement_of :: proc(id, parameter: u32, fallbacks: ^Fallbacks) -> (sim_id, sim_parameter: u32) {
	if id == REQUIREMENT_PARAM_ZERO do return parameter == 0 ? REQUIREMENT_ALWAYS : REQUIREMENT_NEVER, parameter
	for dropped in REQUIREMENT_DROPPED do if dropped == id do return REQUIREMENT_NEVER, parameter
	if run_holds(REQUIREMENT_RUNS[:], id) {
		sim_id = run_value(REQUIREMENT_RUNS[:], id)
		if id == REQUIREMENT_FLOW_STATE do return sim_id, flow_state(parameter, fallbacks)
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
flow_state :: proc(mode: u32, fallbacks: ^Fallbacks) -> u32 {
	count(fallbacks, .Flow_State_Guessed, mode)
	for phase in FLOW_PHASES do if phase.mode == mode {
		return 1 << u32(phase.every) + u32(phase.first) * tk5_convert.PHASE_FIRST_FRAME_UNIT
	}
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
	// new sim ids: bound counter, juggle count clear, move variables H, I, J, Yoshimitsu's part swaps. Force rage (0x814e)
	// drops: rage is health only.
	{0x8120, 0x8120, 0x8163}, {0x8121, 0x8121, 0x8164}, {0x805f, 0x8067, 0x8165}, {0x8144, 0x8145, 0x816e},
	{0x8124, 0x8124, 0x8170},  // the facing turns aim at the held near side
	{0x816f, 0x816f, 0x8171},  // four push spheres off
	{0x8123, 0x8123, 0x8172},  // two hurtboxes higher
	{PROPERTY_TRACK, PROPERTY_TRACK, SIM_PROPERTY_TRACK},
}

// Past every range of the dispatcher (FUN_001b4ba0 handles 0x8001..0x81c0, 0x81c1..0x81e2, 0x81e3..0x81e8).
@(private, rodata)
PROPERTY_DEAD := [?]u32{0x81f0, 0x8202, 0x8203, 0x8216}

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
// The six new codes (4, 6, 12, 14, 16, 21) only set a new facing mode (tracking.odin code_modes), so they take a TK5 code
// the sim treats the same: 4 and 6 are no homing codes for the transition filter (FUN_001ab9e8), so TK5 5, not 3 and 4;
// 16 homes as 15. TK5 codes 39..42 have no TK6 code.
@(private, rodata)
MOTION_CODES := [MOTION_TABLE_SIZE]u8{
	0, 1, 2, 3, 5, 4, 5, 5, 6, 7, 8, 9, 9, 10, 10, 11, 11, 12, 13, 14, 15, 15,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38,
	43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55,
}

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

// --- state classes (contract 5): TK6 0..0x14 are the sim's, 0x17 and up are 2 higher than the sim's, 0x15 and 0x16
// (no TK5 twin; the hit test never hits them, FUN_001be02c) are the sim's last two classes.

STATE_CLASS_SHIFT :: 11
STATE_CLASS_UNHITTABLE_FIRST :: 0x15
STATE_CLASS_UNHITTABLE_LAST :: 0x16
SIM_STATE_CLASS_UNHITTABLE :: 30  // sim CLASS_UNHITTABLE_FIRST

@(private)
state_word_of :: proc(word: u32) -> u32 {
	class := word >> STATE_CLASS_SHIFT & 31
	sim_class := class
	switch class {
	case STATE_CLASS_UNHITTABLE_FIRST ..= STATE_CLASS_UNHITTABLE_LAST:
		sim_class = class - STATE_CLASS_UNHITTABLE_FIRST + SIM_STATE_CLASS_UNHITTABLE
	case STATE_CLASS_UNHITTABLE_LAST + 1 ..= 31: sim_class = class - 2
	}
	return word &~ (31 << STATE_CLASS_SHIFT) | sim_class << STATE_CLASS_SHIFT
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

SPECIAL_POINT_FIRST :: 0x1e  // codes 0x1e..0x27: points the game builds from the bones each frame (FUN_001d62fc)
// The sim's special point slots, in its order (hit.h T6SpecialSlot).
Special_Slot :: enum u8 {
	Chest_Ahead, Chest_Behind, Head_Ahead, Left_Foot_Low, Left_Foot_High, Right_Foot_High,
	Pelvis_Ahead, Pelvis_Ahead_Body, Left_Hand_Tip, Right_Hand_Tip,
}

// The slot of each code 0x1e..0x27, tk6decomp docs/sim_contract.md 7.
@(private, rodata)
SPECIAL_POINT_SLOTS := [?]Special_Slot {
	.Chest_Ahead, .Chest_Behind, .Pelvis_Ahead, .Pelvis_Ahead_Body, .Head_Ahead,
	.Left_Foot_Low, .Left_Foot_High, .Right_Foot_High, .Left_Hand_Tip, .Right_Hand_Tip,
}

// The point of a special code the sim builds; false for codes it does not.
@(private)
special_point :: proc(code: u8) -> (point: tk5_convert.Hit_Point, built: bool) {
	if code < SPECIAL_POINT_FIRST || int(code) >= SPECIAL_POINT_FIRST + len(SPECIAL_POINT_SLOTS) do return
	return {.Special, u8(SPECIAL_POINT_SLOTS[code - SPECIAL_POINT_FIRST])}, true
}

// The special points the sim builds, over the points tk5_convert.hitbox_hits read of the same codes.
@(private)
special_pairs :: proc(hits: ^tk5_convert.Move_Hits, codes: u32) {
	code_at :: proc(codes: u32, position: int) -> u8 {return u8(codes >> u32(24 - 8 * position))}  // file order
	for &pair, slot in hits.pairs {
		if point, built := special_point(code_at(codes, 2 * slot)); built do pair.end = point
		if point, built := special_point(code_at(codes, 2 * slot + 1)); built do pair.start = point
	}
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
			if _, built := special_point(u8(code)); !built do count(fallbacks, .Hitbox_Keep, code)
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
