package tests

import "core:encoding/endian"
import "core:testing"
import formats "../src/formats/tk5"

// PS2 8-bit pictures: a 256-colour palette is stored in CSM1 order (bits 3 and 4 of the index swapped), and alpha 0x80 is opaque.
@(test)
tim2_palette_order_and_alpha :: proc(t: ^testing.T) {
	w, h, colors := 4, 1, 256
	header :: 0x30
	d := make([]byte, 0x10 + header + w * h + colors * 4, context.temp_allocator)
	copy(d, "TIM2")
	d[4] = 4
	d[6] = 1  // pictures
	p := d[0x10:]
	endian.put_u32(p[0:], .Little, u32(len(p)))
	endian.put_u32(p[4:], .Little, u32(colors * 4))
	endian.put_u32(p[8:], .Little, u32(w * h))
	endian.put_u16(p[0x0c:], .Little, header)
	endian.put_u16(p[0x0e:], .Little, u16(colors))
	p[0x12], p[0x13] = 3, 5  // 32-bit CSM1 palette, 8-bit indices
	endian.put_u16(p[0x14:], .Little, u16(w))
	endian.put_u16(p[0x16:], .Little, u16(h))
	copy(p[header:], []byte{0, 8, 16, 24})
	clut := p[header + w * h:]
	for i in 0 ..< colors do clut[4 * i], clut[4 * i + 3] = u8(i), 0x40

	pictures, ok := formats.read_tim2(d, context.temp_allocator)
	if !testing.expect(t, ok && len(pictures) == 1) do return
	rgba := pictures[0].rgba
	testing.expect_value(t, rgba[0], 0)
	testing.expect_value(t, rgba[4], 16)  // index 8 reads palette slot 16
	testing.expect_value(t, rgba[8], 8)
	testing.expect_value(t, rgba[12], 24)
	testing.expect_value(t, rgba[3], 0x80)
}
