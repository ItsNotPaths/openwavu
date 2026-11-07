package titlepack

import "core:fmt"
import "core:strconv"
import "core:strings"

THUMB :: "thumb.png"  // the pack's slot art, at the root of its tar

// One pack version on a network's files host: a line of GET /store or /versions/<id> (docs/network.md),
// `id version sha256 size front_sha256 front_size thumb_sha256 thumb_size`. Hashes in hex; a pack without a thumb
// has `- 0` for it.
Listed :: struct {
	id, version:                        string,
	sha256, front_sha256, thumb_sha256: string,
	size, front_size, thumb_size:       i64,
}

listing_line :: proc(pack: Listed, allocator := context.temp_allocator) -> string {
	thumb := pack.thumb_sha256 == "" ? "-" : pack.thumb_sha256
	return fmt.aprintf("%s %s %s %d %s %d %s %d\n", pack.id, pack.version, pack.sha256, pack.size, pack.front_sha256, pack.front_size, thumb, pack.thumb_size, allocator = allocator)
}

// Lines that do not read are skipped. Strings point into text.
read_listing :: proc(text: string, allocator := context.allocator) -> []Listed {
	packs := make([dynamic]Listed, allocator)
	lines := text
	for line in strings.split_lines_iterator(&lines) {
		words := strings.fields(line, context.temp_allocator)
		if len(words) != 8 do continue
		size, size_ok := strconv.parse_i64(words[3])
		front_size, front_ok := strconv.parse_i64(words[5])
		thumb_size, thumb_ok := strconv.parse_i64(words[7])
		if !size_ok || !front_ok || !thumb_ok do continue
		thumb := words[6] == "-" ? "" : words[6]
		append(&packs, Listed{words[0], words[1], words[2], words[4], thumb, size, front_size, thumb_size})
	}
	return packs[:]
}
