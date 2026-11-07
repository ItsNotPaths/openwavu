package game

import "core:fmt"
import "core:math"
import "core:strings"
import clay "../../vendor/clay"
import "../ui"

// The screen-bottom popup: openwavu's own, the top bar's counterpart. Packs only open its fixed modes.
// (hole store-versions :tags (game net)) an installed pack's install popup shows only its installed version; no update or older versions from the network's /versions (a store pick lists them).
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
	file:       string,
	frame_cap:  int,
	music_volume, effects_volume: int,  // percent
	favourites: [dynamic]string,  // tile names
	name:       strings.Builder,  // the player's name online; free text
	network:    string,  // the files host's name, or a full URL
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

// (hole identity-export :tags (game net)) no export or import of identity.key in the settings.
// (hole submit-line :tags (game net)) no submit line: typed text is not signed and sent to the network's /note.
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
		if step != 0 {
			l.settings.frame_cap = caps[at + step]
			settings_save(l.settings)
		}
	}
	volume_row(u, "Music", &l.settings.music_volume, &l.settings)
	volume_row(u, "Effects", &l.settings.effects_volume, &l.settings)
	if clay.UI()(ui.row(8)) {
		ui.label("Name", tint = ui.TEXT_DIM)
		ui.spacer()
		before := strings.clone(strings.to_string(l.settings.name), context.temp_allocator)
		settings_field(u, clay.ID("Name"), &l.settings.name, "Player")
		if strings.to_string(l.settings.name) != before do settings_save(l.settings)
	}
	if clay.UI()(ui.row(8)) {
		ui.label("Network", tint = ui.TEXT_DIM)
		ui.spacer()
		if settings_field(u, clay.ID("Network"), &l.network_edit, DEFAULT_NETWORK) do l.change = Switch_Network{}
	}
	if l.settings.network != DEFAULT_NETWORK {
		ui.label(fmt.tprintf("Packs here are approved by %s, not %s.", l.settings.network, DEFAULT_NETWORK), tint = ui.WARN)
	}
	if l.identity_err != "" do ui.label(l.identity_err, tint = ui.WARN)
}

SETTINGS_FIELD_WIDTH :: 360

// A volume setting, saved when it moves. Packs take it when they start.
@(private = "file")
volume_row :: proc(u: ^ui.Ui, name: string, percent: ^int, settings: ^Settings) {
	if clay.UI()(ui.row(8)) {
		ui.label(name, tint = ui.TEXT_DIM)
		ui.spacer()
		moved := int(math.round(ui.slider(u, clay.ID(name), f32(percent^) / 100) * 100))
		if moved != percent^ {
			percent^ = moved
			settings_save(settings^)
		}
	}
}

// A text field of one width for every settings row.
@(private = "file")
settings_field :: proc(u: ^ui.Ui, id: clay.ElementId, text: ^strings.Builder, placeholder: string) -> (submitted: bool) {
	if clay.UI()({layout = {sizing = {width = clay.SizingFixed(SETTINGS_FIELD_WIDTH)}}}) {
		submitted = ui.field(u, id, text, placeholder)
	}
	return
}

@(private = "file")
install_popup :: proc(l: ^Launcher, u: ^ui.Ui) {
	if store_pick, is_store := l.selected.(Store_Pick); is_store {
		store_install_popup(l, u, store_pick)
		return
	}
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
