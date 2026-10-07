// Animation banks: LE, 23 channels, frame 0 base pose then 16-frame blocks of second-order
// delta streams. Port of FUN_000b8a88 as in ../tk5decomp/sim/src/anim.c. data.md §5-6.
package tk5_formats

import "base:intrinsics"

CHANNELS :: 23
BANK_BODY :: 0x64
ANIM_BASE :: 0x12    // base pose, after u16 frames, u8 rot shift, i8 pos shift, u16 n, f32 scale[3]
ANIM_BLOCKS :: 0xae  // u32 block offsets, from this table
ANGLE :: f32(0h38c90fdb)  // 2pi/65536 (TOC-0x5b2c)

Anim_Bank :: struct {
	data:    []byte,
	count:   int,
	offsets: int,  // u32 anim offset table
}

// Per frame, per channel: position (channels 0, 1, 6) or rotation (axis pitch, axis yaw, angle) in radians.
Anim :: struct {
	frames: int,
	values: [][CHANNELS][3]f32,
}

// Channels 0, 1 and 6 are positions. The game tests the index, not the bone types.
channel_is_rot :: proc(ch: int) -> bool {return ch != 0 && ch != 1 && ch != 6}

// u16 type, u16 anim count, u16 bone count, u16 bone type[], pad to 4, u32 anim offset[].
read_bank :: proc(data: []byte) -> (bank: Anim_Bank, ok: bool) {
	if len(data) < 6 || le_u16(data, 0) != BANK_BODY do return {}, false
	count, bones := int(le_u16(data, 2)), int(le_u16(data, 4))
	offsets := 6 + 2 * bones + (bones % 2 == 0 ? 2 : 0)
	if offsets + 4 * count > len(data) do return {}, false
	return {data, count, offsets}, true
}

read_anim :: proc(bank: Anim_Bank, index: int, allocator := context.allocator) -> (a: Anim, ok: bool) {
	if index < 0 || index >= bank.count do return {}, false
	start := int(le_u32(bank.data, bank.offsets + 4 * index) &~ 1)
	if start + ANIM_BLOCKS > len(bank.data) do return {}, false
	h := bank.data[start:]
	a.frames = int(le_u16(h, 0))
	a.values = make([][CHANNELS][3]f32, a.frames, allocator)
	for &v, f in a.values do decode_frame(h, f, &v)
	return a, true
}

@(private = "file")
Key_Mode :: struct {
	bits, offset: i32,
}

@(private = "file")
HOLD :: 99
@(private = "file")
CODE_RUN :: 14
@(private = "file")
CODE_HOLD :: 15

@(private = "file", rodata)
MODES := [14]Key_Mode{
	{0, 0}, {2, 1}, {2, -4}, {4, 5}, {4, -20}, {6, 21}, {6, -84},
	{8, 85}, {8, -340}, {10, 341}, {10, -1364}, {12, 1365}, {12, -5460}, {16, 0},
}

// h: the anim header. Out-of-range frames clamp to 0..frames-1.
@(private = "file")
decode_frame :: proc(h: []byte, frame: int, out: ^[CHANNELS][3]f32) {
	frames := int(le_u16(h, 0))
	rot_shift := u32(h[2] & 0x7f)
	pos_shift := u32(h[3])
	f := max(frame, 0)
	if f + 1 >= frames do f = frames - 1

	state: [CHANNELS][3]i16
	p := ANIM_BASE
	for ch in 0 ..< CHANNELS {
		for i in 0 ..< 3 {
			if channel_is_rot(ch) {
				base := le_i16(h, p + 2 * i)
				out[ch][i] = f32(base) * ANGLE
				state[ch][i] = sraw16(base, rot_shift)
			} else {
				out[ch][i] = le_f32(h, p + 4 * i)
			}
		}
		p += channel_is_rot(ch) ? 6 : 12
	}
	if f <= 0 do return

	field := ANIM_BLOCKS + int(le_u32(h, ANIM_BLOCKS + 4 * ((f - 1) >> 4)))
	steps := (f - 1) & 15
	mode: Key_Mode
	for ch in 0 ..< CHANNELS {
		for i in 0 ..< 3 {
			v := decode_field(&mode, h, field, state[ch][i], steps)
			field += int(h[field] >> 2)
			if channel_is_rot(ch) {
				out[ch][i] = f32(i32(slw(i32(v), rot_shift))) * ANGLE
			} else {
				scale := le_f32(h, 6 + 4 * (ch == 6 ? 2 : ch))
				out[ch][i] = intrinsics.fused_mul_add(f32(i32(slw(i32(v), pos_shift))), scale, out[ch][i])
			}
		}
	}
}

// One axis of one channel. Head: b0 = size << 2 | code bits 9..8, b1 = code bits 7..6 | 6 data bits.
// Runs count in 16 bits, so a run of 0 (0xffff) never ends inside a block.
@(private = "file")
decode_field :: proc(m: ^Key_Mode, d: []byte, field: int, value: i16, steps: int) -> i16 {
	head := u32(d[field] & 3) << 8 | u32(d[field + 1])
	code := head >> 6
	b := Bits{d, field + 2, head & 0x3f, 6}
	run: u16 = 0
	if code == CODE_RUN {
		run = u16((head & 0x3f) >> 2) - 1
		b.buf, b.n = head & 3, 2
	} else {
		set_mode(m, code)
	}
	v := u16(i32(value) + (m.bits == HOLD ? 0 : read_delta(&b, m^)))
	vel: i32 = 0
	for _ in 0 ..< steps {
		if run == 0 {
			code = bits_read(&b, 4)
			if code == CODE_RUN do run = u16(bits_read(&b, 4)) - 1
			else do set_mode(m, code)
		} else {
			run -= 1
		}
		if m.bits == HOLD do break
		vel += read_delta(&b, m^)
		v = u16(i32(v) + vel)
	}
	return i16(v)
}

@(private = "file")
set_mode :: proc(m: ^Key_Mode, code: u32) {
	m^ = code == CODE_HOLD ? {HOLD, 0} : MODES[code]
}

@(private = "file")
read_delta :: proc(b: ^Bits, m: Key_Mode) -> i32 {
	return m.bits == 0 ? 0 : i32(i16(bits_read(b, m.bits))) + m.offset
}

// MSB-first bit reader. At most 23 bits are buffered.
@(private = "file")
Bits :: struct {
	d:   []byte,
	pos: int,
	buf: u32,
	n:   i32,
}

@(private = "file")
bits_read :: proc(b: ^Bits, count: i32) -> u32 {
	for b.n < count {
		b.buf = b.buf << 8 | u32(b.d[b.pos])
		b.pos += 1
		b.n += 8
	}
	b.n -= count
	v := b.buf >> u32(b.n)
	b.buf &= ~(max(u32) << u32(b.n))
	return v
}

// PPC slw / sraw: the shift count is 6 bits; 32..63 shift everything out.
@(private = "file")
slw :: proc(x: i32, n: u32) -> u32 {
	s := n & 63
	return s < 32 ? u32(x) << s : 0
}

@(private = "file")
sraw16 :: proc(x: i16, n: u32) -> i16 {
	s := n & 63
	if s > 15 do return x < 0 ? -1 : 0
	return x >> s
}
