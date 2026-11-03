// DDS textures, one mip: DXT blocks as stored, or 32-bit pixels. The importer writes them, the renderer reads them.
package dds

import "core:encoding/endian"

Format :: enum {BC1, BC2, BC3, RGBA8}

@(rodata) FOUR_CC := [Format]string{.BC1 = "DXT1", .BC2 = "DXT3", .BC3 = "DXT5", .RGBA8 = ""}

HEADER_SIZE :: 4 + 124
MAX_SIDE :: 16384

// Header fields, as offsets after the magic.
@(private = "file") FLAGS :: 4
@(private = "file") HEIGHT :: 8
@(private = "file") WIDTH :: 12
@(private = "file") PITCH :: 16
@(private = "file") MIPS :: 24
@(private = "file") PIXEL_FORMAT_SIZE :: 72
@(private = "file") PIXEL_FLAGS :: 76
@(private = "file") PIXEL_FOUR_CC :: 80
@(private = "file") PIXEL_BITS :: 84
@(private = "file") RED_MASK :: 88
@(private = "file") GREEN_MASK :: 92
@(private = "file") BLUE_MASK :: 96
@(private = "file") ALPHA_MASK :: 100
@(private = "file") CAPS :: 104
@(private = "file") FOUR_CC_FLAG :: 0x4

Image :: struct {
	format:        Format,
	width, height: int,
	data:          []byte,  // the top mip, in place
	bgra:          bool,    // RGBA8 with red and blue swapped
}

mip_size :: proc(format: Format, width, height: int) -> int {
	blocks := max(1, (width + 3) / 4) * max(1, (height + 3) / 4)
	switch format {
	case .BC1: return blocks * 8
	case .BC2, .BC3: return blocks * 16
	case .RGBA8: return width * height * 4
	}
	return 0
}

encode :: proc(format: Format, width, height: int, data: []byte, allocator := context.allocator) -> []byte {
	size := mip_size(format, width, height)
	out := make([]byte, HEADER_SIZE + size, allocator)
	put :: proc(out: []byte, offset: int, v: u32) {endian.put_u32(out[4 + offset:], .Little, v)}
	copy(out, "DDS ")
	put(out, 0, 124)
	put(out, FLAGS, format == .RGBA8 ? 0x100f : 0x81007)  // caps, height, width, pixel format; pitch or linear size
	put(out, HEIGHT, u32(height))
	put(out, WIDTH, u32(width))
	put(out, PITCH, format == .RGBA8 ? u32(width * 4) : u32(size))
	put(out, MIPS, 1)
	put(out, PIXEL_FORMAT_SIZE, 32)
	switch format {
	case .BC1, .BC2, .BC3:
		put(out, PIXEL_FLAGS, FOUR_CC_FLAG)
		copy(out[4 + PIXEL_FOUR_CC:], FOUR_CC[format])
	case .RGBA8:
		put(out, PIXEL_FLAGS, 0x41)  // rgb, alpha
		put(out, PIXEL_BITS, 32)
		put(out, RED_MASK, 0x000000ff)
		put(out, GREEN_MASK, 0x0000ff00)
		put(out, BLUE_MASK, 0x00ff0000)
		put(out, ALPHA_MASK, 0xff000000)
	}
	put(out, CAPS, 0x1000)  // texture
	copy(out[HEADER_SIZE:], data[:size])
	return out
}

// The top mip of DXT1, DXT3 or DXT5 blocks, or 32-bit RGBA or BGRA pixels.
read :: proc(data: []byte) -> (image: Image, ok: bool) {
	if len(data) < HEADER_SIZE || string(data[:4]) != "DDS " do return
	field :: proc(data: []byte, offset: int) -> int {
		v, _ := endian.get_u32(data[4 + offset:], .Little)
		return int(v)
	}
	image.height, image.width = field(data, HEIGHT), field(data, WIDTH)
	if image.width == 0 || image.height == 0 || image.width > MAX_SIDE || image.height > MAX_SIDE do return
	if field(data, PIXEL_FLAGS) & FOUR_CC_FLAG != 0 {
		switch string(data[4 + PIXEL_FOUR_CC:][:4]) {
		case "DXT1": image.format = .BC1
		case "DXT3": image.format = .BC2
		case "DXT5": image.format = .BC3
		case: return
		}
	} else {
		red, blue := field(data, RED_MASK), field(data, BLUE_MASK)
		rgba, bgra := red == 0xff && blue == 0xff0000, red == 0xff0000 && blue == 0xff
		if field(data, PIXEL_BITS) != 32 || !(rgba || bgra) do return
		image.format, image.bgra = .RGBA8, bgra
	}
	size := mip_size(image.format, image.width, image.height)
	if len(data) - HEADER_SIZE < size do return
	image.data = data[HEADER_SIZE:][:size]
	return image, true
}
