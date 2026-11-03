package tk5_importer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "../../titlepack"

PACK_ID :: "tekken5dr"
STOCK_PACK :: PACK_ID + ".tar"
TITLE :: "Tekken 5: Dark Resurrection"

// The stock modules build.sh made from modules/tk5, so an import writes this openwavu's own.
// (hole stock-modules :tags (importer tk5mod) :needs mod-scene) the stock pack's gamerender.wasm is an empty module.
GAMEPLAY_MODULE :: #load("../../../build/modules/gameplay.wasm", string)
APP_MODULE :: #load("../../../build/modules/app.wasm", string)
EMPTY_MODULE :: "\x00asm\x01\x00\x00\x00"
STOCK_FRONT :: #load("../../../modules/tk5/front.owf", string)

// The game's stock title pack: packs_dir/tekken5dr.tar. inputs are recorded so an openwavu update can rebuild it.
// The unpacked files stay in packs_dir/tekken5dr/ when keep is set.
build_pack :: proc(inputs: []string, packs_dir: string, keep := false, progress: ^Progress = nil) -> (err: string) {
	if progress != nil do sync.atomic_store(&progress.total, PROGRESS_STEPS)
	if !make_dir(packs_dir) do return fmt.aprintf("cannot create %s", packs_dir)
	scratch := strings.clone(join(packs_dir, PACK_ID + ".source"))  // an unpacked .pkg
	defer delete(scratch)
	os.remove_all(scratch)
	defer os.remove_all(scratch)
	game: Game
	if game, err = find_game(inputs, scratch); err != "" do return
	defer destroy_game(game)
	stage := strings.clone(join(packs_dir, PACK_ID))  // run frees temp memory
	defer delete(stage)
	os.remove_all(stage)
	defer if !keep do os.remove_all(stage)
	if err = run(game, stage, progress); err != "" do return
	if err = write_pack_files(stage, inputs); err != "" do return
	err = titlepack.write_tar(stage, join(packs_dir, STOCK_PACK))
	if progress != nil do sync.atomic_add(&progress.done, 1)
	return
}

// pack.toml, the front and the modules: the files a pack needs at its root.
write_pack_files :: proc(stage: string, inputs: []string) -> (err: string) {
	toml := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&toml, "id = %s", quote(PACK_ID))
	fmt.sbprintfln(&toml, "name = %s", quote(TITLE))
	fmt.sbprintfln(&toml, "version = %s", quote(IMPORTER_VERSION))
	fmt.sbprintln(&toml, "main = \"app.wasm\"")
	fmt.sbprintln(&toml, "\n[modes.versus]\nsim = \"gameplay.wasm\"\npresenter = \"gamerender.wasm\"")
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
		{"gamerender.wasm", EMPTY_MODULE},
		{"app.wasm", APP_MODULE},
	}
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
