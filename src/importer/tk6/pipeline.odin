package tk6_importer

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "../../db"
import tk6_convert "../../convert/tk6"
import tk5_convert "../../convert/tk5"
import tk6 "../../formats/tk6"
import tk5 "../../formats/tk5"
import "../../ps3"
import "../../release"
import tk5_importer "../tk5"

TK6_SCHEMA :: #load("../../db/tk6/schema.sql", string)
SCHEMA_VERSION :: "1"
DATABASE :: "tk6.db"
COSTUMES :: [?]int{tk6.PLAYER_ONE}  // costume n + 1 is the game's costume n

Progress :: tk5_importer.Progress

// One step per character and stage, one for the shared anims and the rest.
PROGRESS_STEPS :: len(tk6.CHARACTERS) + len(tk6.STAGES) + 2

Import :: struct {
	game:     tk6.Game_Files,
	root:     string,
	w:        db.Writer,
	progress: ^Progress,
	textures: map[string]bool,  // <owner>/<hash> with a texture row
	failure:  string,  // the first part that did not read or write; it fails the import
}

// The game's files under usrdir -> the stock pack's files under root.
// (hole tk6-sound :tags (tk6 importer audio) :sev gap) no sound or music import; the converter already keeps full voice words.
run :: proc(usrdir, root: string, progress: ^Progress = nil) -> (err: string) {
	game, opened := tk6.open_game_files(usrdir)
	if !opened do return fmt.tprintf("cannot open the game files in %s", usrdir)
	defer tk6.close_game_files(&game)
	im := Import{game = game, root = root, progress = progress}
	defer {
		for key in im.textures do delete(key)
		delete(im.textures)
	}
	for dir in ([]string{"anims", "parts", "stages", "textures"}) {
		if !make_dir(join(root, dir)) do return fmt.tprintf("cannot create %s", join(root, dir))
	}
	im.w, err = db.create(join(root, DATABASE), TK6_SCHEMA)
	if err != "" do return err
	w := &im.w
	title_id := "BLES00635"
	if sfo, read := os.read_entire_file(join(usrdir, "..", "PARAM.SFO"), context.temp_allocator); read == nil {
		title_id = ps3.read_sfo_string(sfo, "TITLE_ID") or_else title_id
	}
	db.insert(w, "source", "title_id", title_id)
	db.insert(w, "source", "schema_version", SCHEMA_VERSION)
	db.insert(w, "source", "importer_version", release.current())

	write_bank(&im, "common", read_file(&im, tk6.COMMON_ANIMS) or_else nil)
	step(&im)
	roster, listed := tk6.read_roster(game)
	if !listed do return "the move sets did not read"
	defer tk6.delete_roster(roster)
	for character in tk6.CHARACTERS {
		if err = import_character(&im, character, roster); err != "" do return strings.clone(err)
		free_all(context.temp_allocator)
		step(&im)
	}
	for stage in tk6.STAGES {
		import_stage(&im, stage)
		free_all(context.temp_allocator)
		step(&im)
	}
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

import_character :: proc(im: ^Import, character: tk6.Character, roster: []tk6.Roster_Entry) -> (err: string) {
	w := &im.w
	id := character.id
	db.insert(w, "character", id, character.name, i64(character.chara), i64(character.model))

	motbin_index := -1
	for entry in roster do if entry.name == character.motbin do motbin_index = entry.index
	data, read := read_file(im, motbin_index)
	if !read do return fmt.tprintf("%s: no move set %s", id, character.motbin)
	motbin, parsed := tk6.read_motbin(data, context.temp_allocator)
	if !parsed do return fmt.tprintf("%s: move set did not read", id)
	fallbacks: tk6_convert.Fallbacks
	defer tk6_convert.delete_fallbacks(fallbacks)
	if err = tk6_convert.write_moveset_rows(w, id, id, motbin, &fallbacks); err != "" do return

	container_index, paired := tk6.anim_container(im.game, motbin_index)
	if !paired do return fmt.tprintf("%s: no anim container", id)
	container := read_file(im, container_index) or_else nil
	banks, unpacked := tk5.sections(container, context.temp_allocator)
	if !unpacked || len(banks) == 0 do return fmt.tprintf("%s: anim container did not read", id)
	if !bank_fits(motbin, banks[0]) do return fmt.tprintf("%s: anim container %d does not fit the move set", id, container_index)
	write_bank(im, id, banks[0])
	// (hole tk6-hand-face-camera-banks :tags (tk6 importer) :sev polish) container sections 1, 2 and 5 (hands, face, move cameras) are not imported.

	body_data, has_body := read_file(im, tk6.body_file(character))
	if !has_body do return fmt.tprintf("%s: no body model", id)
	body := tk6.sections(body_data, context.temp_allocator) or_else nil
	if len(body) <= tk6.MODEL_BONES do return fmt.tprintf("%s: body model did not read", id)
	bone, has_bone := tk6.read_bone(body[tk6.MODEL_BONES], context.temp_allocator)
	skeleton, mapped := tk6_convert.sim_skeleton(bone)
	if !has_bone || !mapped do return fmt.tprintf("%s: skeleton did not read", id)
	tk5_convert.write_skeleton_rows(w, id, skeleton)
	idle, has_idle := idle_anim(im, motbin, banks[0])
	if !has_idle do return fmt.tprintf("%s: standing idle did not read", id)
	// (hole tk6-body-rows :tags (tk6 importer) :sev polish) hurt and push radii, points and gaze are TK5's defaults, not read from TK6.
	body_model := character.model == tk5_convert.MODEL_JINPACHI ? 0 : character.model  // TK6 has no Jinpachi: 34 is Bob
	tk5_convert.write_body(w, id, body_model, tk5_convert.head_top(&skeleton, idle))
	tk5_convert.write_body_points(w, id, -1)
	tk5_convert.write_gaze(w, id, -1)

	for costume in COSTUMES do import_costume(im, character, costume, bone)
	return ""
}

// Every container anim id of the move set is in the bank: the pairing of move set and container holds.
bank_fits :: proc(motbin: tk6.Motbin, own_bank: []byte) -> bool {
	bank, read := tk6.read_mota(own_bank, context.temp_allocator)
	if !read do return false
	for move in motbin.moves {
		if move.animation & tk6.CONTAINER_BANK != 0 && int(move.animation & tk6.ANIM_INDEX) >= bank.count do return false
	}
	return true
}

// Alias 1's anim: the standing idle, whose head end height the body row keeps.
idle_anim :: proc(im: ^Import, motbin: tk6.Motbin, own_bank: []byte) -> (idle: tk5.Anim, ok: bool) {
	move := int(motbin.aliases[tk5_convert.IDLE_STAND_ALIAS])
	if move >= len(motbin.moves) do return
	anim := motbin.moves[move].animation
	bank_data := anim & tk6.COMMON_BANK != 0 ? read_file(im, tk6.COMMON_ANIMS) or_return : own_bank
	bank := tk6.read_mota(bank_data, context.temp_allocator) or_return
	idle = tk6.read_mota_anim(bank, int(anim & tk6.ANIM_INDEX), context.temp_allocator) or_return
	return idle, idle.frames > 0
}

// The body model and the costume's parts. The body model's part is the costume's own: it hides the meshes the parts cover.
// (hole tk6-costumes :tags (tk6 importer) :sev polish) only costume 1 is imported; the 2P parts are mapped.
import_costume :: proc(im: ^Import, character: tk6.Character, costume: int, bone: tk5.Skeleton) {
	w := &im.w
	id := character.id
	name := fmt.tprintf("%d", costume + 1)
	worn, read := tk6.read_costume(im.game, character, costume, context.temp_allocator)
	if !read {
		fail(im, "%s: costume %s did not read", id, name)
		return
	}
	db.insert(w, "costume", id, name)
	body_part := fmt.tprintf("%s_%s_body", id, name)
	first_mesh_node, written := write_part(im, id, body_part, "body", body_part, tk6.body_file(character), texture_set = worn.body_texture_set)
	if !written {
		fail(im, "%s: body model did not convert", id)
		return
	}
	db.insert(w, "costume_part", id, name, body_part)
	for joint, index in tk6_convert.glb_skeleton(bone, nil, context.temp_allocator).bones {
		names := tk5_importer.SKELETON_NAMES
		standard: db.Value = index < len(names) ? names[index] : db.Null{}
		joint_name := index < len(names) ? names[index] : fmt.tprintf("helper_%d", index)
		db.insert(w, "bone", body_part, i64(index), i64(joint.parent), joint_name, standard)
	}
	hidden := make(map[int]bool, context.temp_allocator)
	for part in worn.parts {
		// (hole tk6-costume-effects :tags (tk6 importer look) :sev polish) aura and rage glow parts (effect models, particles in section 9) are skipped.
		if tk6.is_effect_model(im.game, tk6.part_file(character, part.slot)) do continue
		for mesh in part.hidden_meshes do hidden[mesh] = true
		part_id := fmt.tprintf("%s_part_%d", id, part.slot)
		if _, part_written := write_part(im, id, part_id, "item", body_part, tk6.part_file(character, part.slot), worn.colours); !part_written {
			fail(im, "%s: part %d did not convert", id, part.slot)
			continue
		}
		db.insert(w, "costume_part", id, name, part_id)
	}
	meshes := slice.map_keys(hidden, context.temp_allocator) or_else nil
	slice.sort(meshes)
	for mesh in meshes do db.insert(w, "part_hidden_mesh", body_part, i64(first_mesh_node + mesh + 1))
}

// One model file as parts/<owner>/<part>.glb on its own skeleton (the body's bones, then its cloth joints), and its
// part row. Its textures are its own, the set of each colour channel's colour (set 0 when the part has fewer: Mokujin's
// heads) and its texture set.
// (hole tk6-physics :tags (tk6 importer) :sev polish) ties and cloth flaps are rigid (user: no physics for now); model section 3 is the swing data, unread.
write_part :: proc(im: ^Import, owner, part, slot, skeleton_part: string, file: int, colours: [tk6.COLOUR_CHANNELS]int = {}, texture_set := 0) -> (first_mesh_node: int, ok: bool) {
	sections := tk6.sections(read_file(im, file) or_return, context.temp_allocator) or_return
	if len(sections) <= tk6.MODEL_BONES do return
	bone := tk6.read_bone(sections[tk6.MODEL_BONES], context.temp_allocator) or_return
	texture_sections := make([dynamic][]byte, context.temp_allocator)
	append(&texture_sections, sections[tk6.MODEL_TEXTURES])
	for colour, channel in colours {
		for candidate in ([]int{colour, 0}) {
			file_after_part, set := tk6.colour_set(channel, candidate)
			colour_sections := tk6.sections(read_file(im, file + file_after_part) or_continue, context.temp_allocator) or_continue
			if set < len(colour_sections) && len(colour_sections[set]) > 0 {
				append(&texture_sections, colour_sections[set])
				break
			}
		}
	}
	if len(sections) > tk6.MODEL_TEXTURE_SETS {
		sets := tk6.sections(sections[tk6.MODEL_TEXTURE_SETS], context.temp_allocator) or_else nil
		if texture_set < len(sets) do append(&texture_sections, sets[texture_set])
	}
	textures := make(tk5_convert.Textures, context.temp_allocator)
	for section in texture_sections {
		list := tk5.read_ntp3(section, context.temp_allocator) or_continue
		for texture in list do if texture.hash not_in textures do textures[texture.hash] = texture
	}
	meshes := tk5.read_ndp3(sections[tk6.MODEL_MESHES], context.temp_allocator, tk6.MATERIAL_SLOTS) or_return
	skeleton := tk6_convert.glb_skeleton(bone, meshes, context.temp_allocator)
	make_dir(join(im.root, "parts", owner)) or_return
	glb := fmt.tprintf("parts/%s/%s.glb", owner, part)
	first_mesh_node = tk6_convert.write_model(im.root, glb, meshes, write_textures(im, owner, textures), nil, skeleton) or_return
	db.insert(&im.w, "part", part, owner, slot, skeleton_part, glb)
	return first_mesh_node, true
}

// The six layers as one glb, each placed by its nodes, and the walls and floor.
// (hole tk6-stage-look :tags (tk6 importer) :sev polish) stage blend modes, node anims (gyas) and the effect list are not read.
// (hole tk6-stage-start :tags (tk6 importer) :sev gap) the start points are not read (posf holds none found), so the sim's fallback line places the fighters.
// (hole tk6-floor-breaks :tags (tk6 importer) :sev gap) floor and wall breaks are not imported; they look like stage objects (properties touch them), not fighter code [guess].
import_stage :: proc(im: ^Import, stage: tk6.Stage) {
	collision, has_collision := tk6.read_stage_collision(im.game, stage, context.temp_allocator)
	if !has_collision {
		fail(im, "stage %s: collision did not read", stage.id)
		return
	}
	textures := make(tk5_convert.Textures, context.temp_allocator)
	meshes: [dynamic]tk5.Mesh
	matrices: [dynamic]Maybe([16]f32)
	layers: [dynamic]int
	meshes.allocator, matrices.allocator, layers.allocator = context.temp_allocator, context.temp_allocator, context.temp_allocator
	for layer in 0 ..< tk6.STAGE_LAYERS {
		read, ok := tk6.read_stage_layer(im.game, stage, layer, context.temp_allocator)
		if !ok {
			fail(im, "stage %s: layer %d did not read", stage.id, layer)
			return
		}
		for texture in read.textures do textures[texture.hash] = texture
		if layer == tk6.SPAWNED_LAYER do continue  // its textures are the other layers' too
		append(&meshes, ..read.meshes)
		append(&matrices, ..read.matrices)
		for _ in read.meshes do append(&layers, layer)
	}
	lower_stage(matrices[:], &collision)
	// File layer k is the game's stage layer STAGE_LAYERS - 1 - k (its "stg_n" element; layer 0 holds the effects). Blended
	// draws go lowest order first: the sky, then the scenery, then the effects with the fighters (order 0) by distance.
	layer_orders: [tk6.STAGE_LAYERS]int
	for &order, layer in layer_orders do order = -layer
	file := fmt.tprintf("stages/%s.glb", stage.id)
	texture_files := write_textures(im, stage.id, textures)
	if _, written := tk6_convert.write_model(im.root, file, meshes[:], texture_files, nil, nil, matrices[:], layers[:], layer_orders[:]); !written {
		fail(im, "stage %s: model did not write", stage.id)
		return
	}
	collision_file, surfaces_file := fmt.tprintf("stages/%s.collision.glb", stage.id), fmt.tprintf("stages/%s.surfaces", stage.id)
	if !tk6_convert.write_stage_collision(join(im.root, collision_file), join(im.root, surfaces_file), collision) {
		fail(im, "stage %s: collision did not write", stage.id)
		return
	}
	db.insert(&im.w, "stage", stage.id, stage.id, db.Null{}, file, collision_file, surfaces_file, db.Null{}, f64(0), f64(0))
}

// The sim keeps the fighters' floor at y 0 (gravity and landings), so a stage that starts on a raised level moves
// down by its floor height, the model and the collision alike [likely: the game keeps the current level at 0 too].
lower_stage :: proc(matrices: []Maybe([16]f32), collision: ^tk6.Stage_Collision) {
	IDENTITY :: [16]f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	TRANSLATION_Y :: 13  // row vectors
	height := collision.floor_height
	if height == 0 do return
	for &placed in matrices {
		lowered := placed.? or_else IDENTITY
		lowered[TRANSLATION_Y] -= height
		placed = lowered
	}
	for &floor in collision.floors do for &corner in floor.corners do corner.y -= height
	for &wall in collision.walls do for &corner in wall.corners do corner.y -= height
	collision.floor_height = 0
}

// Each new hash of owner as a texture row. Returns the file of every hash, written now or before.
write_textures :: proc(im: ^Import, owner: string, textures: tk5_convert.Textures) -> (files: tk5_convert.Texture_Files) {
	files = make(tk5_convert.Texture_Files, context.temp_allocator)
	if !make_dir(join(im.root, "textures", owner)) {
		fail(im, "cannot create textures/%s", owner)
		return
	}
	hashes, _ := slice.map_keys(textures, context.temp_allocator)
	slice.sort(hashes)
	for hash in hashes {
		file := fmt.tprintf("textures/%s/%08x.dds", owner, hash)
		key := fmt.tprintf("%s/%08x", owner, hash)
		if key not_in im.textures {
			dds, converted := tk5_convert.texture_dds(textures[hash], context.temp_allocator)
			if !converted || os.write_entire_file(join(im.root, file), dds) != nil {
				fail(im, "texture %s did not convert", key)
				continue
			}
			db.insert(&im.w, "texture", owner, i64(hash), file)
			im.textures[strings.clone(key)] = true
		}
		files[hash] = file
	}
	return
}

// Every anim of a MOTA bank as anims/<owner>/<idx>.anim. Ids that share a record share the file of the first one.
write_bank :: proc(im: ^Import, owner: string, data: []byte) {
	bank, ok := tk6.read_mota(data, context.temp_allocator)
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
	for index in 0 ..< bank.count {
		start := tk6.mota_anim_start(bank, index)
		if shared, has := written[start]; has {
			db.insert(&im.w, "anim", owner, i64(index), i64(shared.frames), shared.file)
			continue
		}
		anim, decoded := tk6.read_mota_anim(bank, index, context.temp_allocator)
		file := fmt.tprintf("anims/%s/%d.anim", owner, index)
		if !decoded || !tk5_convert.write_anim(join(im.root, file), anim) {
			fail(im, "%s: anim %d did not convert", owner, index)
			continue
		}
		written[start] = {file, anim.frames}
		db.insert(&im.w, "anim", owner, i64(index), i64(anim.frames), file)
	}
}

// A file in temp memory; not ok for an empty slot.
read_file :: proc(im: ^Import, index: int) -> (data: []byte, ok: bool) {
	return tk6.read_file(im.game, index, allocator = context.temp_allocator)
}

make_dir :: tk5_importer.make_dir
join :: tk5_importer.join
