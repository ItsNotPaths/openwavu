// Body animation banks ("MOTA"), big endian; tk6decomp docs/data.md "Animation banks". An anim is either a TK5 anim
// (tk5decomp docs/data.md 6.2) in big endian with its channel types in front, decoded by the TK5 sampler after a swap,
// or stored plain: a float per frame, channel and axis, rotations as euler angles.
package tk6_formats

import "core:math"
import "core:slice"
import tk5 "../tk5"

MOTA_TABLE :: 0x14  // u32 anim offsets, from the bank start
ANIM_TYPE_BODY :: 0x64
ANIM_TYPE_PLAIN :: 0xc8  // u16 type, u16 channel count, u32 frames, u32 channel type[], f32 value[frames][channels][3]
POSITION_CHANNELS :: 3

Mota_Bank :: struct {
	data:   []byte,
	count:  int,
	starts: []int,  // sorted distinct anim starts: where each record ends
}

// "MOTA", u32 version, u32 table start, u32 count, u32 0, u32 offset[count].
read_mota :: proc(data: []byte, allocator := context.allocator) -> (bank: Mota_Bank, ok: bool) {
	if len(data) < MOTA_TABLE || string(data[:4]) != "MOTA" do return
	count := int(tk5.be_u32(data, 0x0c))
	if MOTA_TABLE + 4 * count > len(data) do return
	starts := make([]int, count, allocator)
	for &start, index in starts do start = int(tk5.be_u32(data, MOTA_TABLE + 4 * index))
	slice.sort(starts)
	return {data, count, slice.unique(starts)}, true
}

// Ids with the same start are one record.
mota_anim_start :: proc(bank: Mota_Bank, index: int) -> int {return int(tk5.be_u32(bank.data, MOTA_TABLE + 4 * index))}

// The record of an id: from its start to the next record's.
@(private = "file")
mota_record :: proc(bank: Mota_Bank, index: int) -> (record: []byte, ok: bool) {
	if index < 0 || index >= bank.count do return
	start := mota_anim_start(bank, index)
	end := len(bank.data)
	if at, found := slice.binary_search(bank.starts, start); found && at + 1 < len(bank.starts) do end = bank.starts[at + 1]
	if start + 4 > end || end > len(bank.data) do return
	return bank.data[start:end], true
}

read_mota_anim :: proc(bank: Mota_Bank, index: int, allocator := context.allocator) -> (anim: tk5.Anim, ok: bool) {
	record := mota_record(bank, index) or_return
	if tk5.be_u16(record, 0) == ANIM_TYPE_PLAIN do return read_plain_anim(record, allocator)
	if tk5.be_u16(record, 0) != ANIM_TYPE_BODY do return
	little := little_endian_bank(record, context.temp_allocator) or_return
	tk5_bank := tk5.read_bank(little) or_return
	return tk5.read_anim(tk5_bank, 0, allocator)
}

CAMERA_CHANNELS :: 4  // eye (mm, fighter space), turn (euler x, y, z), field of view (radians), unused

// A camera clip of container section 5 (tk5.BANK_CAMERAS): a plain record of the 4 camera channels. 11 of 263 banks
// also hold type 0x64 records; no roster move points at them.
read_camera_clip :: proc(bank: Mota_Bank, index: int, allocator := context.allocator) -> (keys: [][CAMERA_CHANNELS][3]f32, ok: bool) {
	record := mota_record(bank, index) or_return
	if tk5.be_u16(record, 0) != ANIM_TYPE_PLAIN || tk5.be_u16(record, 2) != CAMERA_CHANNELS do return
	values := 8 + 4 * CAMERA_CHANNELS
	frames := int(tk5.be_u32(record, 4))
	if values + frames * CAMERA_CHANNELS * 12 > len(record) do return
	keys = make([][CAMERA_CHANNELS][3]f32, frames, allocator)
	for &key, frame in keys do for &channel, channel_index in key {
		at := values + 12 * (frame * CAMERA_CHANNELS + channel_index)
		channel = {tk5.be_f32(record, at), tk5.be_f32(record, at + 4), tk5.be_f32(record, at + 8)}
	}
	return keys, true
}

// The 23 body channels; channels past them (props) are dropped.
@(private = "file")
read_plain_anim :: proc(record: []byte, allocator := context.allocator) -> (anim: tk5.Anim, ok: bool) {
	channels := int(tk5.be_u16(record, 2))
	values := 8 + 4 * channels
	if channels < tk5.CHANNELS || values > len(record) do return
	channel_type :: proc(record: []byte, channel: int) -> u16 {return u16(tk5.be_u32(record, 8 + 4 * channel))}
	for channel in 0 ..< tk5.CHANNELS do if tk5.channel_is_rot(channel) != is_rotation(channel_type(record, channel)) do return
	anim.frames = int(tk5.be_u32(record, 4))
	if values + anim.frames * channels * 12 > len(record) do return {}, false
	anim.values = make([][tk5.CHANNELS][3]f32, anim.frames, allocator)
	for &frame, frame_index in anim.values do for &channel, channel_index in frame {
		at := values + 12 * (frame_index * channels + channel_index)
		channel = {tk5.be_f32(record, at), tk5.be_f32(record, at + 4), tk5.be_f32(record, at + 8)}
		if is_rotation(channel_type(record, channel_index)) do channel = axis_turn_of_euler(channel)
	}
	return anim, true
}

// Plain records keep rotations as euler angles, not as axis pitch, axis yaw, angle. The turn is the game's matrix
// Rx Ry Rz (t6_mat_rotate_* order) as a quaternion; the sim wants it in its axis form.
@(private = "file")
axis_turn_of_euler :: proc(euler: [3]f32) -> (axis_turn: [3]f32) {
	half_x, half_y, half_z := -euler.x / 2, -euler.y / 2, -euler.z / 2
	turn := quaternion(w = math.cos(half_x), x = math.sin(half_x), y = 0, z = 0) *
		quaternion(w = math.cos(half_y), x = 0, y = math.sin(half_y), z = 0) *
		quaternion(w = math.cos(half_z), x = 0, y = 0, z = math.sin(half_z))
	if real(turn) < 0 do turn = -turn
	half_angle := math.acos(clamp(real(turn), -1, 1))
	sine := math.sin(half_angle)
	if sine < AXIS_SINE_MIN do return {}
	axis := [3]f32{imag(turn), jmag(turn), kmag(turn)} / sine
	axis_turn.x = math.asin(clamp(-axis.y, -1, 1))
	axis_turn.y = math.atan2(axis.x, axis.z)
	axis_turn.z = 2 * half_angle
	return
}
AXIS_SINE_MIN :: 1e-5

// The record as a one-anim TK5 bank of the 23 body channels: header, channel types, one offset, then the anim with its
// numbers swapped. Channels past 23 (props) lose their scale and base pose; their stream fields follow the body's in each
// block, so the sampler never reaches them. The block offsets count from their own table, so the stream stays as it is.
@(private = "file")
little_endian_bank :: proc(record: []byte, allocator := context.allocator) -> (bank: []byte, ok: bool) {
	channels := int(tk5.be_u16(record, 2))
	anim_in := 4 + 2 * channels
	if channels < tk5.CHANNELS || anim_in + tk5.ANIM_BLOCKS > len(record) do return
	for channel in 0 ..< tk5.CHANNELS do if tk5.channel_is_rot(channel) != is_rotation(tk5.be_u16(record, 4 + 2 * channel)) do return
	anim := record[anim_in:]
	frames, positions := int(tk5.be_u16(anim, 0)), int(tk5.be_u16(anim, 4))
	pose_in := 6 + 4 * positions
	pose_end := pose_in
	for channel in 0 ..< channels do pose_end += is_rotation(tk5.be_u16(record, 4 + 2 * channel)) ? 6 : 12
	blocks := (frames + 14) >> 4
	if positions < POSITION_CHANNELS || pose_end + 4 * blocks > len(anim) do return

	header := 6 + 2 * tk5.CHANNELS  // u16 type, count, channel count, channel type[]; 23 channels need no pad
	stream := anim[pose_end:]
	bank = make([]byte, header + 4 + tk5.ANIM_BLOCKS + len(stream), allocator)
	put_u16(bank, 0, tk5.BANK_BODY)
	put_u16(bank, 2, 1)
	put_u16(bank, 4, tk5.CHANNELS)
	for channel in 0 ..< tk5.CHANNELS do put_u16(bank, 6 + 2 * channel, tk5.be_u16(record, 4 + 2 * channel))
	put_u32(bank, header, u32(header + 4))

	out := bank[header + 4:]
	put_u16(out, 0, u16(frames))
	out[2], out[3] = anim[2], anim[3]  // the shifts are bytes
	put_u16(out, 4, POSITION_CHANNELS)
	at := 6
	for scale in 0 ..< POSITION_CHANNELS do at = put_u32(out, at, tk5.be_u32(anim, 6 + 4 * scale))
	from := pose_in
	for channel in 0 ..< tk5.CHANNELS {
		width := tk5.channel_is_rot(channel) ? 2 : 4
		for _ in 0 ..< 3 {
			at = width == 2 ? put_u16(out, at, tk5.be_u16(anim, from)) : put_u32(out, at, tk5.be_u32(anim, from))
			from += width
		}
	}
	copy(out[at:], stream)
	for block in 0 ..< blocks do put_u32(out, at + 4 * block, tk5.be_u32(stream, 4 * block))
	return bank, true
}

// Channel types 4..7 are rotations (tk5decomp docs/data.md 5).
@(private = "file")
is_rotation :: proc(channel_type: u16) -> bool {return channel_type >= 4 && channel_type <= 7}

// Little endian; returns the next place.
@(private = "file")
put_u16 :: proc(bytes: []byte, at: int, value: u16) -> int {
	bytes[at], bytes[at + 1] = u8(value), u8(value >> 8)
	return at + 2
}

@(private = "file")
put_u32 :: proc(bytes: []byte, at: int, value: u32) -> int {
	put_u16(bytes, at, u16(value))
	return put_u16(bytes, at + 2, u16(value >> 16))
}
