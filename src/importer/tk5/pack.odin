package tk5_importer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "../../titlepack"

PACK_ID :: "tekken5dr"
STOCK_PACK :: PACK_ID + ".tar"
TITLE :: "Tekken 5: Dark Resurrection"

// (hole stock-modules :tags (importer tk5mod) :needs module-build) the stock pack's gameplay.wasm and app.wasm are empty modules; the ones built from modules/tk5 are not embedded in openwavu.
EMPTY_MODULE :: "\x00asm\x01\x00\x00\x00"

// The game's stock title pack: packs_dir/tekken5dr.tar. inputs are recorded so an openwavu update can rebuild it.
// The unpacked files stay in packs_dir/tekken5dr/ when keep is set.
// (hole gates-pack-root :tags (tools importer)) tk5decomp's gates (Makefile, oracle, scenario harness, test_stage.sh) read ../openwavu/content/tk5, an import from before today's schema; they need a fresh -keep import and PACK_ROOT at packs/tekken5dr.
build_pack :: proc(inputs: []string, packs_dir: string, keep := false, progress: ^Progress = nil) -> (err: string) {
	if progress != nil do sync.atomic_store(&progress.total, PROGRESS_STEPS)
	if !make_dir(packs_dir) do return fmt.aprintf("cannot create %s", packs_dir)
	game: Game
	if game, err = find_game(inputs); err != "" do return
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
// (hole stock-front :tags (importer titlepack) :needs pack-front) front.txt only names the title; no backgrounds (ui/pic1.png) or layout.
write_pack_files :: proc(stage: string, inputs: []string) -> (err: string) {
	toml := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&toml, "id = %s", quote(PACK_ID))
	fmt.sbprintfln(&toml, "name = %s", quote(TITLE))
	fmt.sbprintfln(&toml, "version = %s", quote(IMPORTER_VERSION))
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
		{"front.txt", fmt.tprintfln("title %s", TITLE)},
		{"gameplay.wasm", EMPTY_MODULE},
		{"app.wasm", EMPTY_MODULE},
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
