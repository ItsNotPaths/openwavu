// Sound packs (tk5decomp docs/data.md §8): records of PS ADPCM sounds, or one ATRAC3plus music track in a RIFF.
// Big endian. The music tables are in the EBOOT.
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

Sound_Codec :: enum u32 {
	PS_ADPCM    = 2,
	ATRAC3_PLUS = 3,
}

// loop_start, loop_length: PS ADPCM bytes, ATRAC3plus samples.
Sound_Record :: struct {
	index:                   int,
	codec:                   Sound_Codec,
	data:                    []byte,
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
