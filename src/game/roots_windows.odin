package game

import "core:fmt"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	GetLogicalDrives :: proc() -> u32 ---
}

// Filesystem roots: one per drive letter.
roots :: proc(allocator := context.allocator) -> []string {
	drives := make([dynamic]string, allocator)
	mask := GetLogicalDrives()
	for letter in 0 ..< u32(26) {
		if mask & (1 << letter) != 0 {
			append(&drives, fmt.aprintf("%c:\\", 'A' + rune(letter), allocator = allocator))
		}
	}
	return drives[:]
}
