package game

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import clay "../../vendor/clay"
import "../ui"

// Picks what the importer takes: an RPCS3 folder, or a game folder and optionally a .rap file.
Browser :: struct {
	dir:     string,
	entries: []os.File_Info,  // folders first, then .rap files
	picked:  [dynamic]string,
	is_game: bool,  // dir holds PARAM.SFO or dev_hdd0
	next:    string,  // opened next frame; Clay still points at this frame's names
}

browser_open :: proc(b: ^Browser, dir: string) {
	browser_close(b)
	b.dir = strings.clone(dir)
	all, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	entries := make([dynamic]os.File_Info)
	for entry in all {
		if strings.has_prefix(entry.name, ".") {
			continue
		}
		if entry.type == .Directory || strings.has_suffix(strings.to_lower(entry.name, context.temp_allocator), ".rap") {
			append(&entries, os.File_Info{fullpath = strings.clone(entry.fullpath), name = strings.clone(entry.name), type = entry.type})
		}
	}
	slice.sort_by(entries[:], proc(a, b: os.File_Info) -> bool {
		if (a.type == .Directory) != (b.type == .Directory) {
			return a.type == .Directory
		}
		return a.name < b.name
	})
	b.entries = entries[:]
	b.is_game = os.exists(join(dir, "PARAM.SFO")) || os.is_dir(join(dir, "dev_hdd0"))
}

browser_close :: proc(b: ^Browser) {
	for entry in b.entries {
		delete(entry.fullpath)
		delete(entry.name)
	}
	delete(b.entries)
	delete(b.dir)
	b.entries, b.dir = nil, ""
}

browser_destroy :: proc(b: ^Browser) {
	browser_close(b)
	for path in b.picked {
		delete(path)
	}
	delete(b.picked)
	delete(b.next)
}

browser :: proc(b: ^Browser, u: ^ui.Ui) {
	if b.dir == "" {
		home, _ := os.user_home_dir(context.temp_allocator)
		browser_open(b, home)
	}
	if b.next != "" {
		browser_open(b, b.next)
		delete(b.next)
		b.next = ""
	}
	if clay.UI()({layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}, childGap = 8, layoutDirection = .TopToBottom}}) {
		if clay.UI()(ui.row(8)) {
			ui.label(b.dir, tint = ui.TEXT_DIM)
			ui.spacer()
			if b.is_game {
				ui.label("Looks like a game folder", tint = ui.LED)
			}
			if ui.button(u, clay.ID("UseFolder"), "Use this folder") {
				pick(b, b.dir)
			}
		}
		if clay.UI()(ui.scroll(clay.ID("Files"))) {
			if ui.list_row(u, clay.ID("Up"), "../", false) {
				b.next = strings.clone(filepath.dir(b.dir))
			}
			for entry, i in b.entries {
				folder := entry.type == .Directory
				name := folder ? fmt.tprintf("%s/", entry.name) : entry.name
				if ui.list_row(u, clay.ID("Entry", u32(i)), name, slice.contains(b.picked[:], entry.fullpath)) {
					if folder {
						b.next = strings.clone(entry.fullpath)
					} else {
						pick(b, entry.fullpath)
					}
				}
			}
		}
		if len(b.picked) > 0 {
			if clay.UI()(ui.row(8)) {
				ui.label(strings.join(b.picked[:], "  +  ", context.temp_allocator), tint = ui.LED)
				ui.spacer()
				if ui.button(u, clay.ID("ClearPicks"), "Clear") {
					for path in b.picked {
						delete(path)
					}
					clear(&b.picked)
				}
				if ui.button(u, clay.ID("Import"), "Import") {
					import_game(b.picked[:])
				}
			}
		}
	}
}

// Picking a picked path again unpicks it.
pick :: proc(b: ^Browser, path: string) {
	if i, found := slice.linear_search(b.picked[:], path); found {
		delete(b.picked[i])
		ordered_remove(&b.picked, i)
	} else {
		append(&b.picked, strings.clone(path))
	}
}

// (hole launcher-import :tags (game importer) :needs titlepack-synth) Import does nothing: the picked paths are not passed to the importer (tk5.find_game, tk5.run), and there is no progress screen.
import_game :: proc(paths: []string) {}

@(private = "file")
join :: proc(a, b: string) -> string {
	path, _ := filepath.join({a, b}, context.temp_allocator)
	return path
}
