// NFH: the glyph table of one font page, LE. Header: line height at 0x04, glyph count at 0x08, the rest
// is font tool leftovers. 0x50: 256 hash buckets (not needed). 0x450: 32-byte records, sorted by code.
package tk5_formats

NFH_RECORDS :: 0x450

Glyph :: struct {
	code:                rune,
	x, y, width, height: int,  // box on the page
	x_offset, y_offset:  f64,  // pen to the box's left edge, line top to its top
	advance:             f64,
}

read_nfh :: proc(d: []byte, allocator := context.allocator) -> (line_height: int, glyphs: []Glyph, ok: bool) {
	if len(d) < NFH_RECORDS || string(d[:4]) != "NFH\x00" do return 0, nil, false
	count := int(le_u32(d, 8))
	if NFH_RECORDS + count * 32 > len(d) do return 0, nil, false
	glyphs = make([]Glyph, count, allocator)
	for &g, i in glyphs {
		r := NFH_RECORDS + i * 32
		bearing := f64(le_i16(d, r + 8)) / 64  // metrics in 1/64 px
		g = {
			code     = rune(be_u16(d, r + 0x16)),
			x        = int(le_u16(d, r + 4)),
			y        = int(le_u16(d, r + 6)),
			width    = int(d[r + 0x14]),
			height   = int(d[r + 0x15]),
			x_offset = bearing,
			y_offset = -f64(le_i16(d, r + 0x0a)) / 64,
			advance  = bearing + f64(le_i16(d, r + 0x0c)) / 64,  // the stored step starts at the bearing; space has a negative one
		}
	}
	return int(le_u32(d, 4)), glyphs, true
}
