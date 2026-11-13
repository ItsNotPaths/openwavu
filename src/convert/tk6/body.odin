// The body row: hurt and push radii by model from the game's tables (FUN_001d3e94 TOC -0x3430, -0x342c; FUN_001d428c
// TOC -0x3414), the same bones and lifts as TK5 (FUN_001d62fc lists TOC -0x3390, -0x3394).
package tk6_convert

import "../../db"
import tk5_convert "../tk5"

MODEL_KUMA :: 11
MODEL_MARDUK :: 17
MODEL_JACK6 :: 19

@(private = "file")
PUSH_HIPS_AZAZEL :: f32(0h44610001)  // 900.0 as the game stores it

@(private = "file")
Body_Radii :: struct {
	hurt:        [14]i16,
	lying_shin: i16,  // hurtboxes 4 and 5 (the shins) in the lying classes
	push:        [8]f32,
}

@(private = "file")
LYING_SHINS :: [2]int{4, 5}

@(private = "file")
RADII_DEFAULT := Body_Radii{{220, 220, 132, 132, 390, 390, 110, 110, 275, 330, 330, 220, 440, 440}, 330, tk5_convert.PUSH_DEFAULT}
@(private = "file")
RADII_KUMA := Body_Radii{{242, 242, 187, 187, 420, 420, 165, 165, 352, 330, 330, 550, 440, 440}, 330, tk5_convert.PUSH_KUMA}
@(private = "file")
RADII_BIG := Body_Radii{{275, 275, 275, 275, 390, 390, 220, 220, 297, 330, 330, 440, 440, 440}, 330, tk5_convert.PUSH_BIG}
@(private = "file")
RADII_AZAZEL := Body_Radii{
	{880, 550, 550, 550, 780, 780, 440, 440, 550, 660, 660, 880, 880, 880}, 660,
	{720, 2 * tk5_convert.PUSH_ARM, 2 * tk5_convert.PUSH_ARM, PUSH_HIPS_AZAZEL, 288, 288, 576, 576},
}
@(private = "file")
RADII_NANCY := Body_Radii{
	{550, 550, 550, 550, 780, 780, 550, 550, 550, 660, 660, 1980, 1320, 1320}, 660,
	{720, 2 * tk5_convert.PUSH_ARM, 2 * tk5_convert.PUSH_ARM, 1200, 288, 288, 576, 576},
}

// The throw range cut is TK5's. The head probe by model is the limb init's (FUN_0004347c), the same as TK5's.
write_body :: proc(w: ^db.Writer, character: string, model: int, head_top: f32) {
	radii := RADII_DEFAULT
	switch model {
	case MODEL_KUMA: radii = RADII_KUMA
	case MODEL_MARDUK, MODEL_JACK6: radii = RADII_BIG
	case MODEL_AZAZEL: radii = RADII_AZAZEL
	case MODEL_NANCY: radii = RADII_NANCY
	}
	lying := radii.hurt
	for hurtbox in LYING_SHINS do lying[hurtbox] = radii.lying_shin
	cut := model == MODEL_KUMA ? tk5_convert.THROW_CUT_KUMA : 0
	probe := tk5_convert.PROBE_DEFAULT
	switch model {
	case 4: probe = {0.2, 0.5, 0.4}
	case MODEL_KUMA: probe = {0.1, 0.2, 0.45}
	case 3: probe = {0.2, 0.45, 0.45}
	}
	row := make([dynamic]db.Value, context.temp_allocator)
	append(&row, character)
	for i in 0 ..< len(radii.hurt) {
		append(&row, i64(radii.hurt[i]), i64(lying[i]), i64(tk5_convert.HURT_BONE[i]), f64(tk5_convert.HURT_LIFT[i]))
	}
	for i in 0 ..< len(radii.push) do append(&row, f64(radii.push[i]), i64(tk5_convert.PUSH_BONE[i]))
	append(&row, f64(cut), f64(probe.x), f64(probe.z), f64(probe.radius), f64(head_top))
	db.insert(w, "body", ..row[:])
}

// Look init FUN_001dda1c: Nina, Xiaoyu and Steve (move sets 5, 7, 16: mask 0x100a0) tilt 15 degrees, others 10.
// (hole tk6-head-turn :tags (tk6 importer) :sev polish) no head turn: TK5 turns Lili's head 10 degrees (head aim 0xe94c0); TK6's head aim is not found.
write_gaze :: proc(w: ^db.Writer, character: string, chara: int) {
	TILT_HIGH :: f32(0h3e860a92)  // 15 degrees, TOC -0x3244
	TILT :: f32(0h3e32b8c2)       // 10 degrees, TOC -0x3240
	tilt := chara == 5 || chara == 7 || chara == 16 ? TILT_HIGH : TILT
	db.insert(w, "gaze", character, f64(tilt), i64(0))
}
