package ui

import "core:fmt"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"

label :: proc(text: string, size: u16 = TEXT_SIZE, tint: u32 = TEXT, engraved := false) {
	clay.TextDynamic(text, clay.TextConfig({
		textColor = clay_color(tint),
		fontSize = size,
		userData = engraved ? &engraved_tag : nil,
	}))
}

button :: proc(ui: ^Ui, id: clay.ElementId, text: string, style := BUTTON, nav := true) -> bool {
	s := interact(ui, id, nav)
	active := s.hovered || s.focused
	if clay.UI()({
		id = id,
		layout = {sizing = {height = clay.SizingFixed(style.height)}, padding = style.padding, childAlignment = {.Center, .Center}},
		custom = painted(Steel{face = active ? style.hover : style.face, lit = active && style.hover == .Raised}),
	}) {
		label(text, style.text_size, style.text)
	}
	return s.clicked
}

// A raised card with a heading and a line of text; the whole card is the button.
card :: proc(ui: ^Ui, id: clay.ElementId, heading, text: string, selected := false) -> bool {
	s := interact(ui, id)
	if clay.UI()({
		id = id,
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingFit({min = 180})},
			padding = clay.PaddingAll(18),
			childGap = 8,
			layoutDirection = .TopToBottom,
		},
		custom = painted(Steel{face = .Raised, lit = s.hovered || s.focused || selected}),
	}) {
		label(heading, HEAD_SIZE, engraved = true)
		label(text, tint = TEXT_DIM)
	}
	return s.clicked
}

// One line in a list, like a file in the browser; picked lights its text.
list_row :: proc(ui: ^Ui, id: clay.ElementId, text: string, picked: bool) -> bool {
	s := interact(ui, id)
	if clay.UI()({
		id = id,
		layout = {sizing = {clay.SizingGrow({}), clay.SizingFixed(ROW_HEIGHT)}, padding = {12, 12, 0, 0}, childAlignment = {.Left, .Center}},
		custom = painted(Steel{face = s.hovered || s.focused ? .Recessed : .None}),
	}) {
		label(text, tint = picked ? LED : TEXT)
	}
	return s.clicked
}

// A pack slot: a steel box, a glass window over the pack's art, an engraved name plate.
// (hole slot-badges :tags game :needs titlepack-installed) no favourite star on installed slots, no size or installed badge on store slots.
slot :: proc(ui: ^Ui, id: clay.ElementId, name: string, art: ^sdl.Texture, selected: bool) -> bool {
	return slot_box_ui(ui, id, name, art, "", selected)
}

// The empty slot at the end of the installed list; picking it opens the install screen.
add_slot :: proc(ui: ^Ui, id: clay.ElementId, selected: bool) -> bool {
	return slot_box_ui(ui, id, "Install", nil, "+", selected)
}

// Layout pieces: pass to clay.UI()(...) and put children in the block.

row :: proc(gap: u16 = 0, align := clay.ChildAlignment{.Left, .Center}) -> clay.ElementDeclaration {
	return {layout = {sizing = {width = clay.SizingGrow({})}, childGap = gap, childAlignment = align}}
}

column :: proc(gap: u16 = 0) -> clay.ElementDeclaration {
	return {layout = {sizing = {width = clay.SizingGrow({})}, childGap = gap, layoutDirection = .TopToBottom}}
}

spacer :: proc() {
	if clay.UI()({layout = {sizing = {width = clay.SizingGrow({})}}}) {}
}

// Vertical scroll area filling its parent. Clay moves it with the wheel.
scroll :: proc(id: clay.ElementId, padding: clay.Padding = {}, gap: u16 = 0) -> clay.ElementDeclaration {
	return {
		id = id,
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			padding = padding,
			childGap = gap,
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}
}

@(private)
slot_box_ui :: proc(ui: ^Ui, id: clay.ElementId, name: string, art: ^sdl.Texture, glyph: string, selected: bool) -> bool {
	s := interact(ui, id)
	active := s.hovered || s.focused
	lift := ease(ui, id, active ? SLOT_LIFT : 0, LIFT_RATE)
	if clay.UI()({id = id, layout = {sizing = {clay.SizingFixed(SLOT), clay.SizingFixed(SLOT + UNDERSIDE)}}}) {
		if clay.UI()({
			layout = {
				sizing = {clay.SizingFixed(SLOT), clay.SizingFixed(SLOT)},
				padding = {SLOT_FRAME, SLOT_FRAME, SLOT_FRAME, 10},
				childGap = 8,
				layoutDirection = .TopToBottom,
			},
			custom = painted(Slot_Box{lit = active || selected, hovered = active}),
			floating = {attachTo = .Parent, offset = {0, -lift}, clipTo = .AttachedParent, pointerCaptureMode = .Passthrough},
		}) {
			if clay.UI()({
				layout = {sizing = {clay.SizingGrow({}), clay.SizingFixed(WINDOW_H)}, childAlignment = {.Center, .Center}},
				custom = painted(Window{art = art, selected = selected}),
			}) {
				if glyph != "" {
					label(glyph, PLUS_SIZE, selected ? LED : PLUS, engraved = true)
				}
			}
			if clay.UI()({
				layout = {sizing = {clay.SizingGrow({}), clay.SizingFixed(PLATE_H)}, padding = {4, 4, 0, 0}, childAlignment = {.Center, .Center}},
				custom = painted(Plate{lit = active || selected}),
			}) {
				label(fit(name, SLOT - 2 * 20 - 2 * 12, PLATE_SIZE), PLATE_SIZE, engraved = true)
			}
		}
	}
	return s.clicked
}

// Cuts text with "..." to fit width.
@(private)
fit :: proc(text: string, width: f32, size: u16) -> string {
	if text_width(text, size) <= width {
		return text
	}
	for n := len(text) - 1; n > 0; n -= 1 {
		if !utf8.rune_start(text[n]) {
			continue
		}
		cut := fmt.tprintf("%s...", text[:n])
		if text_width(cut, size) <= width {
			return cut
		}
	}
	return "..."
}
