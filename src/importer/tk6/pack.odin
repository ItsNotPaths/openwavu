// openwavu-import for Tekken 6 (PS3 disc): the game folder -> the stock title pack packs/tekken6/.
package tk6_importer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "../../release"
import "../../titlepack"
import tk5_importer "../tk5"

PACK_ID :: "tekken6"
STOCK_PACK :: PACK_ID  // a folder, as the TK5 stock pack
PSARC :: "TEKKEN.psarc"

// The stock modules build.sh made from modules/tk6, so an import writes this openwavu's own.
GAMEPLAY_MODULE :: #load("../../../build/modules/tk6/gameplay.wasm", string)
GAMERENDER_MODULE :: #load("../../../build/modules/tk6/gamerender.wasm", string)
APP_MODULE :: #load("../../../build/modules/tk6/app.wasm", string)
STOCK_FRONT :: #load("../../../modules/tk6/front.owf", string)
STOCK_MANIFEST :: #load("../../../modules/tk6/pack.toml", string)  // without version and [import], which an import adds

// The USRDIR of a TK6 game folder among inputs: the disc root, PS3_GAME or USRDIR itself; "" for none.
find_usrdir :: proc(inputs: []string) -> string {
	for input in inputs {
		for usrdir in ([]string{input, join(input, "USRDIR"), join(input, "PS3_GAME", "USRDIR")}) {
			if os.exists(join(usrdir, PSARC)) do return usrdir
		}
	}
	return ""
}

// The folder packs_dir/tekken6/, built beside it and renamed in when whole, then its hash file.
build_pack :: proc(inputs: []string, packs_dir: string, progress: ^Progress = nil) -> (err: string) {
	if progress != nil do sync.atomic_store(&progress.total, PROGRESS_STEPS)
	usrdir := find_usrdir(inputs)
	if usrdir == "" do return "no Tekken 6 game folder (one with PS3_GAME/USRDIR/TEKKEN.psarc)"
	usrdir = strings.clone(usrdir)  // run frees temp memory
	defer delete(usrdir)
	packs := strings.clone(packs_dir)
	defer delete(packs)
	if !make_dir(packs) do return fmt.aprintf("cannot create %s", packs)
	stage := strings.clone(join(packs, PACK_ID + ".part"))
	defer delete(stage)
	os.remove_all(stage)
	defer os.remove_all(stage)
	if err = run(usrdir, stage, progress); err != "" do return
	if err = write_pack_files(stage, inputs); err != "" do return
	digest, hash_err := titlepack.folder_hash(stage)
	if hash_err != "" do return strings.clone(hash_err)
	pack := join(packs, STOCK_PACK)
	os.remove(titlepack.folder_hash_path(pack))
	os.remove_all(pack)
	if os.rename(stage, pack) != nil do return fmt.aprintf("cannot move the pack into %s", pack)
	if hash_err = titlepack.write_folder_hash(pack, digest); hash_err != "" do return strings.clone(hash_err)
	return
}

// pack.toml, the front, the modules and the disc's title art: the files a pack needs at its root.
write_pack_files :: proc(stage: string, inputs: []string) -> (err: string) {
	toml := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&toml, "version = %s", tk5_importer.quote(release.current()))
	fmt.sbprint(&toml, STOCK_MANIFEST)
	fmt.sbprintln(&toml, "\n[import]")
	fmt.sbprintfln(&toml, "schema = %s", tk5_importer.quote(SCHEMA_VERSION))
	fmt.sbprint(&toml, "inputs = [")
	for input, index in inputs {
		absolute, _ := os.get_absolute_path(input, context.temp_allocator)
		fmt.sbprintf(&toml, "%s%s", index > 0 ? ", " : "", tk5_importer.quote(absolute))
	}
	fmt.sbprintln(&toml, "]")
	files := [?]struct {name, text: string}{
		{"pack.toml", strings.to_string(toml)},
		{titlepack.FRONT, STOCK_FRONT},
		{"gameplay.wasm", GAMEPLAY_MODULE},
		{"gamerender.wasm", GAMERENDER_MODULE},
		{"app.wasm", APP_MODULE},
	}
	if !make_dir(join(stage, "ui")) do return fmt.aprintf("cannot create ui")
	for file in files {
		if os.write_entire_file(join(stage, file.name), file.text) != nil do return fmt.aprintf("cannot write %s", file.name)
	}
	usrdir := find_usrdir(inputs)
	for art in ([]string{"icon0", "pic0", "pic1"}) {
		data, read := os.read_entire_file(join(usrdir, "..", fmt.tprintf("%s.PNG", strings.to_upper(art, context.temp_allocator))), context.temp_allocator)
		file := fmt.tprintf("ui/%s.png", art)
		if read == nil && os.write_entire_file(join(stage, file), data) != nil do return fmt.aprintf("cannot write %s", file)
	}
	return ""
}
