package game

import "core:fmt"
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
	},
	source:   Install_Source,
	browser:  Browser,
	importer: Import_Job,
	url:      strings.Builder,
	search_installed, search_store: strings.Builder,
	play:     Maybe(int),
	quit:     bool,
}

Install_Screen :: struct {}

launcher_destroy :: proc(l: ^Launcher) {
	titlepack.destroy_installed(l.packs)
	browser_destroy(&l.browser)
	import_destroy(&l.importer)
	strings.builder_destroy(&l.url)
	strings.builder_destroy(&l.search_installed)
	strings.builder_destroy(&l.search_store)
}

Install_Source :: enum u8 {
	None,
	Game_Files,
	Url,
}

// Installed packs left, the store right, whatever is selected in the middle; columns have no panel.
// (hole launcher-backdrop :tags game :needs pack-front) the spotlight always shows; a picked pack's front backgrounds should replace it.
launcher :: proc(l: ^Launcher, u: ^ui.Ui, r: ^render.Renderer) {
	if clay.UI()({
		id = clay.ID("Root"),
		layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}},
		custom = ui.painted(ui.Spotlight{}),
	}) {
		installed_column(l, u)
		center(l, u)
		store_column(l, u)
		top_bar(l, u, r)
	}
}

installed_column :: proc(l: ^Launcher, u: ^ui.Ui) {
	if clay.UI()(side_column()) {
		column_head(u, "INSTALLED", clay.ID("SearchInstalled"), &l.search_installed)
		if clay.UI()(slot_list(clay.ID("InstalledList"))) {
			for pack, i in l.packs {
				if !matches(pack.id, strings.to_string(l.search_installed)) {
					continue
				}
				picked, is_pack := l.selected.(int)
				if ui.slot(u, clay.ID("Pack", u32(i)), pack.id, nil, is_pack && picked == i) {
					l.selected = i
				}
			}
			_, installing := l.selected.(Install_Screen)
			if ui.add_slot(u, clay.ID("Add"), installing) {
				l.selected = Install_Screen{}
			}
		}
	}
}

// (hole store-list :tags (game net) :needs registry-verify) the store column lists nothing; no pack listing from the master server.
store_column :: proc(l: ^Launcher, u: ^ui.Ui) {
	if clay.UI()(side_column()) {
		column_head(u, "STORE", clay.ID("SearchStore"), &l.search_store)
		if clay.UI()(slot_list(clay.ID("StoreList"))) {}
	}
}

center :: proc(l: ^Launcher, u: ^ui.Ui) {
	if clay.UI()({id = clay.ID("Center"), layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}}}) {
		switch pick in l.selected {
		case Install_Screen:
			install_screen(l, u)
		case int:
			pack_page(l, u, pick)
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

// (hole pack-front :tags (game titlepack)) a picked pack shows only its name and Play: its front.txt is not read or drawn.
pack_page :: proc(l: ^Launcher, u: ^ui.Ui, pack: int) {
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}, childGap = 10, childAlignment = {.Center, .Center}, layoutDirection = .TopToBottom},
	}) {
		ui.label(l.packs[pack].id, 26, engraved = true, face = .Display)
		if ui.button(u, clay.ID("Play"), "Play") {
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
		// (hole launcher-settings :tags game :sev gap) the settings button opens nothing.
		ui.button(u, clay.ID("Settings"), "Settings", ui.BAR_BUTTON, nav = false)
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

slot_list :: proc(id: clay.ElementId) -> clay.ElementDeclaration {
	return ui.scroll(id, {16, 16, 6, 24}, ui.SLOT_GAP)
}

// Case-blind substring match; an empty search matches everything.
matches :: proc(name, search: string) -> bool {
	return strings.contains(strings.to_lower(name, context.temp_allocator), strings.to_lower(search, context.temp_allocator))
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
