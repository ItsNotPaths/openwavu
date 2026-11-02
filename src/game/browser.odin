package game

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import clay "../../vendor/clay"
import "../ui"

// Picks what the importer takes: an RPCS3 folder, or a game folder and optionally a .rap file.
// dir "" is the list of filesystem roots (drive letters on Windows).
Browser :: struct {
	opened:  bool,
	dir:     string,
	entries: []os.File_Info,  // folders first, then .rap files
	picked:  [dynamic]string,
	is_game: bool,  // dir holds PARAM.SFO or dev_hdd0
	next:    Maybe(string),  // opened next frame; Clay still points at this frame's names
}

browser_open :: proc(b: ^Browser, dir: string) {
	browser_close(b)
	b.opened = true
	b.dir = strings.clone(dir)
	entries := make([dynamic]os.File_Info)
	if dir == "" {
		for root in roots(context.temp_allocator) {
			append(&entries, os.File_Info{fullpath = strings.clone(root), name = strings.clone(root), type = .Directory})
		}
		b.entries = entries[:]
		b.is_game = false
		return
	}
	all, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
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
	if next, ok := b.next.?; ok {
		delete(next)
	}
}

// True when Import is pressed; the picked paths are the importer's inputs.
browser :: proc(b: ^Browser, u: ^ui.Ui) -> (import_picked: bool) {
	if !b.opened {
		home, _ := os.user_home_dir(context.temp_allocator)
		browser_open(b, home)
	}
	if next, ok := b.next.?; ok {
		browser_open(b, next)
		delete(next)
		b.next = nil
	}
	if clay.UI()({layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}, childGap = 8, layoutDirection = .TopToBottom}}) {
		if clay.UI()(ui.row(8)) {
			ui.label(b.dir == "" ? "Drives" : b.dir, tint = ui.TEXT_DIM)
			ui.spacer()
			if b.is_game {
				ui.label("Looks like a game folder", tint = ui.LED)
			}
			if b.dir != "" && ui.button(u, clay.ID("UseFolder"), "Use this folder") {
				pick(b, b.dir)
			}
		}
		if clay.UI()(ui.scroll(clay.ID("Files"))) {
			if parent, ok := up(b.dir); ok && ui.list_row(u, clay.ID("Up"), "../", false) {
				b.next = strings.clone(parent)
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
				import_picked = ui.button(u, clay.ID("Import"), "Import")
			}
		}
	}
	return
}

// The folder above dir. Above a root is the root list, shown only when there are several roots.
up :: proc(dir: string) -> (parent: string, ok: bool) {
	if dir == "" {
		return "", false
	}
	all := roots(context.temp_allocator)
	if slice.contains(all, dir) {
		return "", len(all) > 1
	}
	return filepath.dir(dir), true
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

@(private = "file")
join :: proc(a, b: string) -> string {
	path, _ := filepath.join({a, b}, context.temp_allocator)
	return path
}
