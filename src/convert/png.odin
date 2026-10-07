package convert

import "core:encoding/endian"
import "core:hash"
import "vendor:zlib"

// RGBA8 -> PNG bytes. Deterministic: same pixels, same bytes.
encode_png :: proc(rgba: []byte, width, height: int, allocator := context.allocator) -> []byte {
	rows := make([]byte, (width * 4 + 1) * height, context.temp_allocator)  // filter byte 0 per row
	for y in 0 ..< height do copy(rows[y * (width * 4 + 1) + 1:], rgba[y * width * 4:][:width * 4])
	packed_len := zlib.compressBound(zlib.uLong(len(rows)))
	packed := make([]byte, packed_len, context.temp_allocator)
	zlib.compress2(raw_data(packed), &packed_len, raw_data(rows), zlib.uLong(len(rows)), 6)

	out := make([dynamic]byte, allocator)
	append(&out, "\x89PNG\r\n\x1a\n")
	ihdr: [13]byte
	endian.put_u32(ihdr[0:], .Big, u32(width))
	endian.put_u32(ihdr[4:], .Big, u32(height))
	ihdr[8], ihdr[9] = 8, 6  // 8-bit RGBA
	chunk(&out, "IHDR", ihdr[:])
	chunk(&out, "IDAT", packed[:packed_len])
	chunk(&out, "IEND", nil)
	return out[:]
}

@(private)
chunk :: proc(out: ^[dynamic]byte, type: string, data: []byte) {
	n: [4]byte
	endian.put_u32(n[:], .Big, u32(len(data)))
	append(out, ..n[:])
	start := len(out)
	append(out, type)
	append(out, ..data)
	endian.put_u32(n[:], .Big, hash.crc32(out[start:]))
	append(out, ..n[:])
}
