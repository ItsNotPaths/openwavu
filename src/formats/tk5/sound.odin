// Sound packs (tk5decomp docs/data.md §8): records of PS ADPCM sounds, or one ATRAC3plus music track in a RIFF.
// Big endian. The music tables and the sound id tables of the sim's cues (§8.4) are in the EBOOT.
package tk5_formats

SOUND_PACK_MAGIC :: 0x00020100
SOUND_RECORD_SIZE :: 0xc0

// Shared banks by entry; a costume's are in its group, a stage's at SOUND_STAGE_FIRST + 3 * stage.
SOUND_MENU :: 10
SOUND_ROUND_CALLS :: 11
SOUND_COMMON :: 12
SOUND_NAMES :: 206  // the announcer's character names
SOUND_STAGE_FIRST :: 2131
GROUP_STREAM_VOICES :: 4  // intro and win lines
GROUP_VOICES :: 5

STAGE_RECORD_SIZE :: 16
STAGE_RECORD_MUSIC :: 0xc

VOICE_TABLE :: 9  // entry of the voice table (VTBL)
COSTUME_FIRST :: 1528  // group of costume 0; costume n is GROUP_SIZE groups on
COSTUME_RECORD_SIZE :: 0x24
COSTUME_RECORD_VOICE :: 4
VOICE_CHARACTERS :: 36
SPECIAL_SOUNDS :: 17

Sound_Codec :: enum u32 {
	PS_ADPCM    = 2,
	ATRAC3_PLUS = 3,
}

// loop_start, loop_length: PS ADPCM bytes, ATRAC3plus samples. Records may share data (the same sample at another
// pitch, pan or volume): data_offset tells them apart.
Sound_Record :: struct {
	index:                   int,
	codec:                   Sound_Codec,
	data:                    []byte,
	data_offset:             int,
	looped:                  bool,
	loop_start, loop_length: int,
	volume:                  f32,  // dB
	pitch:                   int,  // cents
	pan:                     f32,  // degrees
	rate:                    int,  // PS ADPCM only
}

read_sound_pack :: proc(pack: []byte, allocator := context.allocator) -> (records: []Sound_Record, ok: bool) {
	if len(pack) < 0x20 || be_u32(pack, 0) != SOUND_PACK_MAGIC do return
	count, data_start, list := int(be_u32(pack, 0x0c)), int(be_u32(pack, 0x10)), int(be_u32(pack, 0x18))
	if list + 4 * count > len(pack) do return
	records = make([]Sound_Record, count, allocator)
	for &record, k in records {
		at := int(be_u32(pack, list + 4 * k))
		if at + SOUND_RECORD_SIZE > len(pack) do return nil, false
		start, size := data_start + int(be_u32(pack, at + 0x18)), int(be_u32(pack, at + 0x14))
		if start + size > len(pack) do return nil, false
		record = {
			index       = int(be_u32(pack, at + 0x08)),
			codec       = Sound_Codec(be_u32(pack, at + 0x0c)),
			data        = pack[start:][:size],
			data_offset = start,
			loop_start  = int(be_u32(pack, at + 0x20)),
			loop_length = int(be_u32(pack, at + 0x24)),
			looped      = be_u32(pack, at + 0x28) == 1,
			volume      = be_f32(pack, at + 0x34),
			pitch       = int(be_i32(pack, at + 0x3c)),
			pan         = be_f32(pack, at + 0x40),
			rate        = int(be_u32(pack, at + 0xbc)),
		}
	}
	return records, true
}

// The parts of a music track's RIFF the decoder needs. Decoded, skip samples of delay come first, then frames samples.
// The record's loop counts from the first decoded sample.
Riff :: struct {
	channels, rate, block_align: int,
	frames, skip:                int,
	data:                        []byte,
}

read_riff :: proc(file: []byte) -> (riff: Riff, ok: bool) {
	if len(file) < 12 || string(file[:4]) != "RIFF" || string(file[8:12]) != "WAVE" do return
	found_format, found_data: bool
	for at := 12; at + 8 <= len(file); {
		id, size := string(file[at:][:4]), int(le_u32(file, at + 4))
		body := at + 8
		if body + size > len(file) do return
		switch id {
		case "fmt ":
			riff.channels, riff.rate, riff.block_align = int(le_u16(file, body + 2)), int(le_u32(file, body + 4)), int(le_u16(file, body + 12))
			found_format = true
		case "fact":  // sample count, then the delay; a 12-byte fact ends with the delay plus the decoder's
			riff.frames = int(le_u32(file, body))
			riff.skip = int(le_u32(file, body + size - 4))
		case "data":
			riff.data = file[body:][:size]
			found_data = true
		}
		at = body + size + (size & 1)
	}
	return riff, found_format && found_data && riff.block_align > 0
}

// The archive entry of every music track; tracks with the same entry share it.
read_music_tracks :: proc(eboot: []byte, build: Build, allocator := context.allocator) -> (entries: []int, ok: bool) {
	table := elf_offset(eboot, build.music_table) or_return
	if table + 4 * build.music_tracks > len(eboot) do return
	entries = make([]int, build.music_tracks, allocator)
	for &entry, track in entries do entry = int(be_i32(eboot, table + 4 * track))
	return entries, true
}

// The track each stage plays; -1 for none (a track past the table: the game fades out).
read_stage_music :: proc(eboot: []byte, build: Build, allocator := context.allocator) -> (tracks: []int, ok: bool) {
	table := elf_offset(eboot, build.stage_table) or_return
	if table + STAGE_RECORD_SIZE * STAGE_COUNT > len(eboot) do return
	tracks = make([]int, STAGE_COUNT, allocator)
	for &track, stage in tracks {
		track = int(be_i32(eboot, table + STAGE_RECORD_SIZE * stage + STAGE_RECORD_MUSIC))
		if track < 0 || track >= build.music_tracks do track = -1
	}
	return tracks, true
}

// A row of the voice table. A move's voice "row n of kind k" is the n-th row of its voice character with bit k in kinds.
Voice_Row :: struct {
	voice, index, record: int,  // index: the row's number in its voice character
	face, kinds:          int,  // face: 0x4000 + clip, another face value, or 0xffff for none
}

VOICE_HEADER :: 0x10
VOICE_ROW_SIZE :: 8
VOICE_END :: 0xff  // in the voice byte

read_voice_table :: proc(table: []byte, allocator := context.allocator) -> (rows: []Voice_Row, ok: bool) {
	if len(table) < VOICE_HEADER || string(table[:4]) != "VTBL" do return
	list := make([dynamic]Voice_Row, allocator)
	for at := VOICE_HEADER; at + VOICE_ROW_SIZE <= len(table) && table[at + 1] != VOICE_END; at += VOICE_ROW_SIZE {
		append(&list, Voice_Row{int(table[at + 1]), int(table[at]), int(be_i16(table, at + 2)), int(be_u16(table, at + 4)), int(be_u16(table, at + 6))})
	}
	return list[:], true
}

// count big endian words at vaddr, stride bytes apart.
read_words :: proc(eboot: []byte, vaddr: u64, count: int, stride := 4, allocator := context.allocator) -> (words: []int, ok: bool) {
	at := elf_offset(eboot, vaddr) or_return
	if at + stride * (count - 1) + 4 > len(eboot) do return
	words = make([]int, count, allocator)
	for &word, k in words do word = int(be_i32(eboot, at + stride * k))
	return words, true
}

// The voice character of the costume in this group.
read_costume_voice :: proc(eboot: []byte, build: Build, group: int) -> (voice: int, ok: bool) {
	costume := u64((group - COSTUME_FIRST) / GROUP_SIZE)
	words := read_words(eboot, build.costume_table + COSTUME_RECORD_SIZE * costume + COSTUME_RECORD_VOICE, 1, allocator = context.temp_allocator) or_return
	return words[0], true
}

// Each stage's record per stage sound number (from 1); -1: no sound.
read_stage_sounds :: proc(eboot: []byte, build: Build, allocator := context.allocator) -> (lists: [][]int, ok: bool) {
	lists = make([][]int, STAGE_COUNT, allocator)
	for &list, stage in lists {
		place := read_words(eboot, build.stage_sounds + u64(8 * stage), 2, allocator = context.temp_allocator) or_return
		if place[1] > 0 do list = read_words(eboot, u64(u32(place[0])), place[1], allocator = allocator) or_return
	}
	return lists, true
}
