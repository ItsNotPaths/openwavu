package tk5_importer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "../../titlepack"

PACK_ID :: "tekken5dr"
STOCK_PACK :: PACK_ID  // a folder: stock packs are built here and never sent, so they need no tar

// The stock modules build.sh made from modules/tk5, so an import writes this openwavu's own.
GAMEPLAY_MODULE :: #load("../../../build/modules/gameplay.wasm", string)
GAMERENDER_MODULE :: #load("../../../build/modules/gamerender.wasm", string)
APP_MODULE :: #load("../../../build/modules/app.wasm", string)
STOCK_FRONT :: #load("../../../modules/tk5/front.owf", string)
DISPLAY_FONT :: #load("../../../vendor/fonts/Michroma-Regular.ttf", string)  // the stock menus' labels
DISPLAY_FONT_LICENSE :: #load("../../../vendor/fonts/Michroma-OFL.txt", string)
STOCK_MANIFEST :: #load("../../../modules/tk5/pack.toml", string)  // without version and [import], which an import adds

// The game's stock title pack: the folder packs_dir/tekken5dr/, built beside it and renamed in when whole, then its
// hash file (titlepack.folder_hash). inputs are recorded so an openwavu update can rebuild it.
build_pack :: proc(inputs: []string, packs_dir: string, progress: ^Progress = nil) -> (err: string) {
	if progress != nil do sync.atomic_store(&progress.total, PROGRESS_STEPS)
	if !make_dir(packs_dir) do return fmt.aprintf("cannot create %s", packs_dir)
	scratch := strings.clone(join(packs_dir, PACK_ID + ".source"))  // an unpacked .pkg
	defer delete(scratch)
	os.remove_all(scratch)
	defer os.remove_all(scratch)
	game: Game
	if game, err = find_game(inputs, scratch); err != "" do return
	defer destroy_game(game)
	stage := strings.clone(join(packs_dir, PACK_ID + ".part"))  // run frees temp memory
	defer delete(stage)
	os.remove_all(stage)
	defer os.remove_all(stage)
	if err = run(game, stage, progress); err != "" do return
	if err = write_pack_files(stage, inputs); err != "" do return
	digest, hash_err := titlepack.folder_hash(stage)
	if hash_err != "" do return strings.clone(hash_err)
	pack := join(packs_dir, STOCK_PACK)
	os.remove(titlepack.folder_hash_path(pack))
	os.remove_all(pack)
	if os.rename(stage, pack) != nil do return fmt.aprintf("cannot move the pack into %s", pack)
	if hash_err = titlepack.write_folder_hash(pack, digest); hash_err != "" do return strings.clone(hash_err)
	if progress != nil do sync.atomic_add(&progress.done, 1)
	return
}

// pack.toml, the front, the modules and the menu font: the files a pack needs at its root.
write_pack_files :: proc(stage: string, inputs: []string) -> (err: string) {
	toml := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&toml, "version = %s", quote(IMPORTER_VERSION))
	fmt.sbprint(&toml, STOCK_MANIFEST)
	fmt.sbprintln(&toml, "\n[import]")
	fmt.sbprintfln(&toml, "schema = %s", quote(SCHEMA_VERSION))
	fmt.sbprint(&toml, "inputs = [")
	for input, i in inputs {
		absolute, _ := os.get_absolute_path(input, context.temp_allocator)
		fmt.sbprintf(&toml, "%s%s", i > 0 ? ", " : "", quote(absolute))
	}
	fmt.sbprintln(&toml, "]")
	files := [?]struct {name, text: string}{
		{"pack.toml", strings.to_string(toml)},
		{titlepack.FRONT, STOCK_FRONT},
		{"gameplay.wasm", GAMEPLAY_MODULE},
		{"gamerender.wasm", GAMERENDER_MODULE},
		{"app.wasm", APP_MODULE},
		{"fonts/michroma.ttf", DISPLAY_FONT},
		{"fonts/michroma-ofl.txt", DISPLAY_FONT_LICENSE},
	}
	if !make_dir(join(stage, "fonts")) do return "cannot create fonts"
	for f in files {
		if os.write_entire_file(join(stage, f.name), f.text) != nil do return fmt.aprintf("cannot write %s", f.name)
	}
	return ""
}

// A TOML basic string.
quote :: proc(s: string) -> string {
	escaped, _ := strings.replace_all(s, "\\", "\\\\", context.temp_allocator)
	escaped, _ = strings.replace_all(escaped, "\"", "\\\"", context.temp_allocator)
	return fmt.tprintf("\"%s\"", escaped)
}
