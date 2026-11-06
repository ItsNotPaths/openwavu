package tk5_importer

import "core:fmt"
import "core:os"
import "../../db"
import convert "../../convert/tk5"
import formats "../../formats/tk5"
import "../../fx"

// The shared sparks (effects/common/<n>.fx) and dust (effects/dust/<n>.fx), drawing the shared element package.
import_shared_effects :: proc(im: ^Import) -> (ok: bool) {
	defer free_all(context.temp_allocator)
	data := read_entry(im.archive, formats.EFFECT_ELEMENTS) or_return
	elements := formats.read_element_package(data, context.temp_allocator) or_return
	files := write_textures(im, "effects", package_textures(elements))
	Shared :: struct {entry: int, owner: string}
	for shared in ([]Shared{{formats.EFFECT_SPARKS, "common"}, {formats.EFFECT_DUST, "dust"}}) {
		efp := read_entry(im.archive, shared.entry) or_continue
		records := formats.read_efp(efp, context.temp_allocator) or_continue
		for record, index in records {
			if record.element >= len(elements.blocks) do continue
			write_effect(im, shared.owner, index, record, elements.blocks[record.element], elements.keyframes, files)
		}
	}
	return true
}

// A character's records (effects/<owner>/<n>.fx, written once per owner) and its hit table, from its first costume group.
// Record n draws block n of the character's own package: the game writes that element over the record's at spawn.
import_character_effects :: proc(im: ^Import, character: formats.Character, owner: string) -> (ok: bool) {
	data := read_entry(im.archive, character.container + formats.GROUP_EFFECTS) or_return
	sections := formats.sections(data, context.temp_allocator) or_return
	if len(sections) < 3 do return false
	rows := formats.read_effect_rows(sections[0]) or_return
	records := formats.read_efp(sections[1], context.temp_allocator) or_return
	elements := formats.read_element_package(sections[2], context.temp_allocator) or_return
	files := write_textures(im, owner, package_textures(elements))
	for row, index in rows {
		db.insert(&im.w, "character_effect_row", character.id, i64(index), i64(row.records), i64(row.sound_row), i64(row.light ? 1 : 0))
	}
	for record, index in records {
		if index >= len(elements.blocks) do break
		file, written := write_effect(im, owner, index, record, elements.blocks[index], elements.keyframes, files, owner == character.id)
		if written do db.insert(&im.w, "character_effect", character.id, i64(index), file)
	}
	return true
}

@(private = "file")
package_textures :: proc(elements: formats.Element_Package) -> convert.Textures {
	textures := make(convert.Textures, context.temp_allocator)
	list, _ := formats.read_ntp3(elements.textures, context.temp_allocator)
	for texture in list do textures[texture.hash] = texture
	return textures
}

// The effect file of a record: written when write_file, else only named (another character owns it).
@(private = "file")
write_effect :: proc(im: ^Import, owner: string, index: int, record: formats.Efp_Record, block: formats.Element_Block, keyframes: []byte, files: convert.Texture_Files, write_file := true) -> (file: string, ok: bool) {
	tracks: []formats.Efp_Track
	if record.flags & formats.EFP_TRACKS != 0 do tracks, _ = formats.read_efp_tracks(keyframes, block.mesh, context.temp_allocator)
	effect := convert.record_effect(record, block, tracks, files, context.temp_allocator) or_return
	file = fmt.tprintf("effects/%s/%d.fx", owner, index)
	if !write_file do return file, true
	data := fx.write(effect, context.temp_allocator) or_return
	make_dir(join(im.root, "effects", owner)) or_return
	return file, os.write_entire_file(join(im.root, file), data) == nil
}
