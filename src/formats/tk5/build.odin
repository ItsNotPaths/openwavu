// Values that differ per game build. Add a row for each dump that is checked.
package tk5_formats

import "core:fmt"
import "core:strings"

Build :: struct {
	title_id:                string,
	version:                 string,  // PARAM.SFO VERSION
	name:                    string,  // shown when another build is given
	elf_sha256:              string,  // decrypted EBOOT; a game update changes it
	table_offset:            int,     // EBOOT file offset of the file table
	table_count:             int,
	throw_camera_table:      u64,     // vaddr of the throw camera table
	throw_camera_categories: int,
	music_table:             u64,     // vaddr: archive entry per music track
	music_tracks:            int,
	stage_table:             u64,     // vaddr: 16-byte stage records, +0xc the music track
	costume_table:           u64,     // vaddr: COSTUME_RECORD_SIZE records, +4 the voice character
	voice_names:             u64,     // vaddr: per voice character {own voice record, names record, frames before "wins", ?}
	special_sounds:          u64,     // vaddr: SPECIAL_SOUNDS rows {id, (voice character, record) x2}
	stage_sounds:            u64,     // vaddr: per stage {pointer, count} of its sound number -> record list
	layer_orders:            u64,     // vaddr: f32 draw sort value of stage layers 0..4; rows walled, infinite, stage 22
	blend_modes:             u64,     // vaddr: BLEND_MODES rows of Blend_Mode
}

BUILDS :: [?]Build{
	{  // vaddr 0x10043940
		title_id                = "NPUB30009",
		version                 = "01.01",
		name                    = "TEKKEN 5 DARK RESURRECTION, US PSN (not the ONLINE edition)",
		elf_sha256              = "6760ad3fb730deb1245d6b4cf293a34159500508b66e843cd62ae9cebfe0c155",
		table_offset            = 0x3b3940,
		table_count             = 2297,
		throw_camera_table      = 0x3513f8,
		throw_camera_categories = 253,
		music_table             = 0x1005503c,
		music_tracks            = 45,
		stage_table             = 0x351090,
		costume_table           = 0x350394,
		voice_names             = 0x10006280,
		special_sounds          = 0x10007198,
		stage_sounds            = 0x351d90,
		layer_orders            = 0x1001c684,
		blend_modes             = 0x10022e00,
	},
}

find_build :: proc(title_id, version: string) -> (Build, bool) {
	for b in BUILDS {
		if b.title_id == title_id && b.version == version do return b, true
	}
	return {}, false
}

// The builds an import accepts, one per line, for refusal messages.
wanted_builds :: proc() -> string {
	lines := make([dynamic]string, context.temp_allocator)
	for b in BUILDS do append(&lines, fmt.tprintf("  %s %s version %s", b.name, b.title_id, b.version))
	return strings.join(lines[:], "\n", context.temp_allocator)
}
