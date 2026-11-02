package tests

import "core:encoding/endian"
import "core:testing"
import formats "../src/formats/tk5"

// Text lays out left to right: the stored step counts from the bearing, so a space whose step is
// negative (the small TK5 fonts: bearing 14, step -9) still moves the pen forward.
@(test)
nfh_space_moves_pen_forward :: proc(t: ^testing.T) {
	d := make([]byte, formats.NFH_RECORDS + 32, context.temp_allocator)
	copy(d, "NFH\x00")
	endian.put_u32(d[4:], .Little, 18)  // line height
	endian.put_u32(d[8:], .Little, 1)
	r := d[formats.NFH_RECORDS:]
	endian.put_i16(r[8:], .Little, 14 * 64)
	endian.put_i16(r[0x0a:], .Little, -19 * 64)
	endian.put_i16(r[0x0c:], .Little, -9 * 64)
	r[0x14], r[0x15], r[0x17] = 1, 1, ' '

	line_height, glyphs, ok := formats.read_nfh(d, context.temp_allocator)
	if !testing.expect(t, ok && len(glyphs) == 1) do return
	testing.expect_value(t, line_height, 18)
	testing.expect_value(t, glyphs[0].code, ' ')
	testing.expect_value(t, glyphs[0].advance, 5)
	testing.expect_value(t, glyphs[0].y_offset, 19)  // below the line top
}
