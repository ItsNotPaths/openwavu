package tests

import "core:bytes"
import "core:encoding/endian"
import "core:testing"
import "../src/dds"

// DXT blocks go in as stored, behind a header any DDS reader takes: size, four cc, linear size; reading gives them
// back, and a file cut short does not read.
@(test)
dds_keeps_blocks :: proc(t: ^testing.T) {
	blocks := make([]byte, 2 * 1 * 16, context.temp_allocator)  // 8x4 texels of DXT5
	for &b, i in blocks do b = u8(i)
	data := dds.encode(.BC3, 8, 4, blocks, context.temp_allocator)
	u32_at :: proc(d: []byte, offset: int) -> u32 {v, _ := endian.get_u32(d[offset:], .Little); return v}
	testing.expect_value(t, string(data[:4]), "DDS ")
	testing.expect_value(t, u32_at(data, 12), 4)  // height
	testing.expect_value(t, u32_at(data, 16), 8)  // width
	testing.expect_value(t, u32_at(data, 20), 32)  // linear size
	testing.expect_value(t, string(data[84:][:4]), "DXT5")
	testing.expect(t, bytes.equal(data[128:], blocks), "DDS blocks differ")

	image, ok := dds.read(data)
	testing.expect(t, ok)
	testing.expect_value(t, image.format, dds.Format.BC3)
	testing.expect_value(t, image.width, 8)
	testing.expect_value(t, image.height, 4)
	testing.expect(t, bytes.equal(image.data, blocks), "read blocks differ")
	_, ok = dds.read(data[:len(data) - 1])
	testing.expect(t, !ok)
}

// RGBA8 pixels read back as written, not swapped.
@(test)
dds_keeps_rgba_pixels :: proc(t: ^testing.T) {
	pixels := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	image, ok := dds.read(dds.encode(.RGBA8, 2, 1, pixels, context.temp_allocator))
	testing.expect(t, ok)
	testing.expect(t, !image.bgra)
	testing.expect(t, bytes.equal(image.data, pixels), "read pixels differ")
}
