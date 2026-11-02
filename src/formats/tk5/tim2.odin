// TIM2, the PS2 texture format, little endian. The PS2-size menu art uses it.
package tk5_formats

Picture :: struct {
	width, height: int,
	rgba:          []byte,
}

// Every picture as RGBA8. Alpha is PS2 style (0x80 = opaque) and is doubled.
read_tim2 :: proc(d: []byte, allocator := context.allocator) -> (pictures: []Picture, ok: bool) {
	if len(d) < 0x10 || string(d[:4]) != "TIM2" do return nil, false
	pictures = make([]Picture, le_u16(d, 6), allocator)
	p := d[5] == 1 ? 0x80 : 0x10  // header aligned to 128 bytes, or 16
	for &picture in pictures {
		if p + 0x30 > len(d) do return nil, false
		total, clut_size, image_size, header_size := int(le_u32(d, p)), int(le_u32(d, p + 4)), int(le_u32(d, p + 8)), int(le_u16(d, p + 0x0c))
		colors, clut_type, image_type := int(le_u16(d, p + 0x0e)), d[p + 0x12], d[p + 0x13]
		w, h := int(le_u16(d, p + 0x14)), int(le_u16(d, p + 0x16))
		if p + header_size + image_size + clut_size > len(d) do return nil, false
		pixels := d[p + header_size:][:image_size]
		clut := d[p + header_size + image_size:][:clut_size]
		rgba := make([]byte, w * h * 4, allocator)
		switch image_type {
		case 4, 5:
			color_bytes := int(clut_type & 3) == 3 ? 4 : 2
			if colors * color_bytes > len(clut) || image_size * (image_type == 4 ? 2 : 1) < w * h do return nil, false
			swizzled := image_type == 5 && clut_type & 0x80 == 0 && colors == 256
			for i in 0 ..< w * h {
				index := image_type == 4 ? int(pixels[i / 2] >> uint(4 * (i % 2)) & 0xf) : int(pixels[i])
				if swizzled do index = (index & ~int(0x18)) | (index & 0x08) << 1 | (index & 0x10) >> 1  // CSM1: bits 3 and 4 swap
				if index < colors do color(clut, index, color_bytes, rgba[4 * i:][:4])
			}
		case 1, 2, 3:
			color_bytes := int(image_type) + 1  // 1: 16-bit, 2: 24-bit, 3: 32-bit
			if image_size < w * h * color_bytes do return nil, false
			for i in 0 ..< w * h do color(pixels, i, color_bytes, rgba[4 * i:][:4])
		case: return nil, false
		}
		picture = {w, h, rgba}
		p += total
	}
	return pictures, true
}

@(private = "file")
color :: proc(src: []byte, index, size: int, out: []byte) {
	switch size {
	case 2:
		v := le_u16(src, 2 * index)  // A1 B5 G5 R5
		out[0], out[1], out[2] = u8(v & 31) << 3, u8(v >> 5 & 31) << 3, u8(v >> 10 & 31) << 3
		out[3] = v >> 15 != 0 ? 255 : 0
	case 3:
		copy(out, src[3 * index:][:3])
		out[3] = 255
	case 4:
		copy(out, src[4 * index:][:4])
		out[3] = u8(min(int(out[3]) * 2, 255))
	}
}
