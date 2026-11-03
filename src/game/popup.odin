package game

import "core:fmt"
import clay "../../vendor/clay"
import "../ui"

// The screen-bottom popup: openwavu's own, the top bar's counterpart. Packs only open its fixed modes.
// (hole settings-save :tags game :sev polish) settings live only until openwavu closes.
// (hole store-versions :tags (game net) :needs store-list) install shows only the installed version; no older versions from the master server.
Popup :: struct {
	mode: Popup_Mode,
	open: bool,
}

Popup_Mode :: enum u8 {
	Settings,
	Install,
	Credits,
	Uninstall,
}

Settings :: struct {
	frame_cap: int,
}

// The sim steps at 60; a higher cap draws frames in between.
FRAME_CAPS :: [?]int{60, 90, 120, 144, 165, 240}
POPUP_WIDTH :: 720
POPUP_SLIDE :: 400  // more than the popup is tall

// Slides up from the bottom edge while open and back down when closed. True when the player confirmed removing the pack.
popup :: proc(l: ^Launcher, u: ^ui.Ui) -> (remove: bool) {
	id := clay.ID("Popup")
	shown := ui.ease(u, id, l.popup.open ? 1 : 0, ui.BAR_RATE)
	if shown < 0.01 do return
	if clay.UI()({
		id = id,
		layout = {sizing = {width = clay.SizingFixed(POPUP_WIDTH)}, padding = {26, 26, 22, 26}, childGap = 14, layoutDirection = .TopToBottom},
		custom = ui.painted(ui.Tray{}),
		floating = {attachTo = .Root, attachment = {element = .CenterBottom, parent = .CenterBottom}, offset = {0, (1 - shown) * POPUP_SLIDE}, zIndex = 2},
	}) {
		switch l.popup.mode {
		case .Settings: settings_popup(l, u)
		case .Install: install_popup(l, u)
		case .Credits: credits_popup(l)
		case .Uninstall: remove = uninstall_popup(l, u)
		}
	}
	return
}

@(private = "file")
settings_popup :: proc(l: ^Launcher, u: ^ui.Ui) {
	ui.label("Settings", ui.HEAD_SIZE, engraved = true, face = .Display)
	if clay.UI()(ui.row(8)) {
		ui.label("Frame cap", tint = ui.TEXT_DIM)
		ui.spacer()
		caps := FRAME_CAPS
		at := 0
		for cap, i in caps do if cap == l.settings.frame_cap do at = i
		step := ui.stepper(u, clay.ID("FrameCap"), fmt.tprintf("%d fps", caps[at]), at > 0, at < len(caps) - 1)
		l.settings.frame_cap = caps[at + step]
	}
}

@(private = "file")
install_popup :: proc(l: ^Launcher, u: ^ui.Ui) {
	pick, is_pack := l.selected.(int)
	if !is_pack {
		ui.label("Install", ui.HEAD_SIZE, engraved = true, face = .Display)
		ui.label("A preview has nothing to install.", tint = ui.TEXT_DIM)
		return
	}
	pack := l.packs[pick]
	ui.label(fmt.tprintf("Install %s", pack.name), ui.HEAD_SIZE, engraved = true, face = .Display)
	if clay.UI()(ui.row(8)) {
		ui.label(fmt.tprintf("Latest  %s", pack.version))
		ui.spacer()
		ui.button(u, clay.ID("InstallLatest"), "Installed", ui.OFF_BUTTON)
	}
}

@(private = "file")
credits_popup :: proc(l: ^Launcher) {
	ui.label("Credits", ui.HEAD_SIZE, engraved = true, face = .Display)
	if len(l.front.front.credits) == 0 do ui.label("This pack lists no credits.", tint = ui.TEXT_DIM)
	for line in l.front.front.credits do ui.label(line)
}

@(private = "file")
uninstall_popup :: proc(l: ^Launcher, u: ^ui.Ui) -> (remove: bool) {
	pick, is_pack := l.selected.(int)
	if !is_pack do return
	pack := l.packs[pick]
	ui.label(fmt.tprintf("Remove %s?", pack.name), ui.HEAD_SIZE, engraved = true, face = .Display)
	ui.label(fmt.tprintf("This deletes %s.", pack.path), tint = ui.TEXT_DIM)
	if clay.UI()(ui.row(8)) {
		ui.spacer()
		if ui.button(u, clay.ID("CancelRemove"), "Cancel") do l.popup.open = false
		remove = ui.button(u, clay.ID("Remove"), "Remove")
	}
	return
}
