package tests

import "core:strings"
import "core:testing"
import "../src/titlepack"

// The example front in docs/launcher.md reads as written.
@(test)
front_doc_example_reads :: proc(t: ^testing.T) {
	text := `page version=1 width=1000 height=2200
page glow=#e6463c
page font=fonts/title.ttf

bg     bg/arena.png  y=0
bg     bg/roster.png y=900

image  logo.png  x=40 y=60 w=420
rect   x=40 y=280 w=520 h=140 color=#000000a0
text   "Best of 3, 60s rounds" x=60 y=300 w=500 size=24 color=#ffffff

image  map.png id=map x=500 y=460 w=460 hidden
button toggle=map x=280 y=460 w=200 h=56 label="Show map"
button install    x=40  y=460 w=220 h=56 label="Install"
button credits    x=40  y=540 w=220 h=56 label="Credits" image=btn/credits.png
image  edge.png   x=0 y=840 w=1000  // a comment
`
	front, err := titlepack.read_front(text, context.temp_allocator)
	if !testing.expect_value(t, err, "") do return
	testing.expect_value(t, front.height, 2200)
	testing.expect_value(t, front.glow, [4]u8{0xe6, 0x46, 0x3c, 0xff})
	testing.expect_value(t, front.font, "fonts/title.ttf")
	if !testing.expect_value(t, len(front.elements), 10) do return
	e := front.elements
	testing.expect(t, e[0].kind == .Bg && e[0].file == "bg/arena.png" && e[1].y == 900)
	testing.expect(t, e[3].kind == .Rect && e[3].color == {0, 0, 0, 0xa0} && e[3].h == 140)
	testing.expect(t, e[4].kind == .Text && e[4].text == "Best of 3, 60s rounds" && e[4].size == 24)
	testing.expect(t, e[5].id == "map" && e[5].hidden)
	testing.expect(t, e[6].action == .Toggle && e[6].target == "map" && e[6].text == "Show map")
	testing.expect(t, e[7].action == .Install && e[8].action == .Credits && e[8].file == "btn/credits.png")
}

// A creator sees which line is wrong.
@(test)
front_errors_name_the_line :: proc(t: ^testing.T) {
	cases := [?]struct {text, line: string}{
		{"page height=10\nimage", "line 2:"},
		{"\n\nbutton x=1", "line 3:"},
		{"text \"open", "line 1:"},
		{"video a.mp4", "line 1:"},
		{"rect color=red", "line 1:"},
	}
	for c in cases {
		_, err := titlepack.read_front(c.text, context.temp_allocator)
		testing.expect(t, strings.has_prefix(err, c.line), c.text)
	}
}

// Boxes stay on the canvas: 1000 wide, as tall as the page.
@(test)
front_boxes_clamp_to_canvas :: proc(t: ^testing.T) {
	front, err := titlepack.read_front("page height=500\nrect x=900 y=-20 w=400 h=900", context.temp_allocator)
	if !testing.expect_value(t, err, "") do return
	r := front.elements[0]
	testing.expect(t, r.x == 900 && r.y == 0 && r.w == 100 && r.h == 500)
}
