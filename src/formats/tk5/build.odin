// Values that differ per game build. Add a row for each dump that is checked.
// (hole other-builds :tags importer) only NPUB30009 is mapped; EU/JP builds (NPEA00019, ...) are refused.
package tk5_formats

Build :: struct {
	title_id:                string,
	elf_sha256:              string,  // decrypted EBOOT; a game update changes it
	table_offset:            int,     // EBOOT file offset of the file table
	table_count:             int,
	throw_camera_table:      u64,     // vaddr of the throw camera table
	throw_camera_categories: int,
	music_table:             u64,     // vaddr: archive entry per music track
	music_tracks:            int,
	stage_table:             u64,     // vaddr: 16-byte stage records, +0xc the music track
}

BUILDS :: [?]Build{
	{  // vaddr 0x10043940
		title_id                = "NPUB30009",
		elf_sha256              = "6760ad3fb730deb1245d6b4cf293a34159500508b66e843cd62ae9cebfe0c155",
		table_offset            = 0x3b3940,
		table_count             = 2297,
		throw_camera_table      = 0x3513f8,
		throw_camera_categories = 253,
		music_table             = 0x1005503c,
		music_tracks            = 45,
		stage_table             = 0x351090,
	},
}

find_build :: proc(title_id: string) -> (Build, bool) {
	for b in BUILDS {
		if b.title_id == title_id do return b, true
	}
	return {}, false
}
