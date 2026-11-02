package ui

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"

// The field taking keyboard text. One at a time.
Typing :: struct {
	id:    clay.ElementId,
	caret: int,  // byte offset into the field's text
	blink: f32,
	shown: bool,  // the field was drawn this frame
	edits: [dynamic]Edit,  // this frame's keys and text, in order
}

// Typed text (in temp memory) or an editing key.
Edit :: union {
	string,
	Edit_Key,
}

Edit_Key :: enum u8 {
	Left,
	Right,
	Home,
	End,
	Backspace,
	Delete,
	Paste,
	Submit,
	Leave,
}

// A one-line field over a caller-owned builder. A click or Accept starts typing; Enter, Escape or a
// click elsewhere stops it. Returns true on Enter.
field :: proc(ui: ^Ui, id: clay.ElementId, text: ^strings.Builder, placeholder: string) -> (submitted: bool) {
	s := interact(ui, id)
	t := &ui.typing
	if s.clicked && t.id.id != id.id {
		start_typing(ui, id, len(text.buf))
	}
	typing := t.id.id == id.id
	if typing {
		t.shown = true
		t.caret = min(t.caret, len(text.buf))
		submitted = apply_edits(ui, text)
		left_field := (ui.input.mouse_pressed && !s.hovered) || (ui.input.pad && ui.focus.id != id.id)
		if submitted || left_field {
			stop_typing(ui)
		}
		typing = t.id.id == id.id
	}

	str := strings.to_string(text^)
	caret := typing ? text_size(ui, .Body, str[:t.caret], TEXT_SIZE).x : 0
	inner := clay.GetElementData(id).boundingBox.width - 2 * FIELD_PAD
	shift := typing ? max(0, caret - inner + 2) : 0
	show_caret := typing && math.mod(t.blink, 1) < 0.5
	if clay.UI()({
		id = id,
		layout = {
			sizing = {clay.SizingGrow({}), clay.SizingFixed(SEARCH_HEIGHT)},
			padding = {FIELD_PAD, FIELD_PAD, 0, 0},
			childAlignment = {.Left, .Center},
		},
		custom = painted(Field{typing = typing, caret = show_caret ? FIELD_PAD + caret - shift : -1}),
		clip = {horizontal = true, childOffset = {-shift, 0}},
	}) {
		empty := len(str) == 0
		clay.TextDynamic(empty ? placeholder : str, clay.TextConfig({
			textColor = clay_color(empty ? HINT : FIELD_TEXT),
			fontSize = TEXT_SIZE,
			wrapMode = .None,
		}))
	}
	return
}

@(private)
start_typing :: proc(ui: ^Ui, id: clay.ElementId, caret: int) {
	ui.typing.id = id
	ui.typing.caret = caret
	ui.typing.blink = 0
	_ = sdl.StartTextInput(sdl.GetRenderWindow(ui.renderer))
}

@(private)
stop_typing :: proc(ui: ^Ui) {
	ui.typing.id = {}
	_ = sdl.StopTextInput(sdl.GetRenderWindow(ui.renderer))
}

// Called from end(): a field that was not drawn stops typing, and the frame's edits are spent.
@(private)
end_typing :: proc(ui: ^Ui) {
	t := &ui.typing
	if t.id.id != 0 && !t.shown {
		stop_typing(ui)
	}
	t.shown = false
	t.blink += ui.dt
	clear(&t.edits)
}

@(private)
apply_edits :: proc(ui: ^Ui, text: ^strings.Builder) -> (submitted: bool) {
	t := &ui.typing
	buf := &text.buf
	for edit in t.edits {
		t.blink = 0
		switch e in edit {
		case string:
			insert(t, buf, e)
		case Edit_Key:
			switch e {
			case .Left:
				t.caret -= rune_before(buf[:], t.caret)
			case .Right:
				t.caret += rune_after(buf[:], t.caret)
			case .Home:
				t.caret = 0
			case .End:
				t.caret = len(buf)
			case .Backspace:
				n := rune_before(buf[:], t.caret)
				remove_range(buf, t.caret - n, t.caret)
				t.caret -= n
			case .Delete:
				remove_range(buf, t.caret, t.caret + rune_after(buf[:], t.caret))
			case .Paste:
				clipboard := sdl.GetClipboardText()
				pasted := string(cstring(clipboard))
				if line_end := strings.index_any(pasted, "\r\n"); line_end >= 0 {
					pasted = pasted[:line_end]
				}
				insert(t, buf, pasted)
				sdl.free(clipboard)
			case .Submit:
				submitted = true
			case .Leave:
				stop_typing(ui)
				return
			}
		}
	}
	return
}

@(private)
insert :: proc(t: ^Typing, buf: ^[dynamic]u8, s: string) {
	inject_at_elems(buf, t.caret, ..transmute([]u8)s)
	t.caret += len(s)
}

@(private)
rune_before :: proc(buf: []u8, at: int) -> int {
	if at == 0 {
		return 0
	}
	_, size := utf8.decode_last_rune(buf[:at])
	return size
}

@(private)
rune_after :: proc(buf: []u8, at: int) -> int {
	if at == len(buf) {
		return 0
	}
	_, size := utf8.decode_rune(buf[at:])
	return size
}

@(private)
edit_key :: proc(key: sdl.Keycode, mod: sdl.Keymod) -> Maybe(Edit_Key) {
	switch key {
	case sdl.K_LEFT:
		return .Left
	case sdl.K_RIGHT:
		return .Right
	case sdl.K_HOME:
		return .Home
	case sdl.K_END:
		return .End
	case sdl.K_BACKSPACE:
		return .Backspace
	case sdl.K_DELETE:
		return .Delete
	case sdl.K_V:
		if mod & sdl.KMOD_CTRL != {} {
			return .Paste
		}
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		return .Submit
	case sdl.K_ESCAPE:
		return .Leave
	}
	return nil
}
