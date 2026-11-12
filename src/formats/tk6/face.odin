// Face clips: MOTA records of type 0x64 with 82 channels (tk6decomp docs/data.md "Hands, face and move cameras"): 40 bone
// pairs {position in mm, rotation in TK5's axis form}, then 2 scale channels. The stream is TK5's body anim stream
// (tk5decomp docs/data.md 6.2), big endian, decoded here for any channel count.
package tk6_formats

import "base:intrinsics"
import tk5 "../tk5"

FACE_BONES :: 40
FACE_CHANNELS :: 2 * FACE_BONES + 2

// Per frame, per channel: a position or a scale as decoded, or a rotation (axis pitch, axis yaw, angle) in radians.
Face_Clip :: struct {
	frames: int,
	values: [][FACE_CHANNELS][3]f32,
}

read_face_clip :: proc(bank: Mota_Bank, index: int, allocator := context.allocator) -> (clip: Face_Clip, ok: bool) {
	if index < 0 || index >= bank.count do return
	start := mota_anim_start(bank, index)
	if start + 4 + 2 * FACE_CHANNELS > len(bank.data) do return
	record := bank.data[start:]
	if tk5.be_u16(record, 0) != ANIM_TYPE_BODY || tk5.be_u16(record, 2) != FACE_CHANNELS do return
	header := 4 + 2 * FACE_CHANNELS
	frames, positions := int(tk5.be_u16(record, header)), int(tk5.be_u16(record, header + 4))
	pose := header + 6 + 4 * positions
	blocks := pose
	for channel in 0 ..< FACE_CHANNELS do blocks += is_rotation(channel_type(record, channel)) ? 6 : 12
	if frames == 0 || blocks + 4 * ((frames + 14) >> 4) > len(record) do return
	clip = {frames, make([][FACE_CHANNELS][3]f32, frames, allocator)}
	for &values, frame in clip.values do decode_frame(record, {header, pose, blocks}, frame, &values)
	return clip, true
}

@(private = "file")
channel_type :: proc(record: []byte, channel: int) -> u16 {return tk5.be_u16(record, 4 + 2 * channel)}

@(private = "file")
is_rotation :: proc(channel_type: u16) -> bool {return channel_type >= 4 && channel_type <= 7}

// Where the parts of a record start: u16 frames, u8 rotation shift, u8 position shift, u16 n, f32 scale[n]; the base pose;
// the u32 block offsets, counted from their own table.
@(private = "file")
Record_Places :: struct {header, pose, blocks: int}

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

// Frame 0 is the base pose; frame n is step (n - 1) % 16 of block (n - 1) / 16. Position channels take the scales in order.
@(private = "file")
decode_frame :: proc(record: []byte, places: Record_Places, frame: int, out: ^[FACE_CHANNELS][3]f32) {
	rotation_shift := u32(record[places.header + 2] & 0x7f)
	position_shift := u32(record[places.header + 3])
	positions := int(tk5.be_u16(record, places.header + 4))
	state: [FACE_CHANNELS][3]i16
	at := places.pose
	for channel in 0 ..< FACE_CHANNELS {
		rotation := is_rotation(channel_type(record, channel))
		for axis in 0 ..< 3 {
			if rotation {
				base := tk5.be_i16(record, at + 2 * axis)
				out[channel][axis] = f32(base) * tk5.ANGLE
				state[channel][axis] = shift_right(base, rotation_shift)
			} else {
				out[channel][axis] = tk5.be_f32(record, at + 4 * axis)
			}
		}
		at += rotation ? 6 : 12
	}
	if frame <= 0 do return

	field := places.blocks + int(tk5.be_u32(record, places.blocks + 4 * ((frame - 1) >> 4)))
	steps := (frame - 1) & 15
	mode: Key_Mode
	scale_index := 0
	for channel in 0 ..< FACE_CHANNELS {
		rotation := is_rotation(channel_type(record, channel))
		scale: f32 = 0
		if !rotation {
			if scale_index < positions do scale = tk5.be_f32(record, places.header + 6 + 4 * scale_index)
			scale_index += 1
		}
		for axis in 0 ..< 3 {
			value := decode_field(&mode, record, field, state[channel][axis], steps)
			field += int(record[field] >> 2)
			if rotation do out[channel][axis] = f32(i32(shift_left(i32(value), rotation_shift))) * tk5.ANGLE
			else do out[channel][axis] = intrinsics.fused_mul_add(f32(i32(shift_left(i32(value), position_shift))), scale, out[channel][axis])
		}
	}
}

// One axis of one channel. Head: b0 = size << 2 | code bits 9..8, b1 = code bits 7..6 | 6 data bits.
@(private = "file")
decode_field :: proc(mode: ^Key_Mode, data: []byte, field: int, value: i16, steps: int) -> i16 {
	head := u32(data[field] & 3) << 8 | u32(data[field + 1])
	code := head >> 6
	bits := Bits{data, field + 2, head & 0x3f, 6}
	run: u16 = 0
	if code == CODE_RUN {
		run = u16((head & 0x3f) >> 2) - 1
		bits.buffer, bits.count = head & 3, 2
	} else {
		set_mode(mode, code)
	}
	result := u16(i32(value) + (mode.bits == HOLD ? 0 : read_delta(&bits, mode^)))
	velocity: i32 = 0
	for _ in 0 ..< steps {
		if run == 0 {
			code = bits_read(&bits, 4)
			if code == CODE_RUN do run = u16(bits_read(&bits, 4)) - 1
			else do set_mode(mode, code)
		} else {
			run -= 1
		}
		if mode.bits == HOLD do break
		velocity += read_delta(&bits, mode^)
		result = u16(i32(result) + velocity)
	}
	return i16(result)
}

@(private = "file")
set_mode :: proc(mode: ^Key_Mode, code: u32) {
	mode^ = code == CODE_HOLD ? {HOLD, 0} : MODES[code]
}

@(private = "file")
read_delta :: proc(bits: ^Bits, mode: Key_Mode) -> i32 {
	return mode.bits == 0 ? 0 : i32(i16(bits_read(bits, mode.bits))) + mode.offset
}

// Most significant bit first.
@(private = "file")
Bits :: struct {
	data:   []byte,
	at:     int,
	buffer: u32,
	count:  i32,
}

@(private = "file")
bits_read :: proc(bits: ^Bits, count: i32) -> u32 {
	for bits.count < count {
		bits.buffer = bits.buffer << 8 | u32(bits.data[bits.at])
		bits.at += 1
		bits.count += 8
	}
	bits.count -= count
	value := bits.buffer >> u32(bits.count)
	bits.buffer &= ~(max(u32) << u32(bits.count))
	return value
}

// PPC slw / sraw: the shift count is 6 bits; 32..63 shift everything out.
@(private = "file")
shift_left :: proc(value: i32, count: u32) -> u32 {
	masked := count & 63
	return masked < 32 ? u32(value) << masked : 0
}

@(private = "file")
shift_right :: proc(value: i16, count: u32) -> i16 {
	masked := count & 63
	if masked > 15 do return value < 0 ? -1 : 0
	return value >> masked
}
