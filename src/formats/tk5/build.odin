// Values that differ per game build. Add a row for each dump that is checked.
package tk5_formats

Build :: struct {
	title_id:     string,
	elf_sha256:   string,  // decrypted EBOOT; a game update changes it
	table_offset: int,  // EBOOT file offset of the file table
	table_count:  int,
}

BUILDS :: [?]Build{
	{  // vaddr 0x10043940
		title_id     = "NPUB30009",
		elf_sha256   = "6760ad3fb730deb1245d6b4cf293a34159500508b66e843cd62ae9cebfe0c155",
		table_offset = 0x3b3940,
		table_count  = 2297,
	},
}

find_build :: proc(title_id: string) -> (Build, bool) {
	for b in BUILDS {
		if b.title_id == title_id do return b, true
	}
	return {}, false
}
