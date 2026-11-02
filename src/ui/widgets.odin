package ui

import sdl "vendor:sdl3"
import clay "../../vendor/clay"

label :: proc(text: string, size: u16 = TEXT_SIZE, tint: u32 = TEXT, engraved := false, face := Font.Body) {
	clay.TextDynamic(text, clay.TextConfig({
		textColor = clay_color(tint),
		fontId = u16(face),
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
		label(text, style.text_size, style.text, face = .Display)
	}
	return s.clicked
}

// A value between two raised arrow buttons; an arrow at its end greys out. Returns -1, 0 or 1.
stepper :: proc(ui: ^Ui, id: clay.ElementId, text: string, can_down, can_up: bool) -> (step: int) {
	if clay.UI()(row(6)) {
		if button(ui, clay.ID("StepDown", id.id), "<", can_down ? BUTTON : OFF_BUTTON) && can_down do step = -1
		if clay.UI()({layout = {sizing = {width = clay.SizingFixed(STEPPER_VALUE_WIDTH)}, childAlignment = {.Center, .Center}}}) {
			label(text, face = .Display)
		}
		if button(ui, clay.ID("StepUp", id.id), ">", can_up ? BUTTON : OFF_BUTTON) && can_up do step = 1
	}
	return
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
		label(heading, HEAD_SIZE, engraved = true, face = .Display)
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
// (hole slot-badges :tags game) no favourite star on installed slots, no size or installed badge on store slots.
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
scroll :: proc(ui: ^Ui, id: clay.ElementId, padding: clay.Padding = {}, gap: u16 = 0) -> clay.ElementDeclaration {
	return {
		id = id,
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			padding = padding,
			childGap = gap,
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, childOffset = scroll_offset(ui, id)},
	}
}

// The scroll position of the container with this id, for its childOffset. Not clay.GetScrollOffset:
// that matches the element's slot from last frame, which moves when the elements before it change.
scroll_offset :: proc(ui: ^Ui, id: clay.ElementId) -> clay.Vector2 {
	append(&ui.scrolling, id)
	return ui.scrolls[id.id]
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
					label(glyph, PLUS_SIZE, selected ? LED : PLUS, engraved = true, face = .Display)
				}
			}
			if clay.UI()({
				layout = {sizing = {clay.SizingGrow({}), clay.SizingFixed(PLATE_H)}, padding = {PLATE_PAD, PLATE_PAD, 0, 0}},
				custom = painted(Plate{lit = active || selected}),
			}) {
				plate_name(ui, name)
			}
		}
	}
	return s.clicked
}

@(private)
plate_name :: proc(ui: ^Ui, name: string) {
	overflow := text_size(ui, .Display, name, PLATE_SIZE).x - (SLOT - 2 * SLOT_FRAME - 2 * PLATE_PAD)
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow({}), clay.SizingGrow({})}, childAlignment = {overflow > 0 ? .Left : .Center, .Center}},
		clip = {horizontal = true, childOffset = {overflow > 0 ? -marquee(overflow, ui.time) : 0, 0}},
	}) {
		clay.TextDynamic(name, clay.TextConfig({
			textColor = clay_color(TEXT),
			fontId = u16(Font.Display),
			fontSize = PLATE_SIZE,
			wrapMode = .None,
			userData = &engraved_tag,
		}))
	}
}
