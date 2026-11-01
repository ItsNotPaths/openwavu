// Type 1 anim banks: the finger poses and gestures (tk5decomp docs/data.md 6.5, src/visual/hand_bank.c).
// Bank: u16 type, u16 clips, u16 channels, u16 b, u32 clip offset[], u16 channel type[].
// Clip: u16 frames, s16 first[3n], s16 last[3n], u16 block offset[], blocks of 16 frames.
package tk5_formats

HAND_JOINTS :: 15  // 5 fingers x 3 joints, root joint first
BANK_HANDS :: 1
HAND_VALUES :: 3 * HAND_JOINTS  // axis x, axis y, angle per joint

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

// Delta modes 1..6: bits read, then added with the offset.
@(private = "file", rodata)
DELTAS := [LITERAL_MODE]struct {bits: u32, offset: i32}{{0, 0}, {6, -84}, {4, -20}, {2, -4}, {2, 1}, {4, 5}, {6, 21}}

Hand_Bank :: struct {
	data:  []byte,
	count: int,
}

// One frame: axis x, axis y, angle of each joint, in angle units (65536 a turn).
Hand_Frame :: [HAND_JOINTS][3]i16

read_hand_bank :: proc(data: []byte) -> (bank: Hand_Bank, ok: bool) {
	if len(data) < 8 || le_u16(data, 0) != BANK_HANDS || int(le_u16(data, 4)) != HAND_JOINTS do return
	count := int(le_u16(data, 2))
	types := 8 + 4 * count
	if count == 0 || types + 2 * HAND_JOINTS > len(data) do return
	for j in 0 ..< HAND_JOINTS {
		t := le_u16(data, types + 2 * j)
		if t < ROTATION_TYPE_FIRST || t > ROTATION_TYPE_LAST do return
	}
	return {data, count}, true
}

// Every frame of clip i, decoded.
read_hand_clip :: proc(bank: Hand_Bank, i: int, allocator := context.allocator) -> (frames: []Hand_Frame, ok: bool) {
	if i < 0 || i >= bank.count do return
	start := int(le_u32(bank.data, 8 + 4 * i) &~ 1)
	if start + 2 + 4 * HAND_VALUES > len(bank.data) do return
	clip := bank.data[start:]
	count := int(le_u16(clip, 0))
	if 2 + 4 * HAND_VALUES + 2 * ((count + 14) / FRAMES_PER_BLOCK) > len(clip) do return
	frames = make([]Hand_Frame, count, allocator)
	for &f, n in frames do f = clip_frame(clip, n) or_return
	return frames, true
}

// Frame 0 reads `first`, the last frame `last`; frame n is step (n-1) % 16 + 1 of block (n-1) / 16, from `first`.
@(private = "file")
clip_frame :: proc(clip: []byte, frame: int) -> (f: Hand_Frame, ok: bool) {
	count := int(le_u16(clip, 0))
	first, last := 2, 2 + 2 * HAND_VALUES
	source := frame + 1 >= count ? last : first
	values := (cast([^]i16)&f)[:HAND_VALUES]
	for &v, k in values do v = le_i16(clip, source + 2 * k)
	if frame <= 0 || frame + 1 >= count do return f, true
	blocks := last + 2 * HAND_VALUES
	field := 2 * int(le_u16(clip, blocks + 2 * ((frame - 1) / FRAMES_PER_BLOCK)))
	steps := (frame - 1) % FRAMES_PER_BLOCK + 1
	for &v in values {
		if field + 2 > len(clip) do return
		v = field_value(clip, field, v, steps) or_return
		field += 2 * int(le_u16(clip, field) % FIELD_UNITS)
	}
	return f, true
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
field_value :: proc(data: []byte, field: int, first: i16, steps: int) -> (value: i16, ok: bool) {
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
			v = literal * ROTATION_SCALE
		} else if mode != 0 {
			v += ((take(&r, DELTAS[mode].bits) or_return) + DELTAS[mode].offset) * ROTATION_SCALE
		}
		v = i32(i16(v))
	}
	return i16(v), true
}
