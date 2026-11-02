#+build !windows
package game

// Filesystem roots: just "/".
roots :: proc(allocator := context.allocator) -> []string {
	return slice_of("/", allocator)
}

@(private = "file")
slice_of :: proc(s: string, allocator := context.allocator) -> []string {
	out := make([]string, 1, allocator)
	out[0] = s
	return out
}
