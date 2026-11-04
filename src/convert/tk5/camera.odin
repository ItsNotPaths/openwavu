// TK5 camera tracks as .anim (layout camera), one key per frame (tk5decomp docs/camera.md 2):
//   eye xyz, target xyz (mm, in the anchor's frame: world = anchor + yaw(-facing) * local),
//   lens: vertical fov (radians), roll (radians), smoothing (1 = follow last frame's camera fully, 0 = cut).
package tk5_convert

import "core:fmt"
import "core:math"
import "../../convert"
import "../../db"
import formats "../../formats/tk5"

Camera_Packing :: enum {
	Scaled,  // fighter and stage banks: frames 0 and 1 hold the scale and offset of eye and target
	Plain,   // the global bank: no header frames, no roll, placed a quarter turn off
}

CAMERA_CHANNELS := [?]convert.Anim_Channel{{.Position, 3, -1}, {.Position, 3, -1}, {.Values, 3, -1}}

@(private = "file")
CAMERA_VALUES :: 9
@(private = "file")
SCALE_FRAMES :: 2
@(private = "file")
WRAP :: 16384
@(private = "file")
PLAIN_POSITION :: 2.5
@(private = "file")
PLAIN_FOV :: 0.0095
@(private = "file")
SMOOTHING :: 0.000125

// raw: the decoded clip, [frames][channels][3].
write_camera_anim :: proc(path: string, raw: []i16, channels: int, packing: Camera_Packing) -> (frames: int, ok: bool) {
	width := 3 * channels
	header := packing == .Scaled ? SCALE_FRAMES : 0
	frames = len(raw) / width - header
	if frames <= 0 do return
	values := make([]f32, frames * CAMERA_VALUES, context.temp_allocator)
	for f in 0 ..< frames {
		frame := raw[(f + header) * width:][:width]
		out := values[f * CAMERA_VALUES:][:CAMERA_VALUES]
		switch packing {
		case .Scaled: scaled_frame(out, frame, raw[:width], raw[width:][:width]) or_return
		case .Plain:  plain_frame(out, frame)
		}
	}
	ok = convert.write_anim(path, {
		layout        = "camera",
		frames        = frames,
		fps           = FPS,
		position_unit = 0.001,
		channels      = CAMERA_CHANNELS[:],
		values        = values,
	})
	return
}

// Eye and target: wrapped, divided by frame 0 / 100, plus frame 1 * 10.
@(private = "file")
scaled_frame :: proc(out: []f32, frame, divisors, offsets: []i16) -> (ok: bool) {
	for k in 0 ..< 6 {
		v := i32(frame[k])
		if v > WRAP / 2 do v -= WRAP
		else if v < -WRAP / 2 do v += WRAP
		if divisors[k] == 0 do return
		out[k] = f32(v) / (f32(divisors[k]) * 0.01) + f32(offsets[k]) * 10
	}
	fov := i32(frame[6])
	if fov < 0 do fov += WRAP
	out[6] = f32(fov) * 0.01 * math.RAD_PER_DEG
	out[7] = f32(frame[12]) * 1e-4
	out[8] = 1 - f32(frame[9]) * SMOOTHING
	return true
}

// The game places these at yaw 0x4000 - facing; turned here so every track uses -facing.
@(private = "file")
plain_frame :: proc(out: []f32, frame: []i16) {
	for point in 0 ..< 2 {
		x, y, z := f32(frame[3 * point]), f32(frame[3 * point + 1]), f32(frame[3 * point + 2])
		out[3 * point], out[3 * point + 1], out[3 * point + 2] = -z * PLAIN_POSITION, y * PLAIN_POSITION, x * PLAIN_POSITION
	}
	out[6] = f32(frame[6]) * PLAIN_FOV * math.RAD_PER_DEG
	out[7] = 0
	out[8] = 1 - f32(frame[9]) * SMOOTHING
}

// One throw_camera row per record. Bits 0x01, 0x02 and 0x10 are read by no camera code and are left out.
write_throw_camera_rows :: proc(w: ^db.Writer, records: []formats.Throw_Camera) {
	camera :: proc(id: u16) -> (track, coded: db.Value) {
		if id < formats.CODED_CAMERAS do return db.Null{}, n(id)
		return n(id - formats.CODED_CAMERAS), db.Null{}
	}
	bit :: proc(flags, mask: u16) -> db.Value {return n(flags & mask != 0 ? 1 : 0)}
	pos := 0
	for r, i in records {
		pos = i > 0 && records[i - 1].category == r.category ? pos + 1 : 0
		left_track, left_coded := camera(r.left)
		right_track, right_coded := camera(r.right)
		db.insert(w, "throw_camera", n(r.category), n(pos), n(r.weight), "cameras", left_track, left_coded, right_track, right_coded,
			bit(r.flags, 0x04), bit(r.flags, 0x08), bit(r.flags, 0x20), bit(r.flags, 0x40), bit(r.flags, 0x80), bit(r.flags, 0x200), bit(r.flags, 0x100))
	}
}

@(private = "file")
PROP_MOVE_CAMERA :: 0x8153
@(private = "file")
CONTAINER_BANK :: 0x4000
@(private = "file")
FRAME_CODE :: 0x7fff

// A move_camera row per move with property 0x8153 (the intro and win poses): its clip of the fighter's own bank.
write_move_camera_rows :: proc(w: ^db.Writer, char, anim_owner: string, move_keys: []string, m: formats.Motbin) {
	for mv, i in m.moves {
		if mv.extra_props < 0 || int(mv.extra_props) >= len(m.extra_props) do continue
		for x in m.extra_props[mv.extra_props:] {
			if x.unk_00 == 0 do break
			if x.unk_02 != PROP_MOVE_CAMERA do continue
			value := x.unk_04 >> 16
			owner := value & CONTAINER_BANK != 0 ? anim_owner : embedded_owner(char)
			db.insert(w, "move_camera", move_keys[i], fmt.tprintf("%s/cameras", owner), n(value &~ CONTAINER_BANK), n(x.unk_00 & FRAME_CODE))
			break
		}
	}
}
