// Where a character's files sit, and what his default costumes wear. tk6decomp docs/data.md "Character files",
// "Customize items".
package tk6_formats

import "core:slice"
import tk5 "../tk5"

Character :: struct {
	id, name: string,
	motbin:   string,  // the move set's header name
	number:   int,     // the game's character number: picks the body and part files
}

// The roster comes later; each entry needs only its number and move set name.
// (hole tk6-roster :tags (tk6 importer) :sev gap) only Kazuya; each character needs an entry here, its anim container pairing checked, the special body rows (Kuma, Yoshimitsu...) and its shop table.
CHARACTERS :: [?]Character{{"kazuya", "Kazuya Mishima", "[KAZUYA]", 15}}

COMMON_ANIMS :: 147277  // the shared MOTA bank (0x8000 anim ids)
BODY_FIRST :: 491       // body model of character n: BODY_FIRST + BODY_FILES * n
BODY_FILES :: 34
PART_FIRST :: 12509     // part slot s of character n: PART_FIRST + PART_FILES * n + PART_SLOT_FILES * s (+ 1..12 colours)
PART_FILES :: 2993
PART_SLOT_FILES :: 13
COLOUR_CHANNELS :: 3    // a part's colour files: COLOUR_FILES per channel, COLOUR_SETS NTP3 sets in each, one per colour
COLOUR_FILES :: 4
COLOUR_SETS :: 5
NO_COLOUR :: 0x0c       // a shop record's channel it leaves alone
ITEM_FILE :: 2990       // in the part files: item definitions (section 0) and the shop table (section 1)
NO_PART :: 0xffffffff
BODY_MESHES :: 0xffffffff  // an item record that names the body model's meshes
PLAYER_ONE :: 0         // default costumes: 0 = 1P, 1 = 2P, 2 and 3 extra outfits

body_file :: proc(character: Character) -> int {return BODY_FIRST + BODY_FILES * character.number}

part_file :: proc(character: Character, slot: int) -> int {
	return PART_FIRST + PART_FILES * character.number + PART_SLOT_FILES * slot
}

// The file after a part's model file and the section that hold colour `colour` of a channel.
colour_set :: proc(channel, colour: int) -> (file_after_part, section: int) {
	return 1 + COLOUR_FILES * channel + colour / COLOUR_SETS, colour % COLOUR_SETS
}

// The anim container of a move set: the k-th little endian container of the motion archive goes with its k-th move set
// [proven by data for Kazuya: his anim ids fill the container's bank exactly].
anim_container :: proc(game: Game_Files, motbin_index: int) -> (index: int, ok: bool) {
	ANIM_CONTAINER_HEAD :: "\x07\x00\x00\x00\x40\x00\x00\x00"
	archive := archive_named(game, MOTBIN_ARCHIVE) or_return
	motbins, containers: [dynamic]int
	motbins.allocator, containers.allocator = context.temp_allocator, context.temp_allocator
	for file in archive.first ..< archive.end {
		head, read := read_file(game, file, HEADER_SIZE, context.temp_allocator)
		if !read do continue
		if is_motbin(head) do append(&motbins, file)
		if string(head[:min(8, len(head))]) == ANIM_CONTAINER_HEAD do append(&containers, file)
	}
	ordinal := slice.linear_search(motbins[:], motbin_index) or_return
	if ordinal >= len(containers) do return
	return containers[ordinal], true
}

// A part the costume adds to the body model, and the body meshes it covers.
Costume_Part :: struct {
	slot:          int,
	hidden_meshes: []int,
}

// The parts a default costume (PLAYER_ONE, ...) wears on the body model, the body's texture set and the colours.
Costume :: struct {
	parts:            []Costume_Part,
	body_texture_set: int,  // MODEL_TEXTURE_SETS set; SCALP_HAIR_SET when a part wants hair painted on the scalp
	colours:          [COLOUR_CHANNELS]int,  // one palette for every part (Kazuya 1P: red gloves and footwraps)
}

// The colours: every channel any free shop record of the costume sets (no two disagree over the roster). A character
// with no shop table keeps colour 0.
// (hole tk6-body-texture-sets :tags (tk6 importer look) :sev polish) only sets 0 and 1 are picked; Jin (8 sets) and Lei (4) pair them with something unread, and Xiaoyu's hair has no scalp flag though her set 1 paints hair.
read_costume :: proc(game: Game_Files, character: Character, costume: int, allocator := context.allocator) -> (out: Costume, ok: bool) {
	data := read_file(game, PART_FIRST + PART_FILES * character.number + ITEM_FILE, allocator = context.temp_allocator) or_return
	files := sections(data, context.temp_allocator) or_return
	if len(files) < 2 do return
	definitions := read_item_definitions(files[0], context.temp_allocator) or_return
	list := make([dynamic]Costume_Part, allocator)
	for definition in definitions {
		if definition.costumes & (1 << uint(costume)) == 0 || definition.part == NO_PART do continue
		append(&list, Costume_Part{int(definition.part), slice.clone(definition.hidden_meshes, allocator)})
		if definition.scalp_hair do out.body_texture_set = SCALP_HAIR_SET
	}
	out.parts = list[:]
	records := read_shop_records(files[1], context.temp_allocator) or_else nil
	for record in records {
		if record.price != 0 || record.costume != costume do continue
		for colour, channel in record.colours do if colour != NO_COLOUR do out.colours[channel] = int(colour)
	}
	return out, true
}

// Shop table: u32 count, u32 0, then records: u16 item, u16 name length, name, u32 price, u8 costume, u8, u8 count,
// u32 list[count], u32, then a 12-byte tail: u8 kind, u8 colour[COLOUR_CHANNELS], u32 shop id, u8 category, u8, u16.
@(private = "file")
Shop_Record :: struct {
	price:   u32,
	costume: int,
	colours: [COLOUR_CHANNELS]u8,
}

SHOP_TAIL :: 12

@(private = "file")
read_shop_records :: proc(table: []byte, allocator := context.allocator) -> (records: []Shop_Record, ok: bool) {
	if len(table) < 8 do return
	records = make([]Shop_Record, tk5.be_u32(table, 0), allocator)
	at := 8
	for &record in records {
		if at + 4 > len(table) do return
		at += 4 + int(tk5.be_u16(table, at + 2))
		if at + 7 > len(table) do return
		record.price, record.costume = tk5.be_u32(table, at), int(table[at + 4])
		at += 7 + 4 * int(table[at + 6]) + 4
		if at + SHOP_TAIL > len(table) do return
		copy(record.colours[:], table[at + 1:][:COLOUR_CHANNELS])
		at += SHOP_TAIL
	}
	return records, true
}

// Definition record ("IM03"): name, then u32 words: [5] low byte the default costumes that wear it (bit n = costume n, 0 = shop only), [11] the part slot or NO_PART, [13] 1: the body
// wants hair painted on the scalp (hair parts), and lists {u32 target, u32 count, u32 0, u32 value[count]}; target
// BODY_MESHES lists body meshes the part covers.
@(private = "file")
Item_Definition :: struct {
	costumes:      u8,
	part:          u32,
	scalp_hair:    bool,
	hidden_meshes: []int,
}

DEFINITION_WORDS :: 0x3c
DEFINITION_LISTS :: DEFINITION_WORDS + 4 * 14
HIDDEN_LIST_MAX :: 64

@(private = "file")
read_item_definitions :: proc(table: []byte, allocator := context.allocator) -> (definitions: []Item_Definition, ok: bool) {
	if len(table) < 4 do return
	count := int(tk5.be_u32(table, 0))
	if 4 + 8 * count > len(table) do return
	definitions = make([]Item_Definition, count, allocator)
	for &definition, index in definitions {
		offset, size := int(tk5.be_u32(table, 4 + 8 * index)), int(tk5.be_u32(table, 8 + 8 * index))
		if offset + size > len(table) do return
		record := table[offset:][:size]
		if size < DEFINITION_LISTS || string(record[:4]) != "IM03" do continue
		word :: proc(record: []byte, number: int) -> u32 {return tk5.be_u32(record, DEFINITION_WORDS + 4 * number)}
		definition.costumes, definition.part, definition.scalp_hair = u8(word(record, 5)), word(record, 11), word(record, 13) == 1
		definition.hidden_meshes = hidden_meshes(record, allocator)
	}
	return definitions, true
}

// The first run of body mesh lists after the fixed words [likely: some records put other words before it].
@(private = "file")
hidden_meshes :: proc(record: []byte, allocator := context.allocator) -> []int {
	meshes := make([dynamic]int, allocator)
	is_list :: proc(record: []byte, at: int) -> bool {
		if at + 16 > len(record) || tk5.be_u32(record, at) != BODY_MESHES || tk5.be_u32(record, at + 8) != 0 do return false
		count := int(tk5.be_u32(record, at + 4))
		return count > 0 && count <= HIDDEN_LIST_MAX && at + 12 + 4 * count <= len(record)
	}
	at := DEFINITION_LISTS
	for at + 4 <= len(record) && !is_list(record, at) do at += 4
	for is_list(record, at) {
		count := int(tk5.be_u32(record, at + 4))
		for mesh in 0 ..< count do append(&meshes, int(tk5.be_u32(record, at + 12 + 4 * mesh)))
		at += 12 + 4 * count
	}
	return meshes[:]
}
