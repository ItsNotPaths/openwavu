// openwavu: the game.
package game

import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import "../input"
import "../render"
import "../titlepack"
import "../ui"

VERSION :: "openwavu 0.0.0-dev"

// (hole app-shell :tags game) no ROM import, join path for lobby links, or system overlay (controls, video, audio, leave pack).
main :: proc() {
	if len(os.args) == 3 && os.args[1] == "--package" {
		os.exit(package_folder(os.args[2]))
	}
	data, config, has_folders := user_folders()
	if !has_folders {
		fmt.eprintln("openwavu: no user data folder:", sdl.GetError())
		os.exit(1)
	}
	defer delete(data)
	defer delete(config)
	titlepack.packs_dir = strings.concatenate({data, "/packs"})
	defer delete(titlepack.packs_dir)
	os.make_directory_all(titlepack.packs_dir)
	r, ok := render.init("openwavu", 1280, 720)
	if !ok {
		fmt.eprintln("openwavu:", sdl.GetError())
		os.exit(1)
	}
	defer render.destroy(&r)
	if !sdl.InitSubSystem({.AUDIO}) do fmt.eprintln("openwavu: no sound:", sdl.GetError())  // packs' streams then fail to open
	u: ui.Ui
	if !ui.init(&u, r.renderer_2d, render.size(&r)) {
		fmt.eprintln("openwavu:", sdl.GetError())
		os.exit(1)
	}
	defer ui.destroy(&u)
	// (hole stock-rebuild :tags (game importer)) the stock pack is not rebuilt when its pack.toml version differs from this openwavu's importer; the [import] inputs are recorded for it.
	l := Launcher{packs = titlepack.installed(), settings = settings_load(config)}
	if len(os.args) >= 3 && os.args[1] == "--front" {
		l.selected = Front_Preview{os.args[2], len(os.args) > 3 ? os.args[3] : ""}
	}
	// (hole close-segfault :tags game :sev polish) the -o:speed build segfaulted once on close after an everything_launches 0.0.5 match (2026-11-06); a -debug -sanitize:address build did not repeat it.
	defer launcher_destroy(&l)

	last := sdl.GetTicksNS()
	for !l.quit {
		defer free_all(context.temp_allocator)
		e: sdl.Event
		for sdl.PollEvent(&e) {
			sdl.ConvertEventToRenderCoordinates(r.renderer_2d, &e)
			if e.type == .QUIT do l.quit = true
			input.handle_event(e)
			ui.handle_event(&u, e)
		}
		now := sdl.GetTicksNS()
		dt := f32(now - last) / 1e9
		last = now

		ui.begin(&u, render.size(&r), dt)
		launcher(&l, &u, &r)
		commands := ui.end(&u)
		render.begin_frame(&r, ui.color(ui.BACKGROUND))
		ui.draw(&u, commands)
		render.end_frame(&r)
		pace(now, l.settings.frame_cap)

		if pack, picked := l.play.?; picked {
			l.play = nil
			l.quit = play(&r, l.packs[pack], l.settings.frame_cap)
		}
	}
}

// Waits out the rest of a frame that started at frame_start (SDL ticks), for frame_cap frames a second.
pace :: proc(frame_start: u64, frame_cap: int) {
	budget := u64(1e9) / u64(frame_cap)
	if spent := sdl.GetTicksNS() - frame_start; spent < budget do sdl.DelayPrecise(budget - spent)
}

// --package <folder>: the folder as <folder>.tar, once its pack.toml reads.
package_folder :: proc(path: string) -> (exit_code: int) {
	dir := strings.trim_right(path, "/\\")
	manifest, read_err := os.read_entire_file(fmt.tprintf("%s/%s", dir, titlepack.MANIFEST), context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("openwavu: no %s in %s", titlepack.MANIFEST, dir)
		return 1
	}
	tp, ok := titlepack.read_titlepack(string(manifest), context.temp_allocator)
	if !ok {
		fmt.eprintfln("openwavu: %s needs a string id and version", titlepack.MANIFEST)
		return 1
	}
	out := fmt.tprintf("%s.tar", dir)
	if err := titlepack.write_tar(dir, out); err != "" {
		fmt.eprintln("openwavu:", err)
		return 1
	}
	fmt.printfln("%s %s -> %s", tp.id, tp.version, out)
	return 0
}
