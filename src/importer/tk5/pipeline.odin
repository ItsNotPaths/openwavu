package tk5_importer

import "core:fmt"
import "core:os"
import "core:strings"
import "../../db"
import convert "../../convert/tk5"
import formats "../../formats/tk5"

TK5_SCHEMA :: #load("../../db/tk5/schema.sql", string)
SCHEMA_VERSION :: "1"
IMPORTER_VERSION :: "0.1.0"
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
	archive: Archive,
	root:    string,  // out/tk5
	w:       db.Writer,
}

// Archive -> content pack under out/tk5/.
run :: proc(game: Game, out: string) -> (err: string) {
	table, ok := formats.read_file_table(game.eboot, game.build)
	if !ok do return "file table not found in EBOOT"
	defer delete(table)
	file, open_err := os.open(game.data)
	if open_err != nil do return "cannot open T55DATA1.BIN"
	defer os.close(file)

	im := Import{archive = {table, file}, root = strings.clone(join(out, "tk5"))}
	defer delete(im.root)
	for dir in ([]string{"anims", "parts", "stages", "images"}) {
		if !make_dir(join(im.root, dir)) do return fmt.tprintf("cannot create %s", join(im.root, dir))
	}
	im.w, err = db.create(join(im.root, "tk5.db"), TK5_SCHEMA)
	if err != "" do return err
	w := &im.w
	db.insert(w, "source", "title_id", game.build.title_id)
	db.insert(w, "source", "elf_sha256", game.build.elf_sha256)
	db.insert(w, "source", "data_sha256", game.data_sha256)
	db.insert(w, "source", "schema_version", SCHEMA_VERSION)
	db.insert(w, "source", "importer_version", IMPORTER_VERSION)

	// (hole import-skips :tags importer) a part, bank or stage that does not read is skipped without a message; the pack looks complete.
	if err = import_characters(&im); err != "" do return err
	common := read_entry(im.archive, formats.COMMON_ANIMS) or_else nil
	write_bank(&im, "common", common)
	for id in 0 ..< formats.STAGE_COUNT do import_stage(&im, id)
	import_sounds(&im)
	import_images(&im)
	return db.finish(w)
}

import_characters :: proc(im: ^Import) -> (err: string) {
	for c, char_index in formats.CHARACTERS {
		defer free_all(context.temp_allocator)
		w := &im.w
		db.insert(w, "character", c.id, c.name, i64(char_index))
		owner := formats.container_owner(c.container)

		packed := read_entry(im.archive, formats.MOTBIN_FIRST + 2 * char_index) or_else nil
		data, unpacked := formats.unlz(packed, context.temp_allocator)
		m, read := formats.read_motbin(data, context.temp_allocator)
		if !unpacked || !read do return fmt.tprintf("%s: motbin did not read", c.id)
		if err = convert.write_moveset_rows(w, c.id, owner, char_index, m); err != "" do return err
		if m.bank_offsets[0] < len(data) do write_bank(im, convert.embedded_owner(c.id), data[m.bank_offsets[0]:])
		if m.bank_offsets[formats.BANK_HANDS] < len(data) do write_hand_bank(im, fmt.tprintf("%s/hand_poses", c.id), data[m.bank_offsets[formats.BANK_HANDS]:])
		skeleton, has_skeleton := character_skeleton(im, c)
		if !has_skeleton do return fmt.tprintf("%s: skeleton did not read", c.id)
		convert.write_skeleton_rows(w, c.id, skeleton)
		top, measured := idle_head_top(im, c, m, data, &skeleton)
		if !measured do return fmt.tprintf("%s: standing idle did not read", c.id)
		if err = convert.write_stock_rows(w, c.id, char_index, m, top); err != "" do return err

		first, count := formats.costume_groups(c.container)
		for k in 0 ..< count {
			model, has := read_entry(im.archive, first + k * formats.GROUP_SIZE + formats.GROUP_MODEL)
			if !has do continue
			costume := fmt.tprintf("%d", k + 1)
			part := fmt.tprintf("%s_%s", owner, costume)
			parts := []string{part, fmt.tprintf("%s_lod", part)}
			if owner == c.id && !import_parts(im, owner, parts, model) do continue
			db.insert(w, "costume", c.id, costume)
			for p in parts do db.insert(w, "costume_part", c.id, costume, p)
		}
		if owner == c.id {
			container := read_entry(im.archive, c.container) or_else nil
			sections, _ := formats.sections(container, context.temp_allocator)
			// (hole face-anims :tags importer) face banks are not found or decoded; blinks and face state use libc rand 0x2e7a84.
			// (hole intro-re :tags importer) intros, win poses and outros are not located: motbin moves or separate data, and where their camera tracks live. Leads: move properties 0x8001..0x8008 (camera, dropped by the sim), the type-1 anim sections 1..5 (tk5decomp docs/data.md), the flashback angles, the fight camera 0x75724 (for sdk-camera params only).
			// (hole camera-anims :tags importer :needs intro-re) camera tracks are not imported (.anim layout tk5cam: position, target, roll, fov).
			if len(sections) > 0 do write_bank(im, owner, sections[0])
			if len(sections) > formats.BANK_HANDS do write_hand_bank(im, fmt.tprintf("%s/hand_gestures", owner), sections[formats.BANK_HANDS])
		}
	}
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
	skeleton := largest_skeleton(sections)
	for placeholder, frame0 in swaps do if t, has := textures[frame0]; has do textures[placeholder] = t
	if len(nud) < len(parts) || len(skeleton.bones) == 0 do return false

	dir := join(im.root, "parts", owner)
	if !make_dir(dir) do return false
	for part, i in parts {
		meshes, read := formats.read_ndp3(nud[i], context.temp_allocator)
		file := fmt.tprintf("parts/%s/%s.glb", owner, part)
		if !read || !convert.write_model(join(im.root, file), meshes, textures, skeleton) do return false
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

// The sim's skeleton: the one of the first costume.
character_skeleton :: proc(im: ^Import, c: formats.Character) -> (s: convert.Sim_Skeleton, ok: bool) {
	model := read_entry(im.archive, c.container + formats.GROUP_MODEL) or_return
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
		container := read_entry(im.archive, c.container) or_return
		banks := formats.sections(container, context.temp_allocator) or_return
		if len(banks) == 0 do return
		bank_data = banks[0]
	case anim & 0x8000 != 0: bank_data = read_entry(im.archive, formats.COMMON_ANIMS) or_return
	case: bank_data = data[m.bank_offsets[0]:]
	}
	bank := formats.read_bank(bank_data) or_return
	idle := formats.read_anim(bank, int(anim & 0x3fff), context.temp_allocator) or_return
	if idle.frames == 0 do return
	return convert.head_top(skeleton, idle), true
}

// Every anim of a body bank as anims/<owner>/<idx>.anim. Ids that share a record share the file of the first one.
write_bank :: proc(im: ^Import, owner: string, data: []byte) {
	bank, ok := formats.read_bank(data)
	if !ok || bank.count == 0 do return
	dir := join(im.root, "anims", owner)
	if !make_dir(dir) do return
	Written :: struct {file: string, frames: int}
	written := make(map[int]Written, context.temp_allocator)  // by record start
	for i in 0 ..< bank.count {
		start := formats.anim_start(bank, i)
		if w, shared := written[start]; shared {
			db.insert(&im.w, "anim", owner, i64(i), i64(w.frames), w.file)
			continue
		}
		a, decoded := formats.read_anim(bank, i, context.temp_allocator)
		if !decoded do continue
		file := fmt.tprintf("anims/%s/%d.anim", owner, i)
		if !convert.write_anim(join(im.root, file), a) do continue
		written[start] = {file, a.frames}
		db.insert(&im.w, "anim", owner, i64(i), i64(a.frames), file)
	}
}

// Every clip of a finger bank as anims/<owner>/<idx>.anim. The pose bank's clip 0 is the pose library: frame i = pose i.
write_hand_bank :: proc(im: ^Import, owner: string, data: []byte) {
	bank, ok := formats.read_hand_bank(data)
	if !ok do return
	dir := join(im.root, "anims", owner)
	if !make_dir(dir) do return
	for i in 0 ..< bank.count {
		frames, decoded := formats.read_hand_clip(bank, i, context.temp_allocator)
		if !decoded do continue
		file := fmt.tprintf("anims/%s/%d.anim", owner, i)
		if convert.write_hand_anim(join(im.root, file), frames) do db.insert(&im.w, "anim", owner, i64(i), i64(len(frames)), file)
	}
}

import_stage :: proc(im: ^Import, index: int) {
	defer free_all(context.temp_allocator)
	data, has := read_entry(im.archive, formats.STAGE_FIRST + 3 * index)
	if !has do return
	s, ok := formats.read_stage(data, context.temp_allocator)
	if !ok do return
	id := formats.STAGE_NAMES[index]
	if id == "" do id = fmt.tprintf("stage_%02d", index)

	textures := make(convert.Textures, context.temp_allocator)
	list, _ := formats.read_ntp3(s.sections[1], context.temp_allocator)
	for t in list do textures[t.hash] = t
	meshes: [dynamic]formats.Mesh
	matrices: [dynamic]Maybe([16]f32)
	meshes.allocator, matrices.allocator = context.temp_allocator, context.temp_allocator
	nuds, _ := formats.sections(s.sections[formats.STAGE_MESHES], context.temp_allocator)
	mifs, _ := formats.sections(s.sections[formats.STAGE_NODES], context.temp_allocator)
	for nud, i in nuds {
		if len(nud) == 0 || i >= len(mifs) do continue
		group, read := formats.read_ndp3(nud, context.temp_allocator)
		nodes, nodes_read := formats.read_mif_nodes(mifs[i], context.temp_allocator)
		if !read || !nodes_read || len(nodes) != len(group) do continue
		for mesh, k in group {
			mesh := mesh
			mesh.name = nodes[k].name  // _DRWOFF_ in the name: a broken state, hidden at start
			append(&meshes, mesh)
			transform: Maybe([16]f32)
			if mesh.single_bind >= 0 do transform = nodes[k].transform  // unbound meshes are in world space
			append(&matrices, transform)
		}
	}
	// (hole stage-break-pieces :tags importer :sev polish) section 4 (flying pieces of breakable props) is not exported.
	file := fmt.tprintf("stages/%s.glb", id)
	if len(meshes) > 0 && !convert.write_model(join(im.root, file), meshes[:], textures, nil, matrices[:]) do return
	collision, surfaces := fmt.tprintf("stages/%s.collision.glb", id), fmt.tprintf("stages/%s.surfaces", id)
	if !convert.write_stage_collision(join(im.root, collision), join(im.root, surfaces), s) do return
	db.insert(&im.w, "stage", id, id, i64(index), file, collision, surfaces)
}

// (hole sound-extract :tags (importer audio)) vag sound packs (entries 161..206, character slots +4/+5, stage packs) are not decoded to WAV (ffmpeg parts linked statically, ws.md).
import_sounds :: proc(im: ^Import) {}

// (hole tim2-textures :tags importer :sev polish) model section 17 (TIM2) is not decoded.
import_images :: proc(im: ^Import) {
	for index in 33 ..< 37 {
		defer free_all(context.temp_allocator)
		data, has := read_entry(im.archive, index)
		if !has do continue
		file := fmt.tprintf("images/%d.png", index)
		if os.write_entire_file(join(im.root, file), data) == nil do db.insert(&im.w, "image", fmt.tprintf("%d", index), file)
	}
}

// Unpacked archive entry in temp memory. The LZ layer, if any, stays.
read_entry :: proc(a: Archive, index: int) -> (data: []byte, ok: bool) {
	if index < 0 || index >= len(a.table) do return nil, false
	e := a.table[index]
	if formats.entry_missing(e) do return nil, false
	stored := make([]byte, e.stored_size, context.temp_allocator)
	if n, err := os.read_at(a.file, stored, formats.entry_offset(e)); err != nil || n != len(stored) do return nil, false
	return formats.unpack_entry(e, stored, context.temp_allocator)
}

make_dir :: proc(path: string) -> bool {
	return os.make_directory_all(path) == nil || os.is_dir(path)
}
