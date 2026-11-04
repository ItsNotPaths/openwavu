// .anim: decoded animation channels, the same for every game. Values are what the game decodes,
// bit for bit; the channel table says what each channel is. Little endian:
//   "OWAN", u32 version, char[8] layout, u32 frames, u32 fps, f32 metres per position unit, u32 channels
//   per channel: u8 kind, u8 components, i16 bone (-1: none)
//   f32 values[frames][channels][components]
// The layout ("tk5", ...) names the game rules that combine channels into a pose.
package convert

import "core:bytes"
import "core:encoding/endian"
import "core:os"
import "core:slice"
import "core:strings"

ANIM_VERSION :: 2

Anim_Channel_Kind :: enum u8 {
	Position             = 1,  // xyz
	Quaternion           = 2,  // xyzw
	Spherical_Axis_Angle = 3,  // axis pitch, axis yaw, angle (radians)
	Scalar               = 4,  // one value; the layout says what it is
}

Anim_Channel :: struct {
	kind:       Anim_Channel_Kind,
	components: u8,
	bone:       i16,
}

Anim :: struct {
	layout:        string,
	frames, fps:   int,
	position_unit: f32,  // metres per unit
	channels:      []Anim_Channel,
	values:        []f32,  // [frames][channels][components]
}

write_anim :: proc(path: string, a: Anim) -> (ok: bool) {
	out: bytes.Buffer
	bytes.buffer_init_allocator(&out, 0, 40 + 4 * len(a.channels) + 4 * len(a.values), context.temp_allocator)
	put32 :: proc(out: ^bytes.Buffer, v: u32) {
		b: [4]byte
		endian.put_u32(b[:], .Little, v)
		bytes.buffer_write(out, b[:])
	}
	layout: [8]byte
	copy(layout[:], a.layout)
	bytes.buffer_write_string(&out, "OWAN")
	put32(&out, ANIM_VERSION)
	bytes.buffer_write(&out, layout[:])
	put32(&out, u32(a.frames))
	put32(&out, u32(a.fps))
	put32(&out, transmute(u32)a.position_unit)
	put32(&out, u32(len(a.channels)))
	for c in a.channels {
		b := [4]byte{u8(c.kind), c.components, 0, 0}
		endian.put_i16(b[2:], .Little, c.bone)
		bytes.buffer_write(&out, b[:])
	}
	bytes.buffer_write(&out, slice.to_bytes(a.values))  // the host is little endian
	return os.write_entire_file(path, bytes.buffer_to_bytes(&out)) == nil
}

// Values and channels point into `data`.
read_anim :: proc(data: []byte, allocator := context.allocator) -> (a: Anim, ok: bool) {
	if len(data) < 36 || string(data[:4]) != "OWAN" do return {}, false
	le32 :: proc(b: []byte, off: int) -> u32 {v, _ := endian.get_u32(b[off:], .Little); return v}
	if le32(data, 4) != ANIM_VERSION do return {}, false
	a.layout = strings.truncate_to_byte(string(data[8:16]), 0)
	a.frames, a.fps = int(le32(data, 16)), int(le32(data, 20))
	a.position_unit = transmute(f32)le32(data, 24)
	count := int(le32(data, 28))
	if 32 + 4 * count > len(data) do return {}, false
	a.channels = make([]Anim_Channel, count, allocator)
	width := 0
	for &c, i in a.channels {
		b := data[32 + 4 * i:]
		bone, _ := endian.get_i16(b[2:], .Little)
		c = {Anim_Channel_Kind(b[0]), b[1], bone}
		width += int(c.components)
	}
	start := 32 + 4 * count
	if start + 4 * a.frames * width != len(data) do return {}, false
	a.values = slice.reinterpret([]f32, data[start:])
	return a, true
}
