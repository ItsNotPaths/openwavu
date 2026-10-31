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

// Body, points, gaze and hit rows of one move set. Fails on requirement params the sim can not read.
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
	for mv, i in m.moves {
		hitbox := hitbox_bytes(mv.hit_category)
		for slot in 0 ..< 2 {
			end, start, ok := hit_pair(hitbox[2 * slot], hitbox[2 * slot + 1], moveset)
			if !ok do return fmt.tprintf("%s move %d: a hitbox on a special slot its row leaves unwritten", char, i)
			db.insert(w, "hit_pair", char, i64(i), i64(slot), i64(end.kind), i64(end.index), i64(start.kind), i64(start.index))
		}
		slots := hitbox[2] != 0 ? 2 : hitbox[0] != 0 ? 1 : 0
		launches := hitbox[0] == LAUNCH_CODE || hitbox[1] == LAUNCH_CODE || hitbox[2] == LAUNCH_CODE || hitbox[3] == LAUNCH_CODE
		db.insert(w, "move_hits", char, i64(i), i64(attack_bones(hitbox)), i64(slots), i64(launches))
	}
	return ""
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
	db.insert(w, "body", char, f64(cut), f64(probe.x), f64(probe.z), f64(probe.radius), f64(head_top), i64(hitscan), i64(projectile))
	for i in 0 ..< len(hurt) do db.insert(w, "body_hurt", char, i64(i), i64(hurt[i]), i64(HURT_BONE[i]), f64(HURT_LIFT[i]))
	for i in 0 ..< len(push) do db.insert(w, "body_push", char, i64(i), f64(push[i]), i64(PUSH_BONE[i]))
	for p, i in body_points(moveset) {
		db.insert(w, "body_point", char, i64(i), i64(p.bone), f64(p.offset.x), f64(p.offset.y), f64(p.offset.z))
	}
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
