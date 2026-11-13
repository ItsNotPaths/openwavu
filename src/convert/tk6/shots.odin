// Camera shots in plain terms (schema throw_shot, move_throw_shot, hit_zoom): TK6's throw camera picks and attack zoom
// categories, decoded from the game's code (tk6decomp docs/data.md "Camera picks", "Coded throw shot", "Attack zoom").
// Degrees throughout. Yaw is added to the fight camera's bearing with the thrower or attacker on the right of the screen.
package tk6_convert

import "../../db"
import formats "../../formats/tk6"
import tk5_convert "../tk5"

PROPERTY_THROW_SHOT :: 0x81cf  // value: a camera pick list

// Coded shot ids 0x800..SHOT_BITS_LAST: bits 0..1 the yaw range, 2..3 the pitch range, 0x10 cut in, 0x80 further back.
SHOT_BITS_FIRST :: 0x800
SHOT_BITS_LAST :: 0x8fb
SHOT_CUT_IN :: 0x10
SHOT_FURTHER :: 0x80
SHOT_FURTHEST :: 0x8fc  // the fight camera's view from further back
SHOT_NONE :: [?]u16{0x8fd, 0x8ff}
// The fight camera's view with a fov of 39..42: the fight camera stays.
SHOT_FIGHT_VIEW :: 0x901
FURTHER_SCALE :: 1.4
UNROLLED_FOV :: 50

Range :: [2]f64

@(private = "file")
Shot :: struct {
	keeps_fight_camera, cut_in: bool,
	yaw, pitch, fov:            Range,
	distance_scale:             f64,
}

// built false: a shot the presenter has no code for; the fight camera stays.
@(private = "file")
coded_shot :: proc(id: u16, thrower_right: bool, extra_degrees: f64) -> (shot: Shot, built: bool) {
	shot.distance_scale = 1
	switch {
	case id >= SHOT_BITS_FIRST && id <= SHOT_BITS_LAST:
		turn: Range
		switch id & 3 {
		case 0: turn = {60, 80}
		case 2: turn = {-80, -60}
		case: turn = {-10, -10}
		}
		sign := thrower_right ? 1.0 : -1.0
		shot.yaw = ordered({sign * turn[0] + extra_degrees, sign * turn[1] + extra_degrees})
		switch id & 0xc {
		case 4: shot.pitch = {-10, -8}
		case 8: shot.pitch = {30, 40}
		case: shot.pitch = {-3, 3}
		}
		shot.fov = {39, 42}
		if id & SHOT_FURTHER != 0 do shot.distance_scale = FURTHER_SCALE
		shot.cut_in = id & SHOT_CUT_IN != 0
		return shot, true
	case id == SHOT_FURTHEST:
		shot.fov = {UNROLLED_FOV, UNROLLED_FOV}
		shot.distance_scale = FURTHER_SCALE
		return shot, true
	case id == SHOT_FIGHT_VIEW, id == SHOT_NONE[0], id == SHOT_NONE[1]:
		return {keeps_fight_camera = true}, true
	}
	return {keeps_fight_camera = true}, false
}

@(private = "file")
flag :: proc(on: bool) -> db.Value {return n(on ? 1 : 0)}

@(private = "file")
ordered :: proc(range: Range) -> Range {return range[0] <= range[1] ? range : {range[1], range[0]}}

// A character's throw shot lists and the moves that draw from them.
write_throw_shots :: proc(w: ^db.Writer, character: string, m: formats.Motbin, fallbacks: ^Fallbacks) {
	for list, number in m.camera_pick_lists {
		for pick, pos in m.camera_picks[list.first:] {
			if pick.kind == 0 do break
			for side in 0 ..< 2 {
				shot, built := coded_shot(pick.shot[side], side == 1, f64(pick.extra_degrees))
				if pick.kind != formats.CAMERA_PICK_CODED do shot, built = {keeps_fight_camera = true}, false
				if !built do count(fallbacks, .Throw_Shot_Unbuilt, u32(pick.kind) << 16 | u32(pick.shot[side]))
				db.insert(w, "throw_shot", character, n(number), n(pos), n(side), n(pick.weight), flag(shot.keeps_fight_camera),
					shot.yaw[0], shot.yaw[1], shot.pitch[0], shot.pitch[1], shot.fov[0], shot.fov[1], shot.distance_scale,
					flag(shot.cut_in))
			}
		}
	}
	for move, index in m.moves {
		if move.extra_properties < 0 do continue
		for property in m.extra_properties[move.extra_properties:] {
			if property.frame == 0 do break
			if property.id != PROPERTY_THROW_SHOT do continue
			db.insert(w, "move_throw_shot", row_key(character, "move", index), n(property.frame & tk5_convert.FRAME_CODE), n(property.value))
		}
	}
}

// The game's attack zoom by camera category (FUN_0026a53c): categories 1..6, 23..31, 34..50; three lengths by the
// category's kind, 4..6 only near a counter hit.
@(private = "file")
HIT_ZOOM_FRAMES :: [3]int{13, 18, 23}
HIT_ZOOM_DISTANCE :: 4000
HIT_ZOOM_FOV :: 35
HIT_ZOOM_TURN :: 60

@(private = "file")
Turn :: struct {weight: int, turn, wall_turn: f64}

write_hit_zooms :: proc(w: ^db.Writer) {
	// Below 34 the swing is random, none by a wall. From 34, the category's place in its group of six names the swing.
	random := []Turn{{1, HIT_ZOOM_TURN, 0}, {1, -HIT_ZOOM_TURN, 0}, {2, 0, 0}}
	toward := Turn{1, HIT_ZOOM_TURN, HIT_ZOOM_TURN}
	away := Turn{1, -HIT_ZOOM_TURN, -HIT_ZOOM_TURN}
	straight := Turn{1, 0, 0}
	by_place := [6][]Turn{{toward}, {straight}, {away}, {{1, HIT_ZOOM_TURN, 0}, straight}, {toward, away}, {straight, {1, -HIT_ZOOM_TURN, 0}}}
	write :: proc(w: ^db.Writer, category, kind: int, turns: []Turn) {
		frames := HIT_ZOOM_FRAMES
		db.insert(w, "hit_zoom", n(category), n(frames[kind]), f64(HIT_ZOOM_DISTANCE), f64(HIT_ZOOM_FOV), flag(category >= 4 && category <= 6))
		for turn, pos in turns do db.insert(w, "hit_zoom_turn", n(category), n(pos), n(turn.weight), turn.turn, turn.wall_turn)
	}
	for category in 1 ..= 6 do write(w, category, (category - 1) % 3, random)
	for category in 23 ..= 31 do write(w, category, (category - 23) % 3, random)
	for category in 34 ..= 50 do write(w, category, (category - 34) / 6, by_place[(category - 34) % 6])
}
