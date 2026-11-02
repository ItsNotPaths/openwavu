package game

import "core:strings"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"
import "../titlepack"
import "../ui"

// A pack's front, read when its slot is picked (docs/launcher.md, Fronts).
// (hole front-font :tags (game titlepack)) page font= is read but not used; fronts draw in the launcher font.
// (hole front-credits :tags game) the credits button does nothing: no screen-bottom popup yet.
Front_View :: struct {
	path:     string,  // the tar or folder it came from
	files:    titlepack.Pack_Files,
	text:     string,  // the front file; elements point into it
	front:    titlepack.Front,
	err:      string,
	textures: map[string]^sdl.Texture,  // by file; nil when it does not load
	toggled:  map[string]bool,          // ids flipped from hidden or shown
}

FRONT_BUTTON_SIZE :: [2]f32{220, 56}

front_open :: proc(v: ^Front_View, u: ^ui.Ui, path: string) {
	front_close(v)
	v.path = strings.clone(path)
	ok: bool
	if v.files, ok = titlepack.open_files(path); !ok {
		v.err = strings.clone("the pack does not open")
		return
	}
	data, has := titlepack.read_file(v.files, titlepack.FRONT)
	if !has {
		v.err = strings.clone("this pack has no front")
		return
	}
	v.text = strings.clone(string(data))
	err: string
	v.front, err = titlepack.read_front(v.text)
	v.err = strings.clone(err)
	for e in v.front.elements {
		if e.file == "" || e.file in v.textures do continue
		bytes, found := titlepack.read_file(v.files, e.file)
		v.textures[e.file] = found ? ui.load_png(u, bytes) : nil
	}
}

front_close :: proc(v: ^Front_View) {
	for _, texture in v.textures do if texture != nil do sdl.DestroyTexture(texture)
	delete(v.textures)
	delete(v.toggled)
	delete(v.front.elements)
	delete(v.text)
	delete(v.err)
	delete(v.path)
	titlepack.close_files(&v.files)
	v^ = {}
}

// The canvas between the columns. It scrolls under them, and its backgrounds reach behind them.
// Returns the button the player used.
front_page :: proc(v: ^Front_View, u: ^ui.Ui, installed: bool) -> (action: titlepack.Action, target: string) {
	scale := (u.size.x - 2 * ui.COLUMN_WIDTH) / titlepack.FRONT_WIDTH
	layers := make([dynamic]ui.Layer, context.temp_allocator)
	for e in v.front.elements do if e.kind == .Bg && shown(v, e) && v.textures[e.file] != nil {
		append(&layers, ui.Layer{v.textures[e.file], e.y})
	}
	if clay.UI()({
		id = clay.ID("Front"),
		layout = {sizing = {clay.SizingFixed(u.size.x), clay.SizingFixed(u.size.y)}, padding = {ui.COLUMN_WIDTH, ui.COLUMN_WIDTH, 0, 0}},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		floating = {attachTo = .Root, zIndex = -1},
	}) {
		if clay.UI()({
			id = clay.ID("FrontCanvas"),
			layout = {sizing = {clay.SizingFixed(titlepack.FRONT_WIDTH * scale), clay.SizingFixed(v.front.height * scale)}},
			custom = ui.painted(ui.Backdrop{layers[:], scale}),
		}) {
			for e, i in v.front.elements {
				if e.kind == .Bg || !shown(v, e) do continue
				if element(v, u, e, u32(i), scale, installed) {
					action, target = e.action, e.target
				}
			}
		}
	}
	if action == .Toggle do v.toggled[target] = !v.toggled[target]
	return
}

@(private = "file")
shown :: proc(v: ^Front_View, e: titlepack.Element) -> bool {
	return e.hidden == v.toggled[e.id]
}

// One element as a box floating on the canvas; true when it is a button and was used.
@(private = "file")
element :: proc(v: ^Front_View, u: ^ui.Ui, e: titlepack.Element, index: u32, scale: f32, installed: bool) -> (used: bool) {
	texture := v.textures[e.file]
	size := [2]f32{e.w, e.h}
	switch e.kind {
	case .Image:
		if texture == nil do return
		native: [2]f32
		sdl.GetTextureSize(texture, &native.x, &native.y)
		switch {
		case size.x == 0 && size.y == 0: size = native
		case size.y == 0: size.y = size.x * native.y / native.x
		case size.x == 0: size.x = size.y * native.x / native.y
		}
	case .Button:
		if size.x == 0 do size.x = FRONT_BUTTON_SIZE.x
		if size.y == 0 do size.y = FRONT_BUTTON_SIZE.y
	case .Text:
		if size.x == 0 do size.x = titlepack.FRONT_WIDTH - e.x
	case .Bg, .Rect:
	}
	box := clay.ElementDeclaration{
		id = clay.ID("FrontElement", index),
		layout = {sizing = {clay.SizingFixed(size.x * scale), size.y > 0 ? clay.SizingFixed(size.y * scale) : clay.SizingFit({})}},
		floating = {attachTo = .Parent, offset = {e.x * scale, e.y * scale}, clipTo = .AttachedParent},
	}
	switch e.kind {
	case .Bg:
	case .Image:
		box.image = {imageData = texture}
	case .Rect:
		box.backgroundColor = clay.Color{f32(e.color.r), f32(e.color.g), f32(e.color.b), f32(e.color.a)}
	case .Text, .Button:
	}
	if clay.UI()(box) {
		#partial switch e.kind {
		case .Text:
			ui.label(e.text, u16(e.size * scale), rgba(e.color))
		case .Button:
			off := e.action == .Install && installed
			glow := [4]f32{f32(v.front.glow.r), f32(v.front.glow.g), f32(v.front.glow.b), f32(v.front.glow.a)} / 255
			used = ui.front_button(u, clay.ID("FrontButton", index), off ? "Installed" : e.text, size * scale, u16(ui.TEXT_SIZE * scale), glow, texture, off)
		}
	}
	return
}

@(private = "file")
rgba :: proc(c: [4]u8) -> u32 {
	return u32(c.r) << 24 | u32(c.g) << 16 | u32(c.b) << 8 | u32(c.a)
}
