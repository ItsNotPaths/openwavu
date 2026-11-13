// The points a character's own code builds each frame (FUN_001d62fc by move set), as body_points rows, and the shot
// (tk6decomp docs/sim_contract.md 9.7).
package tk6_convert

import "../../db"

// Move set ids (P+0x54), which the game's switch reads.
CHARA_KUMA :: 11
CHARA_ROGER :: 19
CHARA_PANDA :: 32
CHARA_AZAZEL :: 38
CHARA_NANCY :: 39
CHARA_ALISA :: 41

SHOT_CODE :: 0x31  // block +0xc8: the shot's tip

// Codes of the blocks the character code fills: +0xfc, +0x108 (row 0), +0x114 (row 0), +0x120 (row 1). Yoshimitsu's
// 0x2c, 0x2d and Azazel's 0x3a come from model nodes, so they stay unbuilt.
@(private, rodata)
FIXED_POINT_CODES := [?]struct {code, row: u8}{
	{0x2f, 0}, {0x30, 0}, {0x36, 0}, {0x37, 1}, {0x38, 0}, {0x39, 1}, {0x3b, 0}, {0x3c, 1},
}

@(private)
Body_Point :: struct {
	record: u32,  // TK6 bone record
	yawed:  bool,
	offset: [3]f32,
}

PELVIS_RECORD :: 3

// The point rows of a move set: Kuma and Panda's and Roger's on the pelvis, NANCY's turned by the facing at the pelvis,
// Azazel's on the hands, Alisa's along the forearms.
@(private)
body_points :: proc(chara: int) -> []Body_Point {
	@(static) kuma := [?]Body_Point{{PELVIS_RECORD, false, {200, 450, -200}}}
	@(static) roger := [?]Body_Point{{PELVIS_RECORD, false, {900, 533.333, 0}}}
	@(static) nancy := [?]Body_Point{{PELVIS_RECORD, true, {0, 0, 2000}}, {PELVIS_RECORD, true, {0, -900, 2000}}}
	@(static) azazel := [?]Body_Point{{13, false, {400, 0, 0}}, {9, false, {400, 0, 0}}}
	@(static) alisa := [?]Body_Point{{12, false, {700, 0, 0}}, {8, false, {700, 0, 0}}}
	switch chara {
	case CHARA_KUMA, CHARA_PANDA: return kuma[:]
	case CHARA_ROGER: return roger[:]
	case CHARA_NANCY: return nancy[:]
	case CHARA_AZAZEL: return azazel[:]
	case CHARA_ALISA: return alisa[:]
	}
	return nil
}

write_body_points :: proc(w: ^db.Writer, character: string, chara: int) {
	used := body_points(chara)
	points: [2]Body_Point
	copy(points[:], used)
	row := make([dynamic]db.Value, context.temp_allocator)
	append(&row, character, i64(len(used)))
	for point in points {
		append(&row, i64(sim_bone_code(point.record)), i64(point.yawed ? 1 : 0), f64(point.offset.x), f64(point.offset.y),
			f64(point.offset.z))
	}
	db.insert(w, "body_points", ..row[:])
}
