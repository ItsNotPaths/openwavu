package ui

import clay "../../vendor/clay"

label :: proc(text: string, size: u16 = TEXT_SIZE, color := TEXT) {
	clay.TextDynamic(text, clay.TextConfig({textColor = color, fontSize = size}))
}

button :: proc(ui: ^Ui, id: clay.ElementId, text: string, style := BUTTON, nav := true) -> bool {
	s := interact(ui, id, nav)
	if clay.UI()({
		id = id,
		layout = {padding = style.padding, childAlignment = {.Center, .Center}},
		backgroundColor = s.hovered || s.focused ? style.hover : style.fill,
		cornerRadius = clay.CornerRadiusAll(style.radius),
		border = focus_border(s),
	}) {
		label(text, style.text_size, style.text)
	}
	return s.clicked
}

// A square block with a title at the bottom. image is an ^sdl.Texture or nil.
tile :: proc(ui: ^Ui, id: clay.ElementId, title: string, image: rawptr = nil) -> bool {
	s := interact(ui, id)
	if clay.UI()({
		id = id,
		layout = {
			sizing = {clay.SizingFixed(TILE_SIZE), clay.SizingFixed(TILE_SIZE)},
			padding = clay.PaddingAll(12),
			childAlignment = {.Left, .Bottom},
		},
		backgroundColor = s.hovered || s.focused ? RAISED : SURFACE,
		cornerRadius = clay.CornerRadiusAll(10),
		image = {imageData = image},
		border = focus_border(s),
	}) {
		label(title)
	}
	return s.clicked
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
scroll :: proc(id: clay.ElementId, padding: u16 = 0, gap: u16 = 0) -> clay.ElementDeclaration {
	return {
		id = id,
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingGrow({})},
			padding = clay.PaddingAll(padding),
			childGap = gap,
			layoutDirection = .TopToBottom,
		},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}
}

@(private)
focus_border :: proc(s: Widget_State) -> clay.BorderElementConfig {
	return s.focused ? {color = ACCENT, width = clay.BorderOutside(2)} : {}
}
