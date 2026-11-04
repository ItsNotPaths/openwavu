// EBOOT addresses: ELF64 big endian program headers map a vaddr to a file offset.
package tk5_formats

import "core:encoding/endian"

@(private = "file")
PT_LOAD :: 1

elf_offset :: proc(elf: []byte, vaddr: u64) -> (offset: int, ok: bool) {
	if len(elf) < 0x40 do return
	be_u64 :: proc(b: []byte, off: int) -> u64 {v, _ := endian.get_u64(b[off:], .Big); return v}
	headers, size, count := int(be_u64(elf, 0x20)), int(be_u16(elf, 0x36)), int(be_u16(elf, 0x38))
	if headers + size * count > len(elf) do return
	for i in 0 ..< count {
		h := elf[headers + size * i:]
		if be_u32(h, 0) != PT_LOAD do continue
		start, file_size := be_u64(h, 0x10), be_u64(h, 0x20)
		if vaddr >= start && vaddr < start + file_size do return int(be_u64(h, 0x08) + vaddr - start), true
	}
	return
}
