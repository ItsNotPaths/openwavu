package game

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"
import "../render"
import "../titlepack"
import "../ui"

Launcher :: struct {
	packs:    []titlepack.Title_Pack,
	selected: union {
		Install_Screen,
		int,  // an installed pack
		Front_Preview,
		Store_Pick,
	},
	front:    Front_View,
	popup:    Popup,
	settings: Settings,
	source:   Install_Source,
	browser:  Browser,
	importer: Import_Job,
	store:    Store,
	thumbs:   map[string]^sdl.Texture,  // slot art: installed by path@version, the store's by hash
	url:      strings.Builder,
	search_installed, search_store: strings.Builder,
	play:     Maybe(int),
	change:   Change,
	quit:     bool,
}

// A click that frees strings waits for the next frame: Clay reads them until the frame is drawn.
Change :: union {
	Lock_Tile,
	Remove_Picked,
	Install_Version,
}

Lock_Tile :: distinct int  // index into packs
Remove_Picked :: struct {}
Install_Version :: distinct int  // index into the store's versions

Install_Screen :: struct {}

// --front <tar or folder> [front file]: just that front, for creators. It reopens when its source changes.
Front_Preview :: struct {
	path, file: string,
}

launcher_destroy :: proc(l: ^Launcher) {
	titlepack.destroy_installed(l.packs)
	front_close(&l.front)
	browser_destroy(&l.browser)
	import_destroy(&l.importer)
	store_destroy(&l.store)
	for key, texture in l.thumbs {
		if texture != nil do sdl.DestroyTexture(texture)
		delete(key)
	}
	delete(l.thumbs)
	strings.builder_destroy(&l.url)
	strings.builder_destroy(&l.search_installed)
	strings.builder_destroy(&l.search_store)
	settings_destroy(&l.settings)
}

Install_Source :: enum u8 {
	None,
	Game_Files,
	Url,
}

// Installed packs left, the store right, whatever is selected in the middle; columns have no panel.
// A front replaces the spotlight with its own backgrounds.
launcher :: proc(l: ^Launcher, u: ^ui.Ui, r: ^render.Renderer) {
	switch change in l.change {
	case Lock_Tile: toggle_lock(l, l.packs[change])
	case Remove_Picked: remove_pack(l)
	case Install_Version: install_start(&l.store.install, l.store.versions.packs, int(change))
	}
	l.change = nil
	store_poll(l)
	path, file := "", ""
	switch pick in l.selected {
	case int: path = l.packs[pick].path
	case Front_Preview:
		path, file = pick.path, pick.file
		if front_changed(path, file) != l.front.changed do front_close(&l.front)
	case Store_Pick: path = store_front(l, pick)
	case Install_Screen:
	}
	if path != "" && path != l.front.path do front_open(&l.front, u, path, file)
	showing_front := path != "" && l.front.err == ""
	clicked_away := u.input.mouse_pressed && !clay.PointerOver(clay.ID("Popup")) && !clay.PointerOver(clay.ID("Settings"))  // Settings toggles it itself
	if l.popup.open && (u.input.back || clicked_away) {
		l.popup.open = false
	}
	if clay.UI()({
		id = clay.ID("Root"),
		layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}},
		custom = showing_front ? {} : ui.painted(ui.Spotlight{}),
	}) {
		installed_column(l, u)
		center(l, u)
		store_column(l, u)
		top_bar(l, u, r)
		if popup(l, u) do l.change = Remove_Picked{}
	}
}

installed_column :: proc(l: ^Launcher, u: ^ui.Ui) {
	if clay.UI()(side_column()) {
		column_head(u, "INSTALLED", clay.ID("SearchInstalled"), &l.search_installed)
		if clay.UI()(slot_list(u, clay.ID("InstalledList"))) {
			clicked, clicked_pack := ui.Slot_Click.None, 0  // applied after the list: a star moves its slot
			for favourites in ([2]bool{true, false}) {
				for pack, i in l.packs {
					tile := filepath.stem(pack.path)
					if slice.contains(l.settings.favourites[:], tile) != favourites || !matches(pack.id, strings.to_string(l.search_installed)) {
						continue
					}
					picked, is_pack := l.selected.(int)
					lock: Maybe(bool) = strings.has_suffix(pack.path, ".tar") ? pack.locked : nil  // stock folders do not lock
					if click := ui.installed_slot(u, clay.ID("Pack", u32(i)), tile, installed_thumb(l, u, pack), is_pack && picked == i, favourites, lock); click != .None {
						clicked, clicked_pack = click, i
					}
				}
			}
			_, installing := l.selected.(Install_Screen)
			if ui.add_slot(u, clay.ID("Add"), installing) {
				l.selected = Install_Screen{}
			}
			switch clicked {
			case .None:
			case .Slot: l.selected = clicked_pack
			case .Star: toggle_favourite(&l.settings, filepath.stem(l.packs[clicked_pack].path))
			case .Lock: l.change = Lock_Tile(clicked_pack)
			}
		}
	}
}

center :: proc(l: ^Launcher, u: ^ui.Ui) {
	if clay.UI()({id = clay.ID("Center"), layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}}}) {
		switch pick in l.selected {
		case Install_Screen:
			install_screen(l, u)
		case int:
			pack_page(l, u, l.packs[pick].name, pick)
		case Front_Preview:
			pack_page(l, u, pick.path, nil)
		case Store_Pick:
			pack_page(l, u, l.store.listing.packs[pick.index].id, nil)
		}
	}
}

install_screen :: proc(l: ^Launcher, u: ^ui.Ui) {
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}, padding = {48, 48, 40, 40}, childGap = 20, layoutDirection = .TopToBottom},
	}) {
		ui.label("Install a pack", ui.TITLE_SIZE, engraved = true, face = .Display)
		if clay.UI()(ui.row(18, {.Left, .Top})) {
			if ui.card(u, clay.ID("FromGameFiles"), "Game files", "Build packs from your own TK5 import. Needs the game files on disk.", l.source == .Game_Files) {
				l.source = .Game_Files
			}
			if ui.card(u, clay.ID("FromUrl"), "URL", "A direct pack.tar link. Not reviewed. Offline play only.", l.source == .Url) {
				l.source = .Url
			}
		}
		switch l.source {
		case .None:
		case .Game_Files:
			if l.importer.thread != nil {
				import_status(l, u)
			} else if browser(&l.browser, u) {
				import_start(&l.importer, l.browser.picked[:])
			}
		case .Url:
			if clay.UI()(ui.row(8)) {
				submitted := ui.field(u, clay.ID("Url"), &l.url, "https://.../pack.tar")
				if ui.button(u, clay.ID("Download"), "Download") || submitted {
					install_pack()
				}
			}
			ui.label("URL packs run code nobody reviewed. They never show a front and can't join online play.", tint = ui.WARN)
		}
	}
}

// The pack's front; without one (or with one that does not read) its name, Play and why.
pack_page :: proc(l: ^Launcher, u: ^ui.Ui, name: string, pack: Maybe(int)) {
	if l.front.err == "" {
		action, target := front_page(&l.front, u, pack != nil)
		switch action {
		case .Play: l.play = pack
		case .Url: _ = sdl.OpenURL(strings.clone_to_cstring(target, context.temp_allocator))
		case .Install: l.popup = {.Install, true}
		case .Uninstall: l.popup = {.Uninstall, true}
		case .Credits: l.popup = {.Credits, true}
		case .None, .Toggle:
		}
		return
	}
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}, childGap = 10, childAlignment = {.Center, .Center}, layoutDirection = .TopToBottom},
	}) {
		ui.label(name, 26, engraved = true, face = .Display)
		ui.label(l.front.err, tint = ui.TEXT_DIM)
		if pack != nil && ui.button(u, clay.ID("Play"), "Play") {
			l.play = pack
		}
	}
}

// Slides in when the mouse is near the top edge.
top_bar :: proc(l: ^Launcher, u: ^ui.Ui, r: ^render.Renderer) {
	id := clay.ID("TopBar")
	near := !u.input.pad && u.input.mouse.y < ui.BAR_REVEAL
	shown := ui.ease(u, id, near ? 1 : 0, ui.BAR_RATE)
	if clay.UI()({
		id = id,
		layout = {
			sizing = {clay.SizingFixed(u.size.x), clay.SizingFixed(ui.BAR_HEIGHT)},
			padding = {16, 4, 0, 0},
			childGap = 4,
			childAlignment = {.Left, .Center},
		},
		custom = ui.painted(ui.Bar{}),
		floating = {attachTo = .Root, offset = {0, (shown - 1) * (ui.BAR_HEIGHT + 12)}, zIndex = 1},
	}) {
		ui.label(VERSION, tint = ui.TEXT_DIM, face = .Display)
		if clay.UI()({floating = {attachTo = .Parent, attachment = {.CenterCenter, .CenterCenter}}}) {
			ui.label(clock(), engraved = true, face = .Display)
		}
		ui.spacer()
		if ui.button(u, clay.ID("Settings"), "Settings", ui.BAR_BUTTON, nav = false) {
			l.popup = {.Settings, !(l.popup.open && l.popup.mode == .Settings)}
		}
		if ui.button(u, clay.ID("Fullscreen"), "[ ]", ui.BAR_BUTTON, nav = false) {
			render.toggle_fullscreen(r)
		}
		if ui.button(u, clay.ID("Close"), "X", ui.BAR_BUTTON, nav = false) {
			l.quit = true
		}
	}
}

side_column :: proc() -> clay.ElementDeclaration {
	return {layout = {sizing = {clay.SizingFixed(ui.COLUMN_WIDTH), clay.SizingGrow({})}, layoutDirection = .TopToBottom}}
}

column_head :: proc(u: ^ui.Ui, title: string, search: clay.ElementId, text: ^strings.Builder) {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow({})}, padding = {16, 16, 16, 12}, childGap = 8, layoutDirection = .TopToBottom}}) {
		ui.label(title, ui.COLUMN_SIZE, ui.TITLE, face = .Display)
		ui.field(u, search, text, "Search")
	}
}

slot_list :: proc(u: ^ui.Ui, id: clay.ElementId) -> clay.ElementDeclaration {
	return ui.scroll(u, id, {16, 16, 6, 24}, ui.SLOT_GAP)
}

// Case-blind substring match; an empty search matches everything.
matches :: proc(name, search: string) -> bool {
	return strings.contains(strings.to_lower(name, context.temp_allocator), strings.to_lower(search, context.temp_allocator))
}

// Deletes the picked pack's tar; its front is closed first, since it maps the file.
remove_pack :: proc(l: ^Launcher) {
	pick, is_pack := l.selected.(int)
	if !is_pack do return
	path := strings.clone(l.packs[pick].path, context.temp_allocator)
	front_close(&l.front)
	_ = os.remove_all(path)  // a tar, or a stock pack's folder
	reload_packs(l)
	l.selected = nil
	l.popup.open = false
}

reload_packs :: proc(l: ^Launcher) {
	titlepack.destroy_installed(l.packs)
	l.packs = titlepack.installed()
}

select_tile :: proc(l: ^Launcher, tile: string) {
	for pack, index in l.packs do if filepath.stem(pack.path) == tile do l.selected = index
}

// Locks or unlocks the tile; its star moves with it. Its front is closed first, since it maps the tar.
toggle_lock :: proc(l: ^Launcher, pack: titlepack.Title_Pack) {
	from := strings.clone(filepath.stem(pack.path), context.temp_allocator)  // reload_packs frees pack
	to := strings.clone(titlepack.tile_name(pack.id, pack.version, !pack.locked), context.temp_allocator)
	front_close(&l.front)
	if !titlepack.set_locked(pack, !pack.locked) do return
	if index, starred := slice.linear_search(l.settings.favourites[:], from); starred {
		delete(l.settings.favourites[index])
		l.settings.favourites[index] = strings.clone(to)
		settings_save(l.settings)
	}
	reload_packs(l)
	select_tile(l, to)
}

// (hole titlepack-install :tags (titlepack game)) install does nothing: no file picker, no URL download, no verify, no copy into the packs folder.
install_pack :: proc() {}

clock :: proc() -> string {
	now: sdl.Time
	date: sdl.DateTime
	_ = sdl.GetCurrentTime(&now)
	_ = sdl.TimeToDateTime(now, &date, true)
	return fmt.tprintf("%04d-%02d-%02d  %02d:%02d", date.year, date.month, date.day, date.hour, date.minute)
}
