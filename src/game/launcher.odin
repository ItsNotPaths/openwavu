package game

import "core:fmt"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"
import "../render"
import "../titlepack"
import "../ui"

Launcher :: struct {
	packs:     []titlepack.Title_Pack,
	picked:    Maybe(int),
	bar_shown: f32,
	quit:      bool,
}

launcher :: proc(l: ^Launcher, u: ^ui.Ui, r: ^render.Renderer) {
	if clay.UI()({id = clay.ID("Root"), layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}}}) {
		pack_grid(l, u)
		top_bar(l, u, r)
	}
}

// Slides in when the mouse is near the top edge.
top_bar :: proc(l: ^Launcher, u: ^ui.Ui, r: ^render.Renderer) {
	near := !u.input.pad && u.input.mouse.y < ui.BAR_HEIGHT * 1.5
	ui.approach(&l.bar_shown, near ? 1 : 0, 12, u.dt)
	if clay.UI()({
		id = clay.ID("TopBar"),
		layout = {
			sizing = {clay.SizingFixed(u.size.x), clay.SizingFixed(ui.BAR_HEIGHT)},
			padding = {16, 4, 0, 0},
			childAlignment = {.Left, .Center},
		},
		backgroundColor = ui.BAR_FILL,
		floating = {attachTo = .Root, offset = {0, (l.bar_shown - 1) * ui.BAR_HEIGHT}, zIndex = 1},
	}) {
		ui.label(VERSION, color = ui.TEXT_DIM)
		if clay.UI()({floating = {attachTo = .Parent, attachment = {.CenterCenter, .CenterCenter}}}) {
			ui.label(clock())
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

// Installed packs as square tiles, wrapped into rows, then the install tile.
pack_grid :: proc(l: ^Launcher, u: ^ui.Ui) {
	columns := max(1, int((u.size.x - 2 * ui.PAGE_PAD + ui.TILE_GAP) / (ui.TILE_SIZE + ui.TILE_GAP)))
	count := len(l.packs) + 1
	if clay.UI()(ui.scroll(clay.ID("Packs"), ui.PAGE_PAD, ui.TILE_GAP)) {
		for first := 0; first < count; first += columns {
			if clay.UI()(ui.row(ui.TILE_GAP)) {
				for i in first ..< min(first + columns, count) {
					if i == len(l.packs) {
						if ui.tile(u, clay.ID("Install"), "+ Install") {
							install_pack()
						}
					} else if ui.tile(u, clay.ID("Pack", u32(i)), l.packs[i].id) {
						l.picked = i
					}
				}
			}
		}
	}
}

// (hole titlepack-install :tags (titlepack game) :needs titlepack-format) the install tile does nothing: no file picker, no verify, no copy into the packs folder.
install_pack :: proc() {}

clock :: proc() -> string {
	now: sdl.Time
	date: sdl.DateTime
	_ = sdl.GetCurrentTime(&now)
	_ = sdl.TimeToDateTime(now, &date, true)
	return fmt.tprintf("%04d-%02d-%02d  %02d:%02d", date.year, date.month, date.day, date.hour, date.minute)
}
