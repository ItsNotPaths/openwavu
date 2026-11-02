package convert

import "core:encoding/endian"

Dds_Format :: enum {BC1, BC2, BC3, RGBA8}

@(rodata) FOUR_CC := [Dds_Format]string{.BC1 = "DXT1", .BC2 = "DXT3", .BC3 = "DXT5", .RGBA8 = ""}

DDS_HEADER_SIZE :: 4 + 124

// One mip: block-compressed data as is, or RGBA8 rows.
encode_dds :: proc(format: Dds_Format, width, height: int, data: []byte, allocator := context.allocator) -> []byte {
	size: int
	switch format {
	case .BC1: size = max(1, (width + 3) / 4) * max(1, (height + 3) / 4) * 8
	case .BC2, .BC3: size = max(1, (width + 3) / 4) * max(1, (height + 3) / 4) * 16
	case .RGBA8: size = width * height * 4
	}
	out := make([]byte, DDS_HEADER_SIZE + size, allocator)
	put :: proc(out: []byte, offset: int, v: u32) {endian.put_u32(out[4 + offset:], .Little, v)}  // header offsets after the magic
	copy(out, "DDS ")
	put(out, 0, 124)
	put(out, 4, format == .RGBA8 ? 0x100f : 0x81007)  // caps, height, width, pixel format; pitch or linear size
	put(out, 8, u32(height))
	put(out, 12, u32(width))
	put(out, 16, format == .RGBA8 ? u32(width * 4) : u32(size))
	put(out, 24, 1)  // mips
	put(out, 72, 32)  // pixel format
	switch format {
	case .BC1, .BC2, .BC3:
		put(out, 76, 0x4)  // four cc
		copy(out[4 + 80:], FOUR_CC[format])
	case .RGBA8:
		put(out, 76, 0x41)  // rgb, alpha
		put(out, 84, 32)
		put(out, 88, 0x000000ff)
		put(out, 92, 0x0000ff00)
		put(out, 96, 0x00ff0000)
		put(out, 100, 0xff000000)
	}
	put(out, 104, 0x1000)  // texture
	copy(out[DDS_HEADER_SIZE:], data[:size])
	return out
}
