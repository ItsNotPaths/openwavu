package tk6_importer

import "core:fmt"
import "core:os"
import "core:strings"
import "../../db"
import tk5 "../../formats/tk5"
import tk6 "../../formats/tk6"
import "../../ps3"
import tk5_importer "../tk5"

// The versus banks as sounds/<bank>/<idx>.flac with their record names and sound numbers, the voice table, and each
// stage's music as music/<bank>.flac (stereo). Returns the music of each stage number (delete_stage_music). The scenario campaign's banks
// and the menu music are left out.
import_sounds :: proc(im: ^Import, usrdir: string) -> (stage_music: map[int]string) {
	defer step(im)
	self, read_error := os.read_entire_file(join(usrdir, "EBOOT.BIN"), context.allocator)
	if read_error != nil {
		fail(im, "cannot read EBOOT.BIN")
		return
	}
	defer delete(self)
	elf, decrypt_error := ps3.decrypt_self(self, nil)
	if decrypt_error != "" {
		fail(im, "EBOOT.BIN: %s", decrypt_error)
		return
	}
	defer delete(elf)
	tables, found := tk6.read_sound_tables(elf)
	if !found {
		fail(im, "the sound tables are not in EBOOT.BIN")
		return
	}
	defer tk6.delete_sound_tables(tables)

	numbers := make(map[string]int)  // record name -> sound number
	defer delete(numbers)
	for number, name in tables.names do numbers[name] = number
	banks := make(map[string]tk6.Sound_Bank)
	defer delete(banks)
	for bank in tables.banks do banks[bank.name] = bank

	stage_music = make(map[int]string)
	for pac in ([]int{tk6.SOUND_EFFECTS_PAC, tk6.MUSIC_PAC}) {
		entries, listed := tk6.read_pac_directory(im.game, pac)
		if !listed {
			fail(im, "sound file %d did not read", pac)
			continue
		}
		defer tk6.delete_pac_directory(entries)
		for entry in entries {
			defer free_all(context.temp_allocator)
			game_name := strings.trim_suffix(entry.name, ".nub")
			bank, known := banks[game_name]
			if !known do continue
			if bank.kind == tk6.BANK_STAGE_MUSIC {
				if stage_id(bank.owner) == "" do continue
				music := strings.trim_prefix(game_name, "rm_")
				if write_music(im, pac, entry, music) do stage_music[bank.owner] = strings.clone(music)
				continue
			}
			name := bank_name(bank)
			if name == "" do continue
			write_sound_bank(im, pac, entry, name, bank.record_names, &numbers)
		}
	}

	row_of_voice := 0  // the rows come grouped by voice character
	for row, index in tables.voices {
		row_of_voice = index > 0 && tables.voices[index - 1].voice == row.voice ? row_of_voice + 1 : 0
		db.insert(&im.w, "voice", i64(row.voice), i64(row_of_voice), i64(row.number), i64(row.face), i64(row.kinds))
	}
	return
}

delete_stage_music :: proc(stage_music: map[int]string) {
	for _, music in stage_music do delete(music)
	delete(stage_music)
}

// Where a game bank goes; "" for a bank versus does not use.
bank_name :: proc(bank: tk6.Sound_Bank) -> string {
	BANK_MENU_MUSIC :: 9
	BANK_CAMPAIGN :: 10
	switch bank.kind {
	case tk6.BANK_VOICES, tk6.BANK_INTRO_LINES, tk6.BANK_WIN_LINES:
		folder := bank.kind == tk6.BANK_VOICES ? "voices" : bank.kind == tk6.BANK_INTRO_LINES ? "intro_lines" : "win_lines"
		for character in tk6.CHARACTERS do if character.number == bank.owner do return fmt.tprintf("%s/%s", character.id, folder)
		return ""
	case tk6.BANK_STAGE, tk6.BANK_STAGE_EFFECTS:
		stage := stage_id(bank.owner)
		if stage == "" do return ""
		return fmt.tprintf("%s/%s", stage, bank.kind == tk6.BANK_STAGE ? "sounds" : "effects")
	case BANK_MENU_MUSIC, BANK_CAMPAIGN:
		return ""
	}
	return fmt.tprintf("shared/%s", strings.trim_prefix(bank.name, "se_"))
}

// The stage of a versus stage number; "" for a campaign stage.
stage_id :: proc(number: int) -> string {
	stages := tk6.STAGES
	return number >= 0 && number < len(stages) ? stages[number].id : ""
}

read_nub :: proc(im: ^Import, pac: int, entry: tk6.Pac_Entry) -> (records: []tk5.Sound_Record, ok: bool) {
	data := tk6.read_file(im.game, pac, entry.size, context.temp_allocator, from = entry.offset) or_return
	return tk5.read_sound_pack(data, context.temp_allocator)
}

// Records on one sample share its file, named by the first one. A sound number goes to the first record of its name.
write_sound_bank :: proc(im: ^Import, pac: int, entry: tk6.Pac_Entry, bank: string, record_names: []string, numbers: ^map[string]int) {
	records, read := read_nub(im, pac, entry)
	if !read {
		fail(im, "sound bank %s did not read", bank)
		return
	}
	if !make_dir(join(im.root, "sounds", bank)) {
		fail(im, "cannot create sounds/%s", bank)
		return
	}
	files := make(map[int]string, context.temp_allocator)  // data offset -> file
	for record in records {
		if record.codec != .PS_ADPCM && record.codec != .ATRAC3_PLUS do continue  // only shared/Aly_Fx's reverb impulse
		file, sampled := files[record.data_offset]
		if !sampled {
			file = fmt.tprintf("sounds/%s/%d.flac", bank, record.index)
			if !tk5_importer.write_sound(im.root, file, record) {
				fail(im, "sound %s did not convert", file)
				continue
			}
			files[record.data_offset] = file
		}
		loop_start, loop_length := tk5_importer.sound_loop(record)
		db.insert(&im.w, "sound", bank, i64(record.index), file, f64(record.volume), i64(record.pitch), f64(record.pan), loop_start, loop_length)
		if record.index >= len(record_names) || record_names[record.index] == "" do continue  // shared/Btl_ap 19 has no plain text name
		name := record_names[record.index]
		number: db.Value = db.Null{}
		if found, numbered := numbers[name]; numbered {
			number = i64(found)
			delete_key(numbers, name)
		}
		db.insert(&im.w, "sound_name", bank, i64(record.index), name, number)
	}
}

write_music :: proc(im: ^Import, pac: int, entry: tk6.Pac_Entry, music: string) -> bool {
	records, read := read_nub(im, pac, entry)
	if !read || len(records) != 1 {
		fail(im, "music %s did not read", music)
		return false
	}
	file := fmt.tprintf("music/%s.flac", music)
	if !tk5_importer.write_sound(im.root, file, records[0]) {
		fail(im, "music %s did not convert", music)
		return false
	}
	loop_start, loop_length := tk5_importer.sound_loop(records[0])
	db.insert(&im.w, "music", music, file, loop_start, loop_length)
	return true
}
