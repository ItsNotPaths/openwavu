// EBOOT addresses: ELF64 big endian program headers map a vaddr to a file offset.
package tk5_formats

import "core:encoding/endian"

@(private = "file")
PT_LOAD :: 1

// A loaded segment's bytes in the file.
Elf_Load :: struct {
	vaddr:        u64,
	offset, size: int,
}

elf_loads :: proc(elf: []byte, allocator := context.allocator) -> (loads: []Elf_Load, ok: bool) {
	if len(elf) < 0x40 do return
	be_u64 :: proc(b: []byte, off: int) -> u64 {v, _ := endian.get_u64(b[off:], .Big); return v}
	headers, size, count := int(be_u64(elf, 0x20)), int(be_u16(elf, 0x36)), int(be_u16(elf, 0x38))
	if headers + size * count > len(elf) do return
	list := make([dynamic]Elf_Load, allocator)
	for i in 0 ..< count {
		h := elf[headers + size * i:]
		load := Elf_Load{be_u64(h, 0x10), int(be_u64(h, 0x08)), int(be_u64(h, 0x20))}
		if be_u32(h, 0) == PT_LOAD && load.size > 0 && load.offset + load.size <= len(elf) do append(&list, load)
	}
	return list[:], true
}

elf_offset :: proc(elf: []byte, vaddr: u64) -> (offset: int, ok: bool) {
	loads := elf_loads(elf, context.temp_allocator) or_return
	for load in loads {
		if vaddr >= load.vaddr && vaddr < load.vaddr + u64(load.size) do return load.offset + int(vaddr - load.vaddr), true
	}
	return
}
