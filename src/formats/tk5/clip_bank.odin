// Type 1 anim banks: the finger poses and gestures, the face, the camera tracks (tk5decomp docs/data.md 6.5, docs/camera.md 2).
// Bank: u16 type, u16 clips, u16 channels, u16 b, u32 clip offset[], u16 channel type[].
// Clip: u16 frames, s16 first[3n], s16 last[3n], u16 block offset[], blocks of 16 frames.
package tk5_formats

import "core:slice"

CLIP_BANK_TYPE :: 1
BANK_HANDS :: 1
BANK_FACE :: 2
BANK_CAMERAS :: 5
HAND_JOINTS :: 15  // 5 fingers x 3 joints, root joint first
HAND_VALUES :: 3 * HAND_JOINTS  // axis x, axis y, angle per joint
FACE_CHANNELS :: 38  // the face bones A81..106: turns, moves and the jaw scale
SCALE_TYPE :: 4  // a channel type: x, y, z scale the rotation rows, 100 = 1.0
CAMERA_CHANNELS :: 5  // eye, target, fov, smoothing, roll; the global bank has no roll

@(private = "file")
ROTATION_TYPE_FIRST :: 5
@(private = "file")
ROTATION_TYPE_LAST :: 8
@(private = "file")
FRAMES_PER_BLOCK :: 16
@(private = "file")
FIELD_UNITS :: 512  // head: bits 0..8 the field length in u16, the rest the first stream bits
@(private = "file")
HEAD_BITS :: 7
@(private = "file")
RUN_CODE :: 8
@(private = "file")
LITERAL_MODE :: 7
@(private = "file")
ROTATION_SCALE :: 16
@(private = "file")
POSITION_SCALE :: 4

// Delta modes 1..6: bits read, then added with the offset.
@(private = "file", rodata)
DELTAS := [LITERAL_MODE]struct {bits: u32, offset: i32}{{0, 0}, {6, -84}, {4, -20}, {2, -4}, {2, 1}, {4, 5}, {6, 21}}

Clip_Bank :: struct {
	data:     []byte,
	count:    int,
	channels: int,
}

// One frame: axis x, axis y, angle of each joint, in angle units (65536 a turn).
Hand_Frame :: [HAND_JOINTS][3]i16

read_clip_bank :: proc(data: []byte) -> (bank: Clip_Bank, ok: bool) {
	if len(data) < 8 || le_u16(data, 0) != CLIP_BANK_TYPE do return
	bank = {data, int(le_u16(data, 2)), int(le_u16(data, 4))}
	if bank.count == 0 || bank.channels == 0 || type_table(bank) + 2 * bank.channels > len(data) do return
	return bank, true
}

read_hand_bank :: proc(data: []byte) -> (bank: Clip_Bank, ok: bool) {
	bank = read_clip_bank(data) or_return
	if bank.channels != HAND_JOINTS do return {}, false
	for j in 0 ..< HAND_JOINTS do if !is_rotation(bank, j) do return {}, false
	return bank, true
}

read_face_bank :: proc(data: []byte) -> (bank: Clip_Bank, ok: bool) {
	bank = read_clip_bank(data) or_return
	if bank.channels != FACE_CHANNELS do return {}, false
	return bank, true
}

// An empty bank section (type 0, no clips): king, armor_king, yoshimitsu and jack5 have no intro or win faces.
empty_bank :: proc(data: []byte) -> bool {return len(data) < 8 || le_u16(data, 2) == 0}

read_camera_bank :: proc(data: []byte) -> (bank: Clip_Bank, ok: bool) {
	bank = read_clip_bank(data) or_return
	if bank.channels != CAMERA_CHANNELS && bank.channels != CAMERA_CHANNELS - 1 do return {}, false
	for c in 0 ..< bank.channels do if is_rotation(bank, c) do return {}, false
	return bank, true
}

// Every frame of clip i, decoded: [frames][channels][3].
read_clip :: proc(bank: Clip_Bank, i: int, allocator := context.allocator) -> (values: []i16, ok: bool) {
	if i < 0 || i >= bank.count do return
	width := 3 * bank.channels
	start := int(le_u32(bank.data, 8 + 4 * i) &~ 1)
	if start + 2 + 4 * width > len(bank.data) do return
	clip := bank.data[start:]
	count := int(le_u16(clip, 0))
	if 2 + 4 * width + 2 * ((count + 14) / FRAMES_PER_BLOCK) > len(clip) do return
	values = make([]i16, count * width, allocator)
	for n in 0 ..< count do clip_frame(bank, clip, n, values[n * width:][:width]) or_return
	return values, true
}

read_hand_clip :: proc(bank: Clip_Bank, i: int, allocator := context.allocator) -> (frames: []Hand_Frame, ok: bool) {
	values := read_clip(bank, i, allocator) or_return
	return slice.reinterpret([]Hand_Frame, values), true
}

@(private = "file")
type_table :: proc(bank: Clip_Bank) -> int {return 8 + 4 * bank.count}

// 5..8 a rotation; the face also has 20 a position and 4 a scale (data.md 6.5).
channel_type :: proc(bank: Clip_Bank, channel: int) -> u16 {return le_u16(bank.data, type_table(bank) + 2 * channel)}

is_rotation :: proc(bank: Clip_Bank, channel: int) -> bool {
	t := channel_type(bank, channel)
	return t >= ROTATION_TYPE_FIRST && t <= ROTATION_TYPE_LAST
}

// Frame 0 reads `first`, the last frame `last`; frame n is step (n-1) % 16 + 1 of block (n-1) / 16, from `first`.
@(private = "file")
clip_frame :: proc(bank: Clip_Bank, clip: []byte, frame: int, values: []i16) -> (ok: bool) {
	count := int(le_u16(clip, 0))
	first, last := 2, 2 + 2 * len(values)
	source := frame + 1 >= count ? last : first
	for &v, k in values do v = le_i16(clip, source + 2 * k)
	if frame <= 0 || frame + 1 >= count do return true
	blocks := last + 2 * len(values)
	field := 2 * int(le_u16(clip, blocks + 2 * ((frame - 1) / FRAMES_PER_BLOCK)))
	steps := (frame - 1) % FRAMES_PER_BLOCK + 1
	for &v, k in values {
		if field + 2 > len(clip) do return
		scale := i32(is_rotation(bank, k / 3) ? ROTATION_SCALE : POSITION_SCALE)
		v = field_value(clip, field, v, steps, scale) or_return
		field += 2 * int(le_u16(clip, field) % FIELD_UNITS)
	}
	return true
}

// LSB-first bits over the u16 words of a field.
@(private = "file")
Bits :: struct {
	data:  []byte,
	next:  int,
	bits:  u32,
	count: u32,
}

@(private = "file")
take :: proc(r: ^Bits, width: u32) -> (v: i32, ok: bool) {
	for r.count < width {
		if r.next + 2 > len(r.data) do return
		r.bits |= u32(le_u16(r.data, r.next)) << r.count
		r.next += 2
		r.count += 16
	}
	v = i32(r.bits & (1 << width - 1))
	r.bits >>= width
	r.count -= width
	return v, true
}

@(private = "file")
field_value :: proc(data: []byte, field: int, first: i16, steps: int, scale: i32) -> (value: i16, ok: bool) {
	head := le_u16(data, field)
	r := Bits{data, field + 2, u32(head / FIELD_UNITS), HEAD_BITS}
	v, mode, run := i32(first), i32(0), i32(0)
	for _ in 0 ..< steps {
		if run > 0 {
			run -= 1
		} else {
			mode = take(&r, 4) or_return
			if mode >= RUN_CODE {
				run = (take(&r, 4) or_return) + 1
				mode -= RUN_CODE
			}
		}
		if mode == LITERAL_MODE {
			literal := take(&r, 12) or_return
			if literal >= 2048 do literal -= 4096
			v = literal * scale
		} else if mode != 0 {
			v += ((take(&r, DELTAS[mode].bits) or_return) + DELTAS[mode].offset) * scale
		}
		v = i32(i16(v))
	}
	return i16(v), true
}
