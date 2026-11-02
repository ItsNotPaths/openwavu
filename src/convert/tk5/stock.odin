// Stock rules the game keeps in code, as rows the sim reads: body measures, fixed points and shots, gaze,
// hit points (tk5decomp tools/body.py, hitpoints.py, gaze.py; docs/rewrite.md Db edits). Units: mm.
package tk5_convert

import "core:fmt"
import "core:math"
import "../../db"
import formats "../../formats/tk5"

// Move set ids (index of formats.CHARACTERS) and model ids the game checks.
YOSHIMITSU :: 4
KUMA :: 11
ROGER :: 19
DEVIL_JIN :: 26
PANDA :: 32
EDDY :: 33
JINPACHI :: 34
JINPACHI_BOSS :: 35
MODEL_MARDUK :: 17
MODEL_JACK5 :: 19
MODEL_JINPACHI :: 34

// Skeleton B bones that hurtboxes and push spheres sit on, in the game's list order (0x100425a4, 0x100425dc).
HURT_BONE := [14]u8{20, 16, 12, 8, 19, 15, 11, 7, 3, 10, 6, 0, 18, 14}
HURT_LIFT := [14]f32{8 = 120, 11 = 60}  // head box above the neck, hips box above the hips (0x36e45c, 0x36e460)
PUSH_BONE := [8]u8{3, 11, 7, 0, 19, 15, 20, 16}

HURT_DEFAULT := [14]i16{220, 220, 132, 132, 330, 330, 110, 110, 275, 330, 330, 220, 440, 440}  // 0x10000d80
HURT_KUMA := [14]i16{242, 242, 187, 187, 330, 330, 165, 165, 352, 330, 330, 550, 440, 440}     // 0x10000d64
HURT_BIG := [14]i16{275, 275, 275, 275, 330, 330, 220, 220, 275, 330, 330, 440, 440, 440}      // 0x10000d48

PUSH_ARM :: f32(0h42e66667)        // 115.2 as the game stores it
PUSH_HIPS_WIDE :: f32(0h43e10001)  // 450.0 as the game stores it
PUSH_DEFAULT := [8]f32{288, PUSH_ARM, PUSH_ARM, 360, 144, 144, 144, 144}             // 0x10000d28
PUSH_KUMA := [8]f32{288, PUSH_ARM, PUSH_ARM, PUSH_HIPS_WIDE, 144, 144, 144, 144}     // 0x10000d08
PUSH_BIG := [8]f32{360, PUSH_ARM, PUSH_ARM, PUSH_HIPS_WIDE, 144, 144, 144, 144}      // 0x10000ce8

THROW_CUT_KUMA :: 40.0

Head_Probe :: struct {x, z, radius: f32}
PROBE_DEFAULT :: Head_Probe{0.1, 0.5, 0.4}

Body_Point :: struct {
	bone:   u8,
	offset: [3]f32,
}
BODY_POINTS :: 2  // T5_BODY_POINTS
L_HAND :: 12
PELVIS :: 13

// Shots: rows of the sim's T5_HITSCANS and T5_PROJECTILES, by place in the list (0: none).
EYE_LASER :: 1
FIRE :: 1

Hit_Kind :: enum u8 {None, Bone, Special, Effect, Keep, Fixed, Hitscan, Projectile}
Hit_Point :: struct {
	kind:  Hit_Kind,
	index: u8,
}
HITSCAN_TIP :: 0
HITSCAN_TAIL :: 1
PROJECTILE_FRONT :: 0
PROJECTILE_BACK_LEFT :: 1
PROJECTILE_BACK_RIGHT :: 2

BONES_A :: 107
BONES_B :: 27
SPECIAL_FIRST :: 108
SPECIAL_LAST :: 121
EFFECT_FIRST :: 0x7a
EFFECT_LAST :: 0x7d
SPECIAL_SLOT := [14]u8{6, 7, 3, 4, 5, 2, 0, 1, 6, 6, 6, 8, 9, 6}  // code 108.. -> special point slot
LAUNCH_CODE :: 118  // Jinpachi's fire point: a move with it puts the fire back on the body

// Hit categories of the stock requirements (0x33308): param v passes when a hitbox byte is in its spans;
// a v without spans wants the byte v itself.
Span :: struct {lo, hi: u8}
CATEGORIES := [21][]Span{
	1  = {{1, 2}, {27, 30}},
	3  = {{3, 4}, {0x16, 0x16}, {0x51, 0x55}, {0x58, 0x6a}, {0x71, 0x71}},
	7  = {{7, 7}, {0x24, 0x24}},
	8  = {{8, 8}, {0x33, 0x41}},
	11 = {{0xb, 0xb}, {0x2a, 0x2a}, {7, 7}, {0x24, 0x24}},
	12 = {{0xc, 0xc}, {0x42, 0x50}},
	13 = {{0xd, 0xd}, {0x72, 0x73}},
	14 = {{0xe, 0xe}, {0x2d, 0x2d}},
	15 = {{0xf, 0xf}, {0x2e, 0x2e}},
	16 = {{0x10, 0x11}, {0x17, 0x18}, {0x70, 0x70}},
	18 = {{0x12, 0x12}, {0x31, 0x31}},
	19 = {{0x13, 0x13}, {0x32, 0x32}},
	20 = {{0x14, 0x15}, {0x19, 0x1a}, {0x6e, 0x6f}},
}
ATTACK_BONES :: 32  // bits of move_hits.attack_bones; params 1..31
JOINT_REQUIREMENTS :: [?]u16{0x106, 0x113}  // param is a joint of skeleton A

// Body, points and gaze rows of one move set. Fails on requirement params the sim can not read.
// head_top: head end height of the standing idle (head_top in pose.odin).
write_stock_rows :: proc(w: ^db.Writer, char: string, moveset: int, m: formats.Motbin, head_top: f32) -> (err: string) {
	write_body(w, char, moveset, head_top)
	write_gaze(w, char, moveset)
	for r in m.requirements {
		if is_category_requirement(r.id) && r.param >= ATTACK_BONES {
			return fmt.tprintf("%s: hit category requirement %#x with param %d >= %d", char, r.id, r.param, ATTACK_BONES)
		}
		for id in JOINT_REQUIREMENTS do if r.id == id && r.param >= BONES_A {
			return fmt.tprintf("%s: joint requirement %#x with param %d >= %d", char, r.id, r.param, BONES_A)
		}
	}
	return ""
}

Hit_Pair :: struct {end, start: Hit_Point}

Move_Hits :: struct {
	pairs:        [2]Hit_Pair,  // by hitbox slot
	attack_bones: u32,
	slots:        int,
	launches:     bool,
}

// What the sim reads of a move's hitbox bytes. False: a hitbox on a special slot its row leaves unwritten.
move_hits :: proc(mv: formats.Move, moveset: int) -> (h: Move_Hits, ok: bool) {
	hitbox := hitbox_bytes(mv.hit_category)
	for &pair, slot in h.pairs do pair.end, pair.start = hit_pair(hitbox[2 * slot], hitbox[2 * slot + 1], moveset) or_return
	h.attack_bones = attack_bones(hitbox)
	h.slots = hitbox[2] != 0 ? 2 : hitbox[0] != 0 ? 1 : 0
	h.launches = hitbox[0] == LAUNCH_CODE || hitbox[1] == LAUNCH_CODE || hitbox[2] == LAUNCH_CODE || hitbox[3] == LAUNCH_CODE
	return h, true
}

// The model id of a move set's default costume (P+0x40). From 18 up it is one more (18 is Mokujin);
// Panda has Kuma's model, both Jinpachi move sets model 34.
model_of :: proc(moveset: int) -> int {
	switch {
	case moveset == PANDA: return KUMA
	case moveset >= JINPACHI: return MODEL_JINPACHI
	case moveset == EDDY: return EDDY
	case moveset >= 18: return moveset + 1
	}
	return moveset
}

@(private = "file")
write_body :: proc(w: ^db.Writer, char: string, moveset: int, head_top: f32) {
	model := model_of(moveset)
	hurt, push, cut := HURT_DEFAULT, PUSH_DEFAULT, f32(0)
	switch model {
	case KUMA: hurt, push, cut = HURT_KUMA, PUSH_KUMA, THROW_CUT_KUMA
	case MODEL_MARDUK, MODEL_JACK5, MODEL_JINPACHI: hurt, push = HURT_BIG, PUSH_BIG
	}
	probe := PROBE_DEFAULT
	switch model {  // limb init 0x1cf958
	case 4: probe = {0.2, 0.5, 0.4}
	case KUMA: probe = {0.1, 0.2, 0.45}
	case 3: probe = {0.2, 0.45, 0.45}
	}
	hitscan := moveset == DEVIL_JIN ? EYE_LASER : 0
	projectile := moveset == JINPACHI || moveset == JINPACHI_BOSS ? FIRE : 0
	body := make([dynamic]db.Value, context.temp_allocator)
	append(&body, char)
	for i in 0 ..< len(hurt) do append(&body, i64(hurt[i]), i64(HURT_BONE[i]), f64(HURT_LIFT[i]))
	for i in 0 ..< len(push) do append(&body, f64(push[i]), i64(PUSH_BONE[i]))
	append(&body, f64(cut), f64(probe.x), f64(probe.z), f64(probe.radius), f64(head_top))
	db.insert(w, "body", ..body[:])

	used := body_points(moveset)
	points: [BODY_POINTS]Body_Point
	copy(points[:], used)
	row := make([dynamic]db.Value, context.temp_allocator)
	append(&row, char, i64(len(used)))
	for p in points do append(&row, i64(p.bone), f64(p.offset.x), f64(p.offset.y), f64(p.offset.z))
	append(&row, i64(hitscan), i64(projectile))
	db.insert(w, "body_points", ..row[:])
}

// Row i is special slot 6 + i (character_points of chara 4, 0xb, 0x13).
@(private = "file")
body_points :: proc(moveset: int) -> []Body_Point {
	@(static) yoshimitsu := [?]Body_Point{{L_HAND, {100, 0, 720}}, {L_HAND, {100, 0, 400}}}
	@(static) kuma := [?]Body_Point{{PELVIS, {200, 450, -200}}}
	@(static) roger := [?]Body_Point{{PELVIS, {900, 533.333, 0}}}
	switch moveset {
	case YOSHIMITSU: return yoshimitsu[:]
	case KUMA: return kuma[:]
	case ROGER: return roger[:]
	}
	return nil
}

// Look init 0xe8ab8 (tilt: Nina, Xiaoyu, Steve 15 degrees, others 10) and head aim 0xe94c0 (Lili turns 10 degrees).
@(private = "file")
write_gaze :: proc(w: ^db.Writer, char: string, moveset: int) {
	high_tilt := moveset == 5 || moveset == 7 || moveset == 16
	turn := moveset == 30 ? 10 * 65536 / 360 : 0
	db.insert(w, "gaze", char, f64(radians(high_tilt ? 15 : 10)), i64(turn))
}

// As Python's math.radians, rounded to the game's float.
@(private = "file")
radians :: proc(degrees: f64) -> f32 {
	pi := f64(math.PI)
	return f32(degrees * (pi / 180))
}

// Move +0x40: four code bytes in file order.
@(private = "file")
hitbox_bytes :: proc(stored: u32) -> [4]u8 {
	return {u8(stored >> 24), u8(stored >> 16), u8(stored >> 8), u8(stored)}
}

// A hitbox {code, partner}: the end point, and the start point (none for partner 0).
@(private = "file")
hit_pair :: proc(code, partner: u8, moveset: int) -> (end, start: Hit_Point, ok: bool) {
	end = point_of_code(code, moveset) or_return
	if partner != 0 do start = point_of_code(partner, moveset) or_return
	return end, start, true
}

@(private = "file")
point_of_code :: proc(code: u8, moveset: int) -> (p: Hit_Point, ok: bool) {
	switch code {
	case 0 ..< BONES_B: return {.Bone, code}, true
	case SPECIAL_FIRST ..= SPECIAL_LAST:
		slot := SPECIAL_SLOT[code - SPECIAL_FIRST]
		if slot < 6 do return {.Special, slot}, true
		return character_point(slot, moveset)
	case EFFECT_FIRST ..= EFFECT_LAST: return {.Effect, code - EFFECT_FIRST}, true
	}
	return {.Keep, 0}, true
}

// What special slots 6..9 mean for the character's row.
@(private = "file")
character_point :: proc(slot: u8, moveset: int) -> (p: Hit_Point, ok: bool) {
	switch {
	case moveset == DEVIL_JIN && slot == 6: return {.Hitscan, HITSCAN_TIP}, true
	case moveset == DEVIL_JIN && slot == 7: return {.Hitscan, HITSCAN_TAIL}, true
	case moveset == DEVIL_JIN:
	case moveset == JINPACHI || moveset == JINPACHI_BOSS:
		switch slot {
		case 6: return {.Projectile, PROJECTILE_FRONT}, true
		case 8: return {.Projectile, PROJECTILE_BACK_LEFT}, true
		case 9: return {.Projectile, PROJECTILE_BACK_RIGHT}, true
		}
	case slot == 6 || slot == 7: return {.Fixed, slot - 6}, true
	}
	return {}, false
}

@(private = "file")
attack_bones :: proc(hitbox: [4]u8) -> (bits: u32) {
	for v in u8(1) ..< ATTACK_BONES {
		for code in hitbox do if in_category(v, code) {
			bits |= 1 << v
			break
		}
	}
	return
}

@(private = "file")
in_category :: proc(v, code: u8) -> bool {
	spans := int(v) < len(CATEGORIES) ? CATEGORIES[v] : nil
	if spans == nil do return code == v
	for s in spans do if code >= s.lo && code <= s.hi do return true
	return false
}

// 0x38, 0xd6..0xd9, and 0x123 + 18h + 6r + t for h < 2, r < 3, t in 1..4.
@(private = "file")
is_category_requirement :: proc(id: u16) -> bool {
	if id == 0x38 || (id >= 0xd6 && id <= 0xd9) do return true
	if id < 0x123 do return false
	k := id - 0x123
	return k < 36 && k % 6 >= 1 && k % 6 <= 4
}

// --- db edits to the move rows (tk5decomp motbin2bin.py, cancels.py)

// Move +0x3c as the loader 0xc8508 stores it (0xc8874..0xc8a84): bits 0..3 stay, file bit i (4..31) -> 35 - i.
live_flags :: proc(stored: u32) -> (live: u32) {
	live = stored & 0xf
	for i in u32(4) ..< 32 do live |= (stored >> i & 1) << (35 - i)
	return
}

// Xiaoyu's Hien throws, front and back (compare id: move +0x1c high half). Stock lifts the rider only on Kuma and Panda;
// the sim lifts it on any partner by the partner's head height.
RIDE_MOVE_IDS :: [?]u32{0x35f3, 0x35f5}

rides_partner :: proc(mv: formats.Move) -> bool {
	for id in RIDE_MOVE_IDS do if mv.unk_1c >> 16 == id do return true
	return false
}

// Codes whose param names a row (modules/tk5/sim/requirements.c, properties.c).
CODE_REFS :: [?]struct {first, last: u16, ref: string}{
	{123, 123, "move_pool"}, {218, 218, "move_pool"},  // the opponent's move is in a pool
	{296, 296, "move_pool"}, {302, 302, "move_pool"}, {308, 308, "move_pool"},  // pool and facing
	{314, 314, "move_pool"}, {320, 320, "move_pool"}, {326, 326, "move_pool"},
	{224, 225, "compare_id"},  // the target's move, its pending move, is this identity
	{0x8000 + 113, 0x8000 + 113, "tracking_row"},  // tracking
	{0x8000 + 148, 0x8000 + 149, "move"},  // force move, in place
	{0x8000 + 156, 0x8000 + 156, "move"},  // overwrite move
	{0x8000 + 158, 0x8000 + 158, "move"},  // alternate move
	{0x8000 + 163, 0x8000 + 163, "pushback"},
	{0x8000 + 168, 0x8000 + 168, "pushback"},  // target pushback
	{0x8000 + 173, 0x8000 + 173, "pushback"},  // hitscan start: its path
	{0x8000 + 175, 0x8000 + 175, "pushback"},  // projectile start: its path
	{0x8000 + 263, 0x8000 + 295, "move"},  // alias set
}

write_code_refs :: proc(w: ^db.Writer) {
	for r in CODE_REFS do for code in r.first ..= r.last do db.insert(w, "code_ref", i64(code), r.ref)
}

REQUIREMENT_END :: 0x147
REQ_FLOW_STATE :: 0xf1
REQ_FLOW_NEXT :: 0xf2
PHASE_FIRST_FRAME_UNIT :: 4096

// The sim's phases (src/sim/phase.h T5Phase).
Phase :: enum u16 {None, Intro_1, Intro_2, Ready, Fight, Ko, Flashback, Round_End, Match_End, Over}

// Requirements 0xf1, 0xf2 test the game's flow state (G_game, its next state); the db holds the phases the state stands
// for on every frame (bit p for phase p), plus one phase it stands for on its first frame only, times
// PHASE_FIRST_FRAME_UNIT. State 9 is the flashback and the first frame of the round end. Other states hold in no phase.
requirement_param :: proc(r: formats.Requirement) -> u16 {
	if r.id != REQ_FLOW_STATE && r.id != REQ_FLOW_NEXT do return r.param
	every, first: Phase
	switch r.param {
	case 1: every = .Intro_1
	case 2: every = .Intro_2
	case 4: every = .Ready
	case 5: every = .Fight
	case 6, 8: every = .Ko
	case 9: every, first = .Flashback, .Round_End
	case 10: every = .Match_End
	case 12: every = .Round_End
	case 37, 39: every = .Over
	case: return 0
	}
	return 1 << u16(every) + u16(first) * PHASE_FIRST_FRAME_UNIT
}

// The cancel option bits as the loader 0xc8508 computes them; the file value is ignored.
cancel_option :: proc(m: formats.Motbin, c: formats.Cancel) -> (option: u16) {
	ids := requirement_ids(m, c.requirements)
	extra := m.cancel_extras[c.extra]
	if c.command == 0 do option |= 1
	for id in ids {
		if id > 0x122 && id < 0x8000 do option |= 2
		if id > 0x134 && id < 0x8000 do option |= 4
		if id == 0x8162 do option |= 8
		if id >= 0x6a && id <= 0x6c do option |= 0x10
	}
	if c.command != 0 do option |= 0x10
	if extra & 0x3c00 != 0x2400 do option |= 0x40
	if extra & 0x3f == 0x10 do option |= 0x80
	return
}

// Requirement ids of the list at `first`, up to its end marker.
@(private = "file")
requirement_ids :: proc(m: formats.Motbin, first: u32) -> []u16 {
	ids := make([dynamic]u16, context.temp_allocator)
	for r in m.requirements[first:] {
		if r.id == REQUIREMENT_END do break
		append(&ids, r.id)
	}
	return ids[:]
}
