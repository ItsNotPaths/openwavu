// Sound: PAC files of nub banks (each a TK5 sound pack), and the EBOOT tables that name every record, number it for
// moves and voices, and list each voice character's voices. The tables are found by their shape, not their address.
// tk6decomp docs/data.md "Sound", tools/pacdir.py, tools/soundmap.py.
package tk6_formats

import "core:strings"
import tk5 "../tk5"

SOUND_EFFECTS_PAC :: 2021  // se_*.nub
MUSIC_PAC :: 148112        // rm_*.nub in stereo; 148114 holds 5.1 copies of the menu and stage music
PAC_HEADER_SIZE :: 0x10
@(rodata) PAC_KEY := [4]u8{0xff, 0xf0, 0x00, 0xff}  // the directory is XOR'd with it by byte position

// Bank kinds in the EBOOT's bank table.
BANK_VOICES :: 0         // a character's voices; owner: its file number
BANK_STAGE :: 1          // owner: stage number
BANK_STAGE_EFFECTS :: 7  // owner: stage number
BANK_STAGE_MUSIC :: 11   // owner: stage number
BANK_INTRO_LINES :: 12   // owner: character file number
BANK_WIN_LINES :: 14     // owner: character file number
CAMPAIGN_STAGE_FIRST :: 40  // stage numbers of the scenario campaign

VOICE_CHARACTERS :: 52  // voice character = the character's file number
VOICE_ROW_SIZE :: 0x10

Pac_Entry :: struct {
	name:         string,  // "se_Chr_kaz.nub"
	offset, size: int,     // in the PAC file
}

Sound_Bank :: struct {
	name:         string,    // the nub's name without ".nub"; this and record_names point into the ELF
	kind, owner:  int,       // owner: character file number, stage number, -1 for none
	record_names: []string,  // by record
}

// The voice table's rows (TK5's VTBL). A voice "row n of kind k" is the n-th row of its voice character with bit k
// in kinds; kind 8 takes any row.
Voice_Row :: struct {
	voice, number: int,  // number: the sound number
	face:          int,  // 0x4000 + clip: a face clip; else a face value
	kinds:         int,
}

Sound_Tables :: struct {
	banks:  []Sound_Bank,
	names:  map[int]string,  // sound number -> record name
	voices: []Voice_Row,
}

read_pac_directory :: proc(game: Game_Files, file: int, allocator := context.allocator) -> (entries: []Pac_Entry, ok: bool) {
	head := read_file(game, file, PAC_HEADER_SIZE, context.temp_allocator) or_return
	if len(head) < PAC_HEADER_SIZE || string(head[:4]) != "PAC\x01" do return
	data_start, count := int(tk5.le_u32(head, 8)), int(tk5.le_u32(head, 12))
	if data_start < PAC_HEADER_SIZE do return
	directory := read_file(game, file, data_start - PAC_HEADER_SIZE, context.temp_allocator, from = PAC_HEADER_SIZE) or_return
	for &value, at in directory do value ~= PAC_KEY[at % len(PAC_KEY)]
	entries = make([]Pac_Entry, count, allocator)
	at := 0
	for &entry in entries {
		name_start := at + 4  // after a word [open]
		name_end := name_start
		for name_end < len(directory) && directory[name_end] != 0 do name_end += 1
		at = (name_end + 4) & ~int(3)
		if at + 8 > len(directory) do return nil, false
		entry = {strings.clone(string(directory[name_start:name_end]), allocator), int(tk5.le_u32(directory, at)), int(tk5.le_u32(directory, at + 4))}
		at += 8
	}
	return entries, true
}

read_sound_tables :: proc(elf: []byte, allocator := context.allocator) -> (tables: Sound_Tables, ok: bool) {
	image := Elf_Image{elf, tk5.elf_loads(elf, context.temp_allocator) or_return}
	tables.banks = find_banks(image, allocator)
	tables.names = find_sound_names(image, allocator) or_return
	tables.voices = find_voices(image, allocator) or_return
	return tables, len(tables.banks) > 0
}

@(private = "file")
Elf_Image :: struct {
	elf:   []byte,
	loads: []tk5.Elf_Load,
}

// The big endian word at vaddr; missing outside the image.
@(private = "file")
word :: proc(image: Elf_Image, vaddr: u64, missing: u32 = 0) -> u32 {
	for load in image.loads {
		if vaddr >= load.vaddr && vaddr + 4 <= load.vaddr + u64(load.size) do return tk5.be_u32(image.elf, load.offset + int(vaddr - load.vaddr))
	}
	return missing
}

// A short printable NUL-ended string at vaddr.
@(private = "file")
text_at :: proc(image: Elf_Image, vaddr: u32) -> (text: string, ok: bool) {
	MAX_LENGTH :: 64
	for load in image.loads {
		if u64(vaddr) < load.vaddr || u64(vaddr) >= load.vaddr + u64(load.size) do continue
		start := load.offset + int(u64(vaddr) - load.vaddr)
		for at in start ..< min(start + MAX_LENGTH, len(image.elf)) {
			value := image.elf[at]
			if value == 0 do return string(image.elf[start:at]), at > start
			if value < 0x20 || value >= 0x7f do return
		}
	}
	return
}

// Rows of 6 words: name ("se_Chr_kaz"), bank id, record count, record name list, kind, owner.
@(private = "file")
find_banks :: proc(image: Elf_Image, allocator := context.allocator) -> []Sound_Bank {
	ROW_WORDS :: 6
	MAX_RECORDS :: 0x400
	banks := make([dynamic]Sound_Bank, allocator)
	for load in image.loads {
		for vaddr := load.vaddr; vaddr + 4 * ROW_WORDS <= load.vaddr + u64(load.size); vaddr += 4 {
			words: [ROW_WORDS]u32
			for &value, k in words do value = word(image, vaddr + u64(4 * k))
			name := text_at(image, words[0]) or_continue
			if !strings.has_prefix(name, "se_") && !strings.has_prefix(name, "rm_") || strings.contains(name, ".") do continue
			count := int(words[2])
			if count == 0 || count >= MAX_RECORDS do continue
			if _, named := text_at(image, word(image, u64(words[3]))); !named do continue
			record_names := make([]string, count, allocator)
			for &record_name, record in record_names do record_name = text_at(image, word(image, u64(words[3]) + u64(4 * record))) or_else ""
			append(&banks, Sound_Bank{name, int(words[4]), int(i32(words[5])), record_names})
		}
	}
	return banks[:]
}

// Number n -> handle: 8-byte rows {n, handle}, row 0 = {-1, -1}. Handle -> name: 0x18-byte rows, the name first.
@(private = "file")
find_sound_names :: proc(image: Elf_Image, allocator := context.allocator) -> (names: map[int]string, ok: bool) {
	numbers := find_table(image, 8, starts_numbers)
	handles := find_table(image, HANDLE_ROW, starts_handles)
	if numbers == 0 || handles == 0 do return
	names = make(map[int]string, allocator)
	for number := 1; word(image, numbers + u64(8 * number)) == u32(number); number += 1 {
		handle := word(image, numbers + u64(8 * number) + 4, NONE)
		if handle == NONE do continue
		if name, named := text_at(image, word(image, handles + u64(HANDLE_ROW) * u64(handle))); named do names[number] = name
	}
	return names, true
}

@(private = "file")
NONE :: 0xffffffff
@(private = "file")
HANDLE_ROW :: 0x18

@(private = "file")
starts_numbers :: proc(image: Elf_Image, table: u64) -> bool {
	return word(image, table) == NONE && word(image, table + 4) == NONE && word(image, table + 8) == 1 && word(image, table + 0x10) == 2 && word(image, table + 0x18) == 3
}

// Past its name a handle row holds {0, -1, -1, 0, -1} until the game fills it.
@(private = "file")
is_handle_row :: proc(image: Elf_Image, row: u64) -> bool {
	_, named := text_at(image, word(image, row))
	return named && word(image, row + 4, 1) == 0 && word(image, row + 8) == NONE && word(image, row + 0xc) == NONE &&
		word(image, row + 0x10, 1) == 0 && word(image, row + 0x14) == NONE
}

@(private = "file")
starts_handles :: proc(image: Elf_Image, table: u64) -> bool {
	return is_handle_row(image, table) && is_handle_row(image, table + HANDLE_ROW) && !is_handle_row(image, table - HANDLE_ROW)
}

// VOICE_CHARACTERS rows of 3 words {row list, row count, voice character}; each row {voice character, sound number,
// face, u16 kinds, u16 0}.
@(private = "file")
find_voices :: proc(image: Elf_Image, allocator := context.allocator) -> (voices: []Voice_Row, ok: bool) {
	table := find_table(image, VOICE_CHARACTER_ROW * VOICE_CHARACTERS, starts_voices)
	if table == 0 do return
	list := make([dynamic]Voice_Row, allocator)
	for voice in 0 ..< VOICE_CHARACTERS {
		character_row := table + u64(VOICE_CHARACTER_ROW * voice)
		rows, count := u64(word(image, character_row)), int(word(image, character_row + 4))
		for index in 0 ..< count {
			row := rows + u64(VOICE_ROW_SIZE * index)
			append(&list, Voice_Row{voice, int(word(image, row + 4)), int(word(image, row + 8)), int(word(image, row + 0xc) >> 16)})
		}
	}
	return list[:], true
}

@(private = "file")
VOICE_CHARACTER_ROW :: 12

@(private = "file")
starts_voices :: proc(image: Elf_Image, table: u64) -> bool {
	MAX_ROWS :: 64
	for voice in 0 ..< VOICE_CHARACTERS {
		row := table + u64(VOICE_CHARACTER_ROW * voice)
		count := word(image, row + 4, MAX_ROWS)
		if word(image, row + 8, NONE) != u32(voice) || count >= MAX_ROWS do return false
		if count > 0 && word(image, u64(word(image, row)), NONE) != u32(voice) do return false
	}
	return true
}

// The first vaddr where starts holds and `size` bytes fit; 0 for none.
@(private = "file")
find_table :: proc(image: Elf_Image, size: int, starts: proc(image: Elf_Image, table: u64) -> bool) -> u64 {
	for load in image.loads {
		for vaddr := load.vaddr; vaddr + u64(size) <= load.vaddr + u64(load.size); vaddr += 4 {
			if starts(image, vaddr) do return vaddr
		}
	}
	return 0
}

delete_pac_directory :: proc(entries: []Pac_Entry) {
	for entry in entries do delete(entry.name)
	delete(entries)
}

delete_sound_tables :: proc(tables: Sound_Tables) {
	for bank in tables.banks do delete(bank.record_names)
	delete(tables.banks)
	delete(tables.names)
	delete(tables.voices)
}
