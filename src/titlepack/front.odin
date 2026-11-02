// The front: a pack's page in the launcher (docs/launcher.md, Fronts). One element per line: its kind,
// then bare words, "quoted text" and key=value pairs. // starts a comment. Data only, no code.
package titlepack

import "core:fmt"
import "core:strconv"
import "core:strings"

FRONT :: "front.owf"
FRONT_WIDTH :: 1000
FRONT_MAX_HEIGHT :: 20000

Front :: struct {
	height:   f32,
	glow:     [4]u8,
	font:     string,  // a TTF in the pack's file view; "" for the launcher's
	elements: []Element,
	credits:  []string,  // credits "..." lines; the launcher shows them in its popup
}

Kind :: enum u8 {
	Bg,
	Image,
	Rect,
	Text,
	Button,
}

Action :: enum u8 {
	None,
	Install,
	Uninstall,
	Play,
	Credits,
	Url,
	Toggle,
}

Element :: struct {
	kind:       Kind,
	id:         string,
	hidden:     bool,
	file:       string,  // bg, image, a button's image=
	text:       string,  // text, a button's label=
	x, y, w, h: f32,     // canvas px; w or h 0 = from the image's aspect
	size:       f32,
	color:      [4]u8,
	action:     Action,
	target:     string,  // the url or the toggled id
}

DEFAULT_GLOW :: [4]u8{0xff, 0x5a, 0x4a, 0xff}

// Front text -> the front, or the first line that does not read. Strings point into text.
read_front :: proc(text: string, allocator := context.allocator) -> (front: Front, err: string) {
	front = {height = 720, glow = DEFAULT_GLOW}
	elements := make([dynamic]Element, allocator)
	credits := make([dynamic]string, allocator)
	line_number := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_number += 1
		words, closed := split_words(line, context.temp_allocator)
		if !closed {
			err = fmt.tprintf("line %d: no closing quote", line_number)
			break
		}
		if len(words) == 0 do continue
		if words[0].text == "page" {
			err = read_page(&front, words[1:])
		} else if words[0].text == "credits" {
			if len(words) != 2 || !words[1].quoted do err = "credits takes one \"quoted line\""
			else do append(&credits, words[1].text)
		} else {
			e: Element
			e, err = read_element(words)
			if err == "" do append(&elements, e)
		}
		if err != "" {
			err = fmt.tprintf("line %d: %s", line_number, err)
			break
		}
	}
	front.elements = elements[:]
	front.credits = credits[:]
	for &e in front.elements {  // boxes may hang off the canvas, which cuts them off; the limits only keep sizes sane
		e.x = clamp(e.x, -FRONT_WIDTH, FRONT_WIDTH)
		e.y = clamp(e.y, -front.height, front.height)
		e.w = clamp(e.w, 0, 2 * FRONT_WIDTH)
		e.h = clamp(e.h, 0, 2 * front.height)
	}
	return
}

@(private)
Word :: struct {
	text:   string,
	key:    string,  // key=value: text is the value
	quoted: bool,
}

// Words split at spaces; "..." holds spaces and may follow key=. Not ok when a quote is left open.
@(private)
split_words :: proc(line: string, allocator := context.temp_allocator) -> (words: []Word, ok: bool) {
	out := make([dynamic]Word, allocator)
	rest := line
	for {
		rest = strings.trim_left_space(rest)
		if rest == "" || strings.has_prefix(rest, "//") do break
		w: Word
		end := 0
		for end < len(rest) && rest[end] != ' ' && rest[end] != '\t' && rest[end] != '"' do end += 1
		w.text = rest[:end]
		if i := strings.index_byte(w.text, '='); i >= 0 {
			w.key, w.text = w.text[:i], w.text[i + 1:]
		}
		if end < len(rest) && rest[end] == '"' && w.text == "" {
			close := strings.index_byte(rest[end + 1:], '"')
			if close < 0 do return nil, false
			w.text, w.quoted = rest[end + 1:][:close], true
			end += close + 2
		}
		append(&out, w)
		rest = rest[end:]
	}
	return out[:], true
}

@(private)
read_page :: proc(front: ^Front, words: []Word) -> (err: string) {
	for w in words {
		ok := true
		switch w.key {
		case "version": ok = w.text == "1"
		case "width": ok = w.text == "1000"
		case "height":
			front.height, ok = strconv.parse_f32(w.text)
			front.height = clamp(front.height, 1, FRONT_MAX_HEIGHT)
		case "glow": front.glow, ok = hex_color(w.text)
		case "font": front.font = w.text
		case: return fmt.tprintf("page has no %q", word_name(w))
		}
		if !ok do return fmt.tprintf("page %s=%s does not read", w.key, w.text)
	}
	return ""
}

@(private)
KIND_NAMES := [Kind]string{.Bg = "bg", .Image = "image", .Rect = "rect", .Text = "text", .Button = "button"}

@(private)
read_element :: proc(words: []Word) -> (e: Element, err: string) {
	found: bool
	for name, kind in KIND_NAMES do if words[0].text == name && !words[0].quoted && words[0].key == "" {
		e.kind, found = kind, true
	}
	if !found do return e, fmt.tprintf("%q is not page, credits, bg, image, rect, text or button", word_name(words[0]))
	e.color = {0xff, 0xff, 0xff, 0xff}
	e.size = 24
	for w in words[1:] {
		ok := true
		switch {
		case w.key == "":
			if !read_bare(&e, w) do return e, fmt.tprintf("%s takes no %q", KIND_NAMES[e.kind], w.text)
		case w.key == "x": e.x, ok = strconv.parse_f32(w.text)
		case w.key == "y": e.y, ok = strconv.parse_f32(w.text)
		case w.key == "w": e.w, ok = strconv.parse_f32(w.text)
		case w.key == "h": e.h, ok = strconv.parse_f32(w.text)
		case w.key == "id": e.id = w.text
		case w.key == "size" && e.kind == .Text: e.size, ok = strconv.parse_f32(w.text)
		case w.key == "color" && (e.kind == .Rect || e.kind == .Text): e.color, ok = hex_color(w.text)
		case w.key == "label" && e.kind == .Button: e.text = w.text
		case w.key == "image" && e.kind == .Button: e.file = w.text
		case w.key == "url" && e.kind == .Button: e.action, e.target = .Url, w.text
		case w.key == "toggle" && e.kind == .Button: e.action, e.target = .Toggle, w.text
		case: return e, fmt.tprintf("%s has no %q", KIND_NAMES[e.kind], w.key)
		}
		if !ok do return e, fmt.tprintf("%s=%s does not read", w.key, w.text)
	}
	switch {
	case (e.kind == .Bg || e.kind == .Image) && e.file == "": err = fmt.tprintf("%s needs a file", KIND_NAMES[e.kind])
	case e.kind == .Button && e.action == .None: err = "button needs install, uninstall, play, credits, url= or toggle="
	}
	return
}

// A bare word: hidden, the file of bg and image, the text of text, a button's action.
@(private)
read_bare :: proc(e: ^Element, w: Word) -> bool {
	switch {
	case w.text == "hidden" && !w.quoted: e.hidden = true
	case (e.kind == .Bg || e.kind == .Image) && e.file == "": e.file = w.text
	case e.kind == .Text && e.text == "" && w.quoted: e.text = w.text
	case e.kind == .Button && !w.quoted && w.text == "install": e.action = .Install
	case e.kind == .Button && !w.quoted && w.text == "uninstall": e.action = .Uninstall
	case e.kind == .Button && !w.quoted && w.text == "play": e.action = .Play
	case e.kind == .Button && !w.quoted && w.text == "credits": e.action = .Credits
	case: return false
	}
	return true
}

@(private)
word_name :: proc(w: Word) -> string {
	return w.key != "" ? w.key : w.text
}

// #rrggbb or #rrggbbaa.
@(private)
hex_color :: proc(s: string) -> (c: [4]u8, ok: bool) {
	if len(s) != 7 && len(s) != 9 || s[0] != '#' do return
	c.a = 0xff
	for i in 0 ..< (len(s) - 1) / 2 {
		v := strconv.parse_uint(s[1 + 2 * i:][:2], 16) or_return
		c[i] = u8(v)
	}
	return c, true
}
