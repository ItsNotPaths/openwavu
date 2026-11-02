package tk5_importer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import formats "../../formats/tk5"
import "../../titlepack"

PACK_ID :: "tekken5dr"
STOCK_PACK :: PACK_ID + ".tar"
TITLE :: "Tekken 5: Dark Resurrection"

// (hole stock-modules :tags (importer tk5mod) :needs module-build) the stock pack's gameplay.wasm, gamerender.wasm and app.wasm are empty modules; the ones built from modules/tk5 are not embedded in openwavu.
EMPTY_MODULE :: "\x00asm\x01\x00\x00\x00"

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
		{titlepack.FRONT, stock_front()},
		{"gameplay.wasm", EMPTY_MODULE},
		{"gamerender.wasm", EMPTY_MODULE},
		{"app.wasm", EMPTY_MODULE},
	}
	for f in files {
		if os.write_entire_file(join(stage, f.name), f.text) != nil do return fmt.aprintf("cannot write %s", f.name)
	}
	return ""
}

// The PS3 background and logo, Play, then a grid of every fighter's select render.
stock_front :: proc() -> string {
	COLUMNS :: 8
	CELL :: [2]f32{120, 129}  // a 1008x1080 render at 120 wide
	ROSTER_Y :: 640
	fighters := make([dynamic]string, context.temp_allocator)  // each fighter's first render
	seen := make(map[string]bool, context.temp_allocator)
	for r in formats.SELECT_RENDERS do if !seen[r.fighter] {
		seen[r.fighter] = true
		append(&fighters, fmt.tprintf("%s_%s", r.fighter, r.faces_left ? "left" : "right"))
	}
	rows := (len(fighters) + COLUMNS - 1) / COLUMNS
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "// %s, built on this machine from your own game files.", TITLE)
	fmt.sbprintfln(&b, "page version=1 height=%.0f", ROSTER_Y + f32(rows) * CELL.y + 60)
	fmt.sbprintln(&b, "\nbg     ui/pic1.png y=0")
	fmt.sbprintln(&b, "image  ui/33.png x=40 y=60 w=420")
	fmt.sbprintln(&b, "image  ui/select_renders/jin_left.png x=560 y=20 w=400")
	fmt.sbprintfln(&b, "text   %q x=40 y=280 w=480 size=22", TITLE)
	fmt.sbprintln(&b, "text   \"Built on this machine from your own game files.\" x=40 y=320 w=480 size=16 color=#94969c")
	fmt.sbprintln(&b, "button play    x=40  y=400 w=220 h=56 label=\"Play\"")
	fmt.sbprintln(&b, "button install x=280 y=400 w=220 h=56 label=\"Install\"")
	fmt.sbprintfln(&b, "\nrect   x=0 y=%d w=1000 h=%.0f color=#00000080", ROSTER_Y - 20, f32(rows) * CELL.y + 40)
	for f, i in fighters {
		x, y := 20 + f32(i % COLUMNS) * CELL.x, ROSTER_Y + f32(i / COLUMNS) * CELL.y
		fmt.sbprintfln(&b, "image  ui/select_renders/%s.png x=%.0f y=%.0f w=%.0f", f, x, y, CELL.x)
	}
	return strings.to_string(b)
}

// A TOML basic string.
quote :: proc(s: string) -> string {
	escaped, _ := strings.replace_all(s, "\\", "\\\\", context.temp_allocator)
	escaped, _ = strings.replace_all(escaped, "\"", "\\\"", context.temp_allocator)
	return fmt.tprintf("\"%s\"", escaped)
}
