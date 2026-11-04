// The throw camera table (tk5decomp docs/camera.md 4.2): per camera category, records picked by weight.
package tk5_formats

THROW_CAMERA_RECORD :: 8
CODED_CAMERAS :: 0x67  // ids below are hand-coded shots; the rest are global bank clip id - 0x67

Throw_Camera :: struct {
	category, weight: int,
	flags:            u16,
	left, right:      u16,  // camera id with the thrower on the left / right of the screen
}

read_throw_cameras :: proc(eboot: []byte, build: Build, allocator := context.allocator) -> (records: []Throw_Camera, ok: bool) {
	table := elf_offset(eboot, build.throw_camera_table) or_return
	if table + 8 * build.throw_camera_categories > len(eboot) do return
	list := make([dynamic]Throw_Camera, allocator)
	for category in 0 ..< build.throw_camera_categories {
		pointer, count := be_u32(eboot, table + 8 * category), int(be_i32(eboot, table + 8 * category + 4))
		if count <= 0 do continue
		first, mapped := elf_offset(eboot, u64(pointer))
		if !mapped || first + THROW_CAMERA_RECORD * count > len(eboot) {
			delete(list)
			return
		}
		for k in 0 ..< count {
			r := eboot[first + THROW_CAMERA_RECORD * k:]
			append(&list, Throw_Camera{category, int(be_u16(r, 2)), be_u16(r, 0), be_u16(r, 4), be_u16(r, 6)})
		}
	}
	return list[:], true
}
