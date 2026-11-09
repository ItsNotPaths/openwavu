package tk5_importer

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "../../audio"
import "../../db"
import convert "../../convert/tk5"
import formats "../../formats/tk5"
import "../../release"
import "../../titlepack"

TK5_SCHEMA :: #load("../../db/tk5/schema.sql", string)
SCHEMA_VERSION :: "1"
SKELETON_NAMES := [convert.BODY_BONES]string{
	"root", "hips", "spine", "chest", "pelvis", "neck", "head",
	"r_clavicle", "r_upperarm", "r_forearm", "r_hand", "l_clavicle", "l_upperarm", "l_forearm", "l_hand",
	"r_thigh", "r_shin", "r_foot", "l_thigh", "l_shin", "l_foot", "r_toe", "l_toe",
}

Archive :: struct {
	table: []formats.Entry,
	file:  ^os.File,
}

Import :: struct {
	archive:  Archive,
	game:     Game,
	root:     string,
	w:        db.Writer,
	progress: ^Progress,
	textures: map[string]bool,  // <owner>/<hash> with a texture row
	sound_packs: map[[32]byte]string,  // SHA-256 of a sound pack -> the bank its files were written under
	failure:  string,  // the first part that did not read or write; it fails the import
}

Progress :: titlepack.Progress

// One step per character, stage, 2D art entry and font, one each for the music, the sounds, the select renders, the rest and the pack file.
PROGRESS_STEPS :: len(formats.CHARACTERS) + formats.STAGE_COUNT + len(formats.ART_ENTRIES) + len(formats.FONTS) + 5

// The banks every match shares, by archive entry.
SHARED_SOUND_BANKS := [?]struct {bank: string, entry: int}{
	{"menu", formats.SOUND_MENU}, {"round_calls", formats.SOUND_ROUND_CALLS}, {"common", formats.SOUND_COMMON}, {"names", formats.SOUND_NAMES},
}

// Archive -> the stock pack's files under root.
run :: proc(game: Game, root: string, progress: ^Progress = nil) -> (err: string) {
	table, ok := formats.read_file_table(game.eboot, game.build)
	if !ok do return "file table not found in EBOOT"
	defer delete(table)
	file, open_err := os.open(game.data)
	if open_err != nil do return "cannot open T55DATA1.BIN"
	defer os.close(file)
	Data_Hash :: struct {digest: [32]byte, ok: bool}
	data_hash: Data_Hash  // hashed on its own thread while the import runs: ~4 s without SHA instructions
	hasher := thread.create_and_start_with_poly_data2(game.data, &data_hash, proc(path: string, out: ^Data_Hash) {
		digest, err := hash.hash_file_by_name(.SHA256, path)
		copy(out.digest[:], digest)
		out.ok = err == nil
		delete(digest)
	})
	defer thread.destroy(hasher)

	im := Import{archive = {table, file}, game = game, root = root, progress = progress}
	defer {
		for key in im.textures do delete(key)
		delete(im.textures)
		for _, bank in im.sound_packs do delete(bank)
		delete(im.sound_packs)
	}
	for dir in ([]string{"anims", "effects", "music", "parts", "sounds", "stages", "textures", "ui"}) {
		if !make_dir(join(im.root, dir)) do return fmt.tprintf("cannot create %s", join(im.root, dir))
	}
	im.w, err = db.create(join(im.root, "tk5.db"), TK5_SCHEMA)
	if err != "" do return err
	w := &im.w
	db.insert(w, "source", "title_id", game.build.title_id)
	db.insert(w, "source", "elf_sha256", game.build.elf_sha256)
	db.insert(w, "source", "schema_version", SCHEMA_VERSION)
	db.insert(w, "source", "importer_version", release.current())

	if err = import_characters(&im); err != "" do return err
	write_bank(&im, "common", read_entry(&im, formats.COMMON_ANIMS) or_else nil)
	write_camera_bank(&im, "cameras", read_entry(&im, formats.GLOBAL_CAMERAS) or_else nil, .Plain)
	throw_cameras, read := formats.read_throw_cameras(game.eboot, game.build, context.temp_allocator)
	if !read do fail(&im, "throw cameras did not read")
	convert.write_throw_camera_rows(w, throw_cameras)
	// (hole side-switch-flags :tags (importer round-show) :needs coded-cameras) no side switch flag per throw_camera row: at import, place each row's shot against the anims of the throws that use its category and flag the rows whose shot ends with the fighters swapped on screen.
	stage_tracks := import_music(&im)  // before the stages that name them
	for id in 0 ..< formats.STAGE_COUNT {
		import_stage(&im, id, stage_tracks[id])
		step(&im)
	}
	if !import_shared_effects(&im) do fail(&im, "shared effects did not read")
	import_sounds(&im)
	import_sound_ids(&im)
	import_images(&im)
	step(&im)
	thread.join(hasher)
	if !data_hash.ok do return "cannot read T55DATA1.BIN"
	db.insert(w, "source", "data_sha256", string(hex.encode(data_hash.digest[:], context.temp_allocator)))
	if err = db.finish(w); err != "" do return err
	return im.failure
}

// A part that does not read would change the stock hash, so it can not play online: the import fails instead.
fail :: proc(im: ^Import, format: string, args: ..any) {
	if im.failure == "" do im.failure = fmt.aprintf(format, ..args)
}

step :: proc(im: ^Import) {
	if im.progress != nil do sync.atomic_add(&im.progress.done, 1)
}

import_characters :: proc(im: ^Import) -> (err: string) {
	for c, char_index in formats.CHARACTERS {
		// errors are temp strings: clone before the temp memory goes
		if err = import_character(im, c, char_index); err != "" do return strings.clone(err)
		free_all(context.temp_allocator)
		step(im)
	}
	return ""
}

import_character :: proc(im: ^Import, c: formats.Character, char_index: int) -> (err: string) {
	w := &im.w
	db.insert(w, "character", c.id, c.name, i64(char_index), i64(c.model))
	owner := formats.container_owner(c.container)

	packed := read_entry(im, formats.MOTBIN_FIRST + 2 * char_index) or_else nil
	data, unpacked := formats.unlz(packed, context.temp_allocator)
	m, read := formats.read_motbin(data, context.temp_allocator)
	if !unpacked || !read do return fmt.tprintf("%s: motbin did not read", c.id)
	if err = convert.write_moveset_rows(w, c.id, owner, char_index, m); err != "" do return err
	if bank, has := formats.embedded_bank(m, data, 0); has do write_bank(im, convert.embedded_owner(c.id), bank)
	if bank, has := formats.embedded_bank(m, data, formats.BANK_HANDS); has do write_hand_bank(im, fmt.tprintf("%s/hand_poses", c.id), bank)
	if bank, has := formats.embedded_bank(m, data, formats.BANK_CAMERAS); has do write_camera_bank(im, fmt.tprintf("%s/cameras", convert.embedded_owner(c.id)), bank, .Scaled)
	skeleton, has_skeleton := character_skeleton(im, c)
	if !has_skeleton do return fmt.tprintf("%s: skeleton did not read", c.id)
	convert.write_skeleton_rows(w, c.id, skeleton)
	top, measured := idle_head_top(im, c, m, data, &skeleton)
	if !measured do return fmt.tprintf("%s: standing idle did not read", c.id)
	if err = convert.write_stock_rows(w, c.id, char_index, m, top); err != "" do return err

	first, count := formats.costume_groups(c.container)
	for k in 0 ..< count {
		model, has := read_entry(im, first + k * formats.GROUP_SIZE + formats.GROUP_MODEL)
		if !has {
			fail(im, "%s: costume %d model is missing", c.id, k + 1)
			continue
		}
		costume := fmt.tprintf("%d", k + 1)
		part := fmt.tprintf("%s_%s", owner, costume)
		parts := []string{part, fmt.tprintf("%s_lod", part)}
		if owner == c.id {
			if !import_parts(im, owner, parts, model) {
				fail(im, "%s: costume %s did not read", c.id, costume)
				continue
			}
			group := first + k * formats.GROUP_SIZE
			write_sound_bank(im, fmt.tprintf("%s/voices", part), group + formats.GROUP_VOICES)
			write_sound_bank(im, fmt.tprintf("%s/stream_voices", part), group + formats.GROUP_STREAM_VOICES)
		}
		db.insert(w, "costume", c.id, costume)
		voice, read_voice := formats.read_costume_voice(im.game.eboot, im.game.build, first + k * formats.GROUP_SIZE)
		if !read_voice do fail(im, "%s: costume %s voice did not read", c.id, costume)
		db.insert(w, "costume_voice", c.id, costume, i64(voice))
		for p in parts do db.insert(w, "costume_part", c.id, costume, p)
	}
	if owner == c.id {
		container := read_entry(im, c.container) or_else nil
		sections, read_sections := formats.sections(container, context.temp_allocator)
		if !read_sections do fail(im, "%s: container did not read", c.id)
		// (hole face-anims :tags (importer fighter-detail)) face banks are not found or decoded; blinks and face state use libc rand 0x2e7a84.
		if len(sections) > 0 do write_bank(im, owner, sections[0])
		if len(sections) > formats.BANK_HANDS do write_hand_bank(im, fmt.tprintf("%s/hand_gestures", owner), sections[formats.BANK_HANDS])
		if len(sections) > formats.BANK_CAMERAS do write_camera_bank(im, fmt.tprintf("%s/cameras", owner), sections[formats.BANK_CAMERAS], .Scaled)
	}
	if !import_character_effects(im, c, owner) do fail(im, "%s: effects did not read", c.id)
	return ""
}

// Body (first NDP3) and LOD (second NDP3) of one costume model, sharing one skeleton.
import_parts :: proc(im: ^Import, owner: string, parts: []string, model: []byte) -> bool {
	sections, ok := formats.sections(model, context.temp_allocator)
	if !ok do return false
	textures := make(convert.Textures, context.temp_allocator)
	swaps := make(map[u32]u32, context.temp_allocator)
	nud: [dynamic][]byte
	nud.allocator = context.temp_allocator
	for s in sections {
		if len(s) < 4 do continue
		switch string(s[:4]) {
		case "NDP3": append(&nud, s)
		case "NTP3":
			list, _ := formats.read_ntp3(s, context.temp_allocator)
			for t in list do textures[t.hash] = t
		case "MIF\x00": formats.read_mif_swaps(s, &swaps)
		}
	}
	skeleton := costume_skeleton(sections)
	mop := costume_swings(sections)
	for placeholder, frame0 in swaps do if t, has := textures[frame0]; has do textures[placeholder] = t
	if len(nud) < len(parts) || len(skeleton.bones) == 0 do return false
	texture_files := write_textures(im, owner, textures)

	dir := join(im.root, "parts", owner)
	if !make_dir(dir) do return false
	for part, i in parts {
		meshes, read := formats.read_ndp3(nud[i], context.temp_allocator)
		file := fmt.tprintf("parts/%s/%s.glb", owner, part)
		if !read || !convert.write_model(im.root, file, meshes, texture_files, skeleton, mop = mop) do return false
		db.insert(&im.w, "part", part, owner, i == 0 ? "body" : "lod", parts[0], file)
	}
	for b, i in skeleton.bones {
		name := i < len(SKELETON_NAMES) ? SKELETON_NAMES[i] : fmt.tprintf("helper_%d", i)
		standard: db.Value = i < len(SKELETON_NAMES) ? SKELETON_NAMES[i] : db.Null{}
		db.insert(&im.w, "bone", parts[0], i64(i), i64(b.parent), name, standard)
	}
	return true
}

largest_skeleton :: proc(sections: [][]byte) -> (skeleton: formats.Skeleton) {
	for s in sections {
		if bones, is_bon := formats.read_skeleton(s, context.temp_allocator); is_bon && len(bones.bones) > len(skeleton.bones) {
			skeleton = bones
		}
	}
	return
}

// The costume's own skeleton, with its swing joints; the largest one is the shared base.
costume_skeleton :: proc(sections: [][]byte) -> formats.Skeleton {
	if len(sections) > formats.MODEL_COSTUME_BONES {
		blocks, ok := formats.sections(sections[formats.MODEL_COSTUME_BONES], context.temp_allocator)
		if ok && len(blocks) > 0 {
			if skeleton, is_bon := formats.read_skeleton(blocks[0], context.temp_allocator); is_bon do return skeleton
		}
	}
	return largest_skeleton(sections)
}

// The costume's swing joint values; none for a model without them.
costume_swings :: proc(sections: [][]byte) -> (mop: formats.Mop) {
	if len(sections) <= formats.MODEL_SWINGS do return
	blocks, ok := formats.sections(sections[formats.MODEL_SWINGS], context.temp_allocator)
	if !ok || len(blocks) == 0 do return
	mop, _ = formats.read_mop(blocks[0], context.temp_allocator)
	return
}

// The sim's skeleton: the one of the first costume.
character_skeleton :: proc(im: ^Import, c: formats.Character) -> (s: convert.Sim_Skeleton, ok: bool) {
	model := read_entry(im, c.container + formats.GROUP_MODEL) or_return
	sections := formats.sections(model, context.temp_allocator) or_return
	return convert.sim_skeleton(largest_skeleton(sections))
}

// Head end height in the standing idle (alias 1). data: the unpacked motbin.
idle_head_top :: proc(im: ^Import, c: formats.Character, m: formats.Motbin, data: []byte, skeleton: ^convert.Sim_Skeleton) -> (top: f32, ok: bool) {
	move := int(m.aliases[convert.IDLE_STAND_ALIAS])
	if move >= len(m.moves) do return
	anim := m.moves[move].anim
	bank_data: []byte
	switch {
	case anim & 0x4000 != 0:
		container := read_entry(im, c.container) or_return
		banks := formats.sections(container, context.temp_allocator) or_return
		if len(banks) == 0 do return
		bank_data = banks[0]
	case anim & 0x8000 != 0: bank_data = read_entry(im, formats.COMMON_ANIMS) or_return
	case: bank_data = data[m.bank_offsets[0]:]
	}
	bank := formats.read_bank(bank_data) or_return
	idle := formats.read_anim(bank, int(anim & 0x3fff), context.temp_allocator) or_return
	if idle.frames == 0 do return
	return convert.head_top(skeleton, idle), true
}

// Each new hash of owner as a texture row, in hash order. A MIF placeholder's row names its frame 0 file.
// Returns the file of every hash that has one, written now or before.
write_textures :: proc(im: ^Import, owner: string, textures: convert.Textures) -> (files: convert.Texture_Files) {
	files = make(convert.Texture_Files, context.temp_allocator)
	if !make_dir(join(im.root, "textures", owner)) {
		fail(im, "cannot create textures/%s", owner)
		return
	}
	hashes, _ := slice.map_keys(textures, context.temp_allocator)
	slice.sort(hashes)
	for hash in hashes {
		t := textures[hash]
		file := fmt.tprintf("textures/%s/%08x.dds", owner, t.hash)
		key := fmt.tprintf("%s/%08x", owner, hash)
		if key in im.textures {
			files[hash] = file
			continue
		}
		dds, ok := convert.texture_dds(t, context.temp_allocator)
		if !ok || os.write_entire_file(join(im.root, file), dds) != nil {
			fail(im, "texture %s did not convert", key)
			continue
		}
		db.insert(&im.w, "texture", owner, i64(hash), file)
		im.textures[strings.clone(key)] = true
		files[hash] = file
	}
	return
}

// Every anim of a body bank as anims/<owner>/<idx>.anim. Ids that share a record share the file of the first one.
write_bank :: proc(im: ^Import, owner: string, data: []byte) {
	bank, ok := formats.read_bank(data)
	if !ok {
		fail(im, "%s: anim bank did not read", owner)
		return
	}
	if !make_dir(join(im.root, "anims", owner)) {
		fail(im, "cannot create anims/%s", owner)
		return
	}
	Written :: struct {file: string, frames: int}
	written := make(map[int]Written, context.temp_allocator)  // by record start
	for i in 0 ..< bank.count {
		start := formats.anim_start(bank, i)
		if w, shared := written[start]; shared {
			db.insert(&im.w, "anim", owner, i64(i), i64(w.frames), w.file)
			continue
		}
		a, decoded := formats.read_anim(bank, i, context.temp_allocator)
		file := fmt.tprintf("anims/%s/%d.anim", owner, i)
		if !decoded || !convert.write_anim(join(im.root, file), a) {
			fail(im, "%s: anim %d did not convert", owner, i)
			continue
		}
		written[start] = {file, a.frames}
		db.insert(&im.w, "anim", owner, i64(i), i64(a.frames), file)
	}
}

// Every clip of a finger bank as anims/<owner>/<idx>.anim. The pose bank's clip 0 is the pose library: frame i = pose i.
write_hand_bank :: proc(im: ^Import, owner: string, data: []byte) {
	bank, ok := formats.read_hand_bank(data)
	if !ok {
		fail(im, "%s: hand bank did not read", owner)
		return
	}
	if !make_dir(join(im.root, "anims", owner)) {
		fail(im, "cannot create anims/%s", owner)
		return
	}
	for i in 0 ..< bank.count {
		frames, decoded := formats.read_hand_clip(bank, i, context.temp_allocator)
		file := fmt.tprintf("anims/%s/%d.anim", owner, i)
		if !decoded || !convert.write_hand_anim(join(im.root, file), frames) {
			fail(im, "%s: hand clip %d did not convert", owner, i)
			continue
		}
		db.insert(&im.w, "anim", owner, i64(i), i64(len(frames)), file)
	}
}

// Every track of a camera bank as anims/<owner>/<idx>.anim. Clip i is property 0x8153's clip (fighter banks) or camera id - 0x67 (global).
// 0x8153 names the fighter's own bank, even when the move's anim is in common (King, Roger, Armor King).
write_camera_bank :: proc(im: ^Import, owner: string, data: []byte, packing: convert.Camera_Packing) {
	bank, ok := formats.read_camera_bank(data)
	if !ok {
		fail(im, "%s: camera bank did not read", owner)
		return
	}
	if !make_dir(join(im.root, "anims", owner)) {
		fail(im, "cannot create anims/%s", owner)
		return
	}
	for i in 0 ..< bank.count {
		raw, decoded := formats.read_clip(bank, i, context.temp_allocator)
		file := fmt.tprintf("anims/%s/%d.anim", owner, i)
		frames, written := convert.write_camera_anim(join(im.root, file), raw, bank.channels, packing)
		if !decoded || !written {
			fail(im, "%s: camera track %d did not convert", owner, i)
			continue
		}
		db.insert(&im.w, "anim", owner, i64(i), i64(frames), file)
	}
}

stage_id :: proc(index: int) -> string {
	id := formats.STAGE_NAMES[index]
	return id != "" ? id : fmt.tprintf("stage_%02d", index)
}

// music_track: -1 for none.
import_stage :: proc(im: ^Import, index: int, music_track: int) {
	defer free_all(context.temp_allocator)
	data, has := read_entry(im, formats.STAGE_FIRST + 3 * index)
	if !has do return  // a cut stage
	id := stage_id(index)
	s, ok := formats.read_stage(data, context.temp_allocator)
	if !ok {
		fail(im, "stage %s did not read", id)
		return
	}

	textures := make(convert.Textures, context.temp_allocator)
	list, _ := formats.read_ntp3(s.sections[1], context.temp_allocator)
	for t in list do textures[t.hash] = t
	meshes: [dynamic]formats.Mesh
	matrices: [dynamic]Maybe([16]f32)
	layers: [dynamic]int
	tiles: [dynamic]Stage_Tile
	meshes.allocator, matrices.allocator = context.temp_allocator, context.temp_allocator
	layers.allocator, tiles.allocator = context.temp_allocator, context.temp_allocator
	nuds, _ := formats.sections(s.sections[formats.STAGE_MESHES], context.temp_allocator)
	mifs, _ := formats.sections(s.sections[formats.STAGE_NODES], context.temp_allocator)
	for nud, i in nuds {
		if len(nud) == 0 || i >= len(mifs) || i >= formats.STAGE_LAYERS do continue
		group, read := formats.read_ndp3(nud, context.temp_allocator)
		nodes, nodes_read := formats.read_mif_nodes(mifs[i], context.temp_allocator)
		if !read || !nodes_read || len(nodes) != len(group) {
			fail(im, "stage %s: layer %d did not read", id, i)
			continue
		}
		for mesh, k in group {
			mesh := mesh
			mesh.name = nodes[k].name  // _DRWOFF_ in the name: a broken state, hidden at start
			// (hole stage-shadows :tags (importer render look) :sev polish) the shadow receiver planes (slot 5) are left out, so fighters cast no shadow on the floor.
			if i == STAGE_SHADOW_LAYER do continue
			if i == STAGE_TILE_LAYER && s.radius > 0 do append(&tiles, Stage_Tile{len(meshes), nodes[k].transform[12], nodes[k].transform[14]})
			append(&meshes, mesh)
			append(&layers, i)
			transform: Maybe([16]f32)
			if mesh.single_bind >= 0 do transform = nodes[k].transform  // unbound meshes are in world space
			append(&matrices, transform)
		}
	}
	// (hole stage-show-cameras :tags (importer round-show) :sev polish) the stage show tracks (T55 entries 210..247, one looped clip per stage) are not imported.
	// (hole stage-break-pieces :tags importer :sev polish) section 4 (flying pieces of breakable props) is not exported.
	file := fmt.tprintf("stages/%s.glb", id)
	texture_files := write_textures(im, id, textures)
	if len(meshes) > 0 && !convert.write_model(im.root, file, meshes[:], texture_files, nil, matrices[:], layers[:]) {
		fail(im, "stage %s: model did not write", id)
		return
	}
	collision, surfaces := fmt.tprintf("stages/%s.collision.glb", id), fmt.tprintf("stages/%s.surfaces", id)
	if !convert.write_stage_collision(join(im.root, collision), join(im.root, surfaces), s) {
		fail(im, "stage %s: collision did not write", id)
		return
	}
	music: db.Value = music_track >= 0 ? fmt.tprintf("%d", music_track) : db.Null{}
	db.insert(&im.w, "stage", id, id, i64(index), file, collision, surfaces, music, f64(s.period / convert.MM), f64(s.radius / convert.MM))
	for tile in tiles do db.insert(&im.w, "stage_tile", id, i64(formats.STAGE_LAYERS + tile.mesh + 1), f64(tile.home_x / convert.MM), f64(tile.home_z / convert.MM))
}

STAGE_TILE_LAYER :: 2  // tk5decomp docs/stages.md 8.3
STAGE_SHADOW_LAYER :: 5  // stages.md 4: flat planes the fighters' shadows land on, never drawn as they are

// mesh: index in the stage's meshes; home: the MIF matrix translation, mm.
Stage_Tile :: struct {
	mesh:           int,
	home_x, home_z: f32,
}

// The shared banks and each stage's bank; the costumes' banks come with their character.
import_sounds :: proc(im: ^Import) {
	defer step(im)
	for shared in SHARED_SOUND_BANKS {
		write_sound_bank(im, shared.bank, shared.entry)
		free_all(context.temp_allocator)
	}
	for index in 0 ..< formats.STAGE_COUNT {
		write_sound_bank(im, stage_id(index), formats.SOUND_STAGE_FIRST + 3 * index)
		free_all(context.temp_allocator)
	}
}

// The tables that turn a sound cue's id into a record; each costume's voice character comes with its character.
import_sound_ids :: proc(im: ^Import) {
	w, eboot, build := &im.w, im.game.eboot, im.game.build
	defer free_all(context.temp_allocator)
	table := read_entry(im, formats.VOICE_TABLE) or_else nil
	rows, read_rows := formats.read_voice_table(table, context.temp_allocator)
	if !read_rows do fail(im, "voice table did not read")
	for row in rows do db.insert(w, "voice", i64(row.voice), i64(row.index), i64(row.record), i64(row.face), i64(row.kinds))
	names, read_names := formats.read_words(eboot, build.voice_names, 4 * formats.VOICE_CHARACTERS, allocator = context.temp_allocator)
	if !read_names do fail(im, "voice names did not read")
	for voice in 0 ..< len(names) / 4 {
		name := names[4 * voice:]
		db.insert(w, "voice_name", i64(voice), i64(name[0]), i64(name[1]), i64(name[2]))
	}
	specials, read_specials := formats.read_words(eboot, build.special_sounds, 5 * formats.SPECIAL_SOUNDS, allocator = context.temp_allocator)
	if !read_specials do fail(im, "special sounds did not read")
	for row in 0 ..< len(specials) / 5 {
		special := specials[5 * row:]
		for pair in 0 ..< 2 do if voice := special[1 + 2 * pair]; voice >= 0 do db.insert(w, "special_sound", i64(special[0]), i64(voice), i64(special[2 + 2 * pair]))
	}
	lists, read_lists := formats.read_stage_sounds(eboot, build, context.temp_allocator)
	if !read_lists do fail(im, "stage sounds did not read")
	for list, stage in lists {
		if pack, has := read_entry(im, formats.SOUND_STAGE_FIRST + 3 * stage); !has || len(pack) == 0 do continue  // a cut stage
		for record, k in list do if record >= 0 do db.insert(w, "stage_sound", stage_id(stage), i64(k + 1), i64(record))
	}
}

// Every sample of a sound pack as sounds/<bank>/<idx>.flac, named by its first record; records on one sample share it.
// A pack already written under another bank shares its files.
write_sound_bank :: proc(im: ^Import, bank: string, entry: int) {
	pack, has := read_entry(im, entry)
	if !has do return  // a cut stage
	records, read := formats.read_sound_pack(pack, context.temp_allocator)
	if !read {
		fail(im, "sound bank %s did not read", bank)
		return
	}
	digest: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, pack, digest[:])
	first, shared := im.sound_packs[digest]
	if !shared {
		if !make_dir(join(im.root, "sounds", bank)) {
			fail(im, "cannot create sounds/%s", bank)
			return
		}
		first = strings.clone(bank)
		im.sound_packs[digest] = first
	}
	files := make(map[int]string, context.temp_allocator)  // data offset -> file
	for record in records {
		file, sampled := files[record.data_offset]
		if !sampled {
			file = fmt.tprintf("sounds/%s/%d.flac", first, record.index)
			written := shared ? os.exists(join(im.root, file)) : write_sound(im, file, record)
			if !written {
				fail(im, "sound %s did not convert", file)
				continue
			}
			files[record.data_offset] = file
		}
		loop_start, loop_length := sound_loop(record)
		db.insert(&im.w, "sound", bank, i64(record.index), file, f64(record.volume), i64(record.pitch), f64(record.pan), loop_start, loop_length)
	}
}

// Every music track as music/<track>.flac; tracks on one entry share the first one's file. Returns each stage's track, -1 for none.
import_music :: proc(im: ^Import) -> (stage_tracks: [formats.STAGE_COUNT]int) {
	defer step(im)
	slice.fill(stage_tracks[:], -1)
	entries, read := formats.read_music_tracks(im.game.eboot, im.game.build)
	if !read {
		fail(im, "music tracks did not read")
		return
	}
	defer delete(entries)
	written := make(map[int]int)  // entry -> the track whose file it is
	defer delete(written)
	for entry, track in entries {
		defer free_all(context.temp_allocator)
		first, shared := written[entry]
		pack := read_entry(im, entry) or_continue  // track 18's entry is empty
		records, read_records := formats.read_sound_pack(pack, context.temp_allocator)
		if !read_records || len(records) != 1 {
			fail(im, "music %d did not read", track)
			continue
		}
		if !shared {
			first = track
			if !write_sound(im, fmt.tprintf("music/%d.flac", track), records[0]) {
				fail(im, "music %d did not convert", track)
				continue
			}
			written[entry] = track
		}
		loop_start, loop_length := sound_loop(records[0])
		db.insert(&im.w, "music", fmt.tprintf("%d", track), fmt.tprintf("music/%d.flac", first), loop_start, loop_length)
	}
	tracks, read_tracks := formats.read_stage_music(im.game.eboot, im.game.build, context.temp_allocator)
	if !read_tracks do fail(im, "stage music did not read")
	for track, stage in tracks do if track >= 0 && entries[track] in written do stage_tracks[stage] = track
	return
}

// A record as a FLAC file: PS ADPCM mono at its rate, ATRAC3plus as its RIFF says, without the delay.
write_sound :: proc(im: ^Import, file: string, record: formats.Sound_Record) -> bool {
	samples: []i16
	channels, rate := 1, record.rate
	switch record.codec {
	case .PS_ADPCM:
		samples = audio.decode(.PS_ADPCM, channels, rate, audio.PS_ADPCM_FRAME, record.data, context.temp_allocator) or_return
	case .ATRAC3_PLUS:
		riff := formats.read_riff(record.data) or_return
		channels, rate = riff.channels, riff.rate
		decoded := audio.decode(.ATRAC3_PLUS, channels, rate, riff.block_align, riff.data, context.temp_allocator) or_return
		if (riff.skip + riff.frames) * channels > len(decoded) do return false
		samples = decoded[riff.skip * channels:][:riff.frames * channels]
	case: return false
	}
	flac := audio.flac(samples, channels, rate, context.temp_allocator) or_return
	return os.write_entire_file(join(im.root, file), flac) == nil
}

// A record's loop in samples of its FLAC file; NULL for none.
sound_loop :: proc(record: formats.Sound_Record) -> (start, length: db.Value) {
	if !record.looped do return db.Null{}, db.Null{}
	switch record.codec {
	case .PS_ADPCM:
		return i64(record.loop_start / audio.PS_ADPCM_FRAME * audio.PS_ADPCM_SAMPLES), i64(record.loop_length / audio.PS_ADPCM_FRAME * audio.PS_ADPCM_SAMPLES)
	case .ATRAC3_PLUS:
		riff, _ := formats.read_riff(record.data)
		return i64(record.loop_start - riff.skip), i64(record.loop_length)
	}
	return db.Null{}, db.Null{}
}

// (hole tim2-textures :tags importer :sev polish) model section 17 (TIM2) is not decoded.
// (hole menu-layouts :tags (importer tk5mod)) a screen's SWG layout is copied as is, not decoded; its third block is dropped.
// The PNGs in the archive, the PS3 menu art next to PARAM.SFO, every 2D art entry, the fonts and the select renders.
import_images :: proc(im: ^Import) {
	for index in 33 ..< 37 {
		defer free_all(context.temp_allocator)
		data, has := read_entry(im, index)
		if has do write_image(im, fmt.tprintf("%d", index), data)
	}
	for name in ([]string{"icon0", "pic0", "pic1", "pic2"}) {
		defer free_all(context.temp_allocator)
		data, err := os.read_entire_file(join(im.game.dir, fmt.tprintf("%s.PNG", strings.to_upper(name, context.temp_allocator))), context.temp_allocator)
		if err == nil do write_image(im, name, data)
	}
	for art in formats.ART_ENTRIES {
		defer step(im)
		defer free_all(context.temp_allocator)
		parts, read := art_sections(im, art)
		if !read {
			fail(im, "art %s did not read", art.name)
			continue
		}
		for section, i in parts do write_art(im, fmt.tprintf("%s/%03d", art.name, i), section)
	}
	for names in formats.ART_NAMES {
		for id, i in names.ids {
			defer free_all(context.temp_allocator)
			file := fmt.tprintf("ui/%s/%03d.png", names.screen, names.first + i)
			if os.exists(join(im.root, file)) do db.insert(&im.w, "image", fmt.tprintf("%s/%s", names.kind, id), file)
		}
	}
	for font in formats.FONTS {
		defer step(im)
		defer free_all(context.temp_allocator)
		data := read_entry(im, font.index) or_else nil
		parts, read := formats.sections(data, context.temp_allocator)
		if !read || 2 * (font.first + font.pages) > len(parts) || !make_dir(join(im.root, "ui", "fonts", font.name)) {
			fail(im, "font %s did not read", font.name)
			continue
		}
		line_height, _, read_height := formats.read_nfh(parts[2 * font.first + 1], context.temp_allocator)
		if !read_height do fail(im, "font %s did not read", font.name)
		db.insert(&im.w, "font", font.name, i64(line_height))
		for page in 0 ..< font.pages {
			pair := 2 * (font.first + page)
			_, glyphs, read_glyphs := formats.read_nfh(parts[pair + 1], context.temp_allocator)
			pngs, _ := convert.art_pngs(parts[pair], context.temp_allocator)
			if !read_glyphs || len(pngs) == 0 || pngs[0] == nil {
				fail(im, "font %s page %d did not read", font.name, page)
				continue
			}
			id := fmt.tprintf("fonts/%s/%02d", font.name, page)
			write_image(im, id, pngs[0])
			for g in glyphs {
				db.insert(&im.w, "glyph", font.name, i64(g.code), id, i64(g.x), i64(g.y), i64(g.width), i64(g.height), g.x_offset, g.y_offset, g.advance)
			}
		}
	}
	defer step(im)
	if !make_dir(join(im.root, "ui", "select_renders")) {
		fail(im, "cannot create ui/select_renders")
		return
	}
	for render, i in formats.SELECT_RENDERS {
		defer free_all(context.temp_allocator)
		data := read_entry(im, formats.SELECT_RENDERS_FIRST + i) or_else nil
		section, read := formats.unlz(data, context.temp_allocator)
		if !read {
			fail(im, "select render %s did not read", render.fighter)
			continue
		}
		write_art(im, fmt.tprintf("select_renders/%s_%s", render.fighter, render.faces_left ? "left" : "right"), section)
	}
}

// An art entry's picture sections; a screen's layout goes to ui/<name>/layout.swg.
art_sections :: proc(im: ^Import, art: formats.Art_Entry) -> (parts: [][]byte, ok: bool) {
	data := read_entry(im, art.index) or_return
	is_container: bool
	parts, is_container = formats.sections(data, context.temp_allocator)
	if !is_container {
		data = formats.unlz(data, context.temp_allocator) or_return
		parts = formats.sections(data, context.temp_allocator) or_return
	}
	make_dir(join(im.root, "ui", art.name)) or_return
	if !art.screen do return parts, true
	if len(parts) < 2 || os.write_entire_file(join(im.root, "ui", art.name, "layout.swg"), parts[0]) != nil do return
	return formats.sections(parts[1], context.temp_allocator)
}

// A texture section as ui/<id>.png, more pictures as <id>_1, <id>_2. Other sections (fonts' NFH) are skipped.
write_art :: proc(im: ^Import, id: string, section: []byte) {
	pngs, _ := convert.art_pngs(section, context.temp_allocator)
	for png, k in pngs do if png != nil do write_image(im, k == 0 ? id : fmt.tprintf("%s_%d", id, k), png)
}

write_image :: proc(im: ^Import, id: string, png: []byte) {
	file := fmt.tprintf("ui/%s.png", id)
	if os.write_entire_file(join(im.root, file), png) != nil {
		fail(im, "cannot write %s", file)
		return
	}
	db.insert(&im.w, "image", id, file)
}

// Unpacked archive entry in temp memory; not ok for a missing entry. The LZ layer, if any, stays.
read_entry :: proc(im: ^Import, index: int) -> (data: []byte, ok: bool) {
	if index < 0 || index >= len(im.archive.table) {
		fail(im, "archive entry %d is past the file table", index)
		return
	}
	e := im.archive.table[index]
	if formats.entry_missing(e) do return
	stored := make([]byte, e.stored_size, context.temp_allocator)
	if n, err := os.read_at(im.archive.file, stored, formats.entry_offset(e)); err != nil || n != len(stored) {
		fail(im, "archive entry %d did not read", index)
		return
	}
	data, ok = formats.unpack_entry(e, stored, context.temp_allocator)
	if !ok do fail(im, "archive entry %d did not unpack", index)
	return
}

make_dir :: proc(path: string) -> bool {
	return os.make_directory_all(path) == nil || os.is_dir(path)
}
