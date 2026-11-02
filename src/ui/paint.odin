// The launcher material: cabinet steel, glass and LEDs. Gradients and soft shadows are vertex-colour
// meshes, the grain and round dots are textures baked once at startup. No shaders.
package ui

import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"

// What a custom Clay element draws. Give it to an element with painted().
Paint :: union {
	Steel,
	Slot_Box,
	Window,
	Plate,
	Bar,
	Spotlight,
	Field,
}

// A raised or recessed steel face. lit adds the LED glow of a hovered or focused button.
Steel :: struct {
	face: Face,
	lit:  bool,
}

Slot_Box :: struct {
	lit, hovered: bool,
}

// The slot's glass window; art nil shows the empty back.
Window :: struct {
	art:      ^sdl.Texture,
	selected: bool,
}

// The name plate; only its LED is drawn, the name is a Clay text child.
Plate :: struct {
	lit: bool,
}

Bar :: struct {}

// A text field's recessed face; caret is its x inside the field, or < 0 for none.
Field :: struct {
	typing: bool,
	caret:  f32,
}

// The default backdrop: a red light shining down onto a floor.
Spotlight :: struct {}

Textures :: struct {
	grain, dot: ^sdl.Texture,
}

// Each paint gets a copy in the frame's temp memory, which lives until the frame is drawn.
painted :: proc(p: Paint) -> clay.CustomElementConfig {
	copy := new(Paint, context.temp_allocator)
	copy^ = p
	return {customData = copy}
}

bake :: proc(r: ^sdl.Renderer) -> Textures {
	return {grain = bake_texture(r, GRAIN_TILE, grain_pixel), dot = bake_texture(r, DOT_SIZE, dot_pixel)}
}

unbake :: proc(t: Textures) {
	sdl.DestroyTexture(t.grain)
	sdl.DestroyTexture(t.dot)
}

@(private)
paint :: proc(ui: ^Ui, rect: sdl.FRect, p: Paint) {
	switch p in p {
	case Steel:
		steel(ui, rect, p)
	case Slot_Box:
		slot_box(ui, rect, p)
	case Window:
		window(ui, rect, p)
	case Plate:
		plate_led(ui, {rect.x + 4, rect.y + 7, 6, 6}, p.lit)
	case Field:
		steel(ui, rect, {face = .Recessed, lit = p.typing})
		if p.caret >= 0 {
			fill(ui.renderer, {rect.x + p.caret, rect.y + (rect.h - TEXT_SIZE) / 2, 2, TEXT_SIZE}, color(LED))
		}
	case Spotlight:
		shade(ui.renderer, rect, spotlight_color)
	case Bar:
		steel(ui, rect, {face = .Raised})
		line := sdl.FRect{rect.x, rect.y + rect.h - 4, rect.w, 1}
		soft(ui.renderer, line, 6, lit_color(0.7))
		fill(ui.renderer, line, lit_color(0.7))
	}
}

@(private)
steel :: proc(ui: ^Ui, rect: sdl.FRect, s: Steel) {
	r := ui.renderer
	switch s.face {
	case .None:
	case .Raised:
		soft(r, offset(rect, 0, 6), 12, color(0x000000aa))
		fill(r, offset(rect, 0, 2), color(0x000000ff))
		if s.lit {
			soft(r, rect, 16, lit_color(0.5))
		}
		steel_face(ui, rect)
		bevel(r, rect, 1, 2)
	case .Recessed:
		fill(r, offset(rect, 0, 1), color(0xffffff14))
		shade(r, rect, inset_color)
		grain(ui, rect)
		inner_shadow(r, rect, {2, 4, 2, 1}, color(0x000000cc))
		outline(r, rect, s.lit ? lit_color(0.6) : color(RIM))
	}
}

@(private)
slot_box :: proc(ui: ^Ui, rect: sdl.FRect, s: Slot_Box) {
	r := ui.renderer
	if s.hovered {
		soft(r, offset(rect, 0, 18), 30, color(0x000000ff))
		soft(r, grow(rect, 2), 24, lit_color(0.4))
	} else {
		soft(r, offset(rect, 0, 14), 26, color(0x000000ff))
	}
	underside(r, rect)
	steel_face(ui, rect)
	bevel(r, rect, 2, 3)
	for corner in ([4][2]f32{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
		at := [2]f32{rect.x + 8 + corner.x * (rect.w - 16), rect.y + 8 + corner.y * (rect.h - 16)}
		dot(ui, at, 3.5, color(0x00000099))
		dot(ui, at, 2.6, color(SCREW_RING))
		dot(ui, at, 1.8, color(SCREW_HEAD))
	}
	strips := [3]sdl.FRect {
		{rect.x + rect.w * 0.2, rect.y + 7, rect.w * 0.6, 2},
		{rect.x + 7, rect.y + rect.h * 0.2, 2, rect.h * 0.6},
		{rect.x + rect.w - 9, rect.y + rect.h * 0.2, 2, rect.h * 0.6},
	}
	for strip in strips {
		if s.lit {
			soft(r, grow(strip, 2), 14, lit_color(0.6))
			soft(r, grow(strip, 1), 6, lit_color(1))
		} else {
			soft(r, grow(strip, 1), 5, lit_color(0.45))
		}
		fill(r, offset(grow(strip, 1), 0, 1), color(0xffffff12))
		fill(r, grow(strip, 1), color(0x000000ff))
		led := color(LED)
		fill(r, strip, s.lit ? led : {led.r * 0.55, led.g * 0.55, led.b * 0.55, 1})
	}
}

@(private)
window :: proc(ui: ^Ui, rect: sdl.FRect, w: Window) {
	r := ui.renderer
	if w.selected {
		soft(r, grow(rect, 5), 14, lit_color(0.6))
		fill(r, grow(rect, 3), color(LED))
	}
	fill(r, grow(rect, 2), color(RIM))
	if w.art != nil {
		rect := rect
		sdl.RenderTexture(r, w.art, nil, &rect)
	} else {
		shade(r, rect, empty_window_color)
	}
	shade(r, rect, glass_color)
	inner_shadow(r, rect, {12, 12, 12, 6}, color(0x000000dd))
}

@(private)
plate_led :: proc(ui: ^Ui, rect: sdl.FRect, lit: bool) {
	center := [2]f32{rect.x + rect.w / 2, rect.y + rect.h / 2}
	if lit {
		soft(ui.renderer, rect, 10, lit_color(0.8))
		soft(ui.renderer, rect, 4, lit_color(1))
	}
	dot(ui, center + {0, 0.5}, 3, color(0xffffff1c))
	dot(ui, center, 3, lit ? color(LED) : color(LED_OFF))
}

// The thin bottom face under a slot, narrowing inward: the box seen from slightly above.
@(private)
underside :: proc(r: ^sdl.Renderer, rect: sdl.FRect) {
	top, bottom := sdl.FColor(color(0x232427ff)), sdl.FColor(color(0x0c0d0fff))
	y0, y1 := rect.y + rect.h, rect.y + rect.h + UNDERSIDE
	inset := rect.w * 0.03
	vertices := [4]sdl.Vertex {
		{position = {rect.x, y0}, color = top},
		{position = {rect.x + rect.w, y0}, color = top},
		{position = {rect.x + inset, y1}, color = bottom},
		{position = {rect.x + rect.w - inset, y1}, color = bottom},
	}
	indices := [6]i32{0, 1, 2, 1, 3, 2}
	sdl.RenderGeometry(r, nil, raw_data(vertices[:]), 4, raw_data(indices[:]), 6)
	fill(r, {rect.x, y0, rect.w, 1}, color(0x00000088))
}

@(private)
steel_face :: proc(ui: ^Ui, rect: sdl.FRect) {
	shade(ui.renderer, rect, steel_color)
	grain(ui, rect)
}

@(private)
grain :: proc(ui: ^Ui, rect: sdl.FRect) {
	rect := rect
	sdl.RenderTextureTiled(ui.renderer, ui.textures.grain, nil, 1, &rect)
}

@(private)
bevel :: proc(r: ^sdl.Renderer, rect: sdl.FRect, top, bottom: f32) {
	fill(r, {rect.x, rect.y, rect.w, top}, color(BEVEL_HI))
	fill(r, {rect.x, rect.y + rect.h - bottom, rect.w, bottom}, color(BEVEL_LO))
}

@(private)
outline :: proc(r: ^sdl.Renderer, rect: sdl.FRect, c: [4]f32) {
	fill(r, {rect.x, rect.y, rect.w, 1}, c)
	fill(r, {rect.x, rect.y + rect.h - 1, rect.w, 1}, c)
	fill(r, {rect.x, rect.y + 1, 1, rect.h - 2}, c)
	fill(r, {rect.x + rect.w - 1, rect.y + 1, 1, rect.h - 2}, c)
}

@(private)
fill :: proc(r: ^sdl.Renderer, rect: sdl.FRect, c: [4]f32) {
	rect := rect
	sdl.SetRenderDrawColorFloat(r, c.r, c.g, c.b, c.a)
	sdl.RenderFillRect(r, &rect)
}

@(private)
dot :: proc(ui: ^Ui, center: [2]f32, radius: f32, c: [4]f32) {
	rect := sdl.FRect{center.x - radius, center.y - radius, radius * 2, radius * 2}
	sdl.SetTextureColorModFloat(ui.textures.dot, c.r, c.g, c.b)
	sdl.SetTextureAlphaModFloat(ui.textures.dot, c.a)
	sdl.RenderTexture(ui.renderer, ui.textures.dot, nil, &rect)
}

// Colour at a point of a face, given the point and the face size.
@(private)
Shader :: proc(p, size: [2]f32) -> [4]f32

@(private)
Stop :: struct {
	at:    f32,
	color: u32,
}

@(private)
STEEL_RAMP := [?]Stop{{0, STEEL_TOP}, {0.5, STEEL_MID}, {1, STEEL_BOTTOM}}
@(private)
SHEEN_RAMP := [?]Stop{{0.15, 0xffffff00}, {0.38, 0xffffff1e}, {0.5, 0xffffff0a}, {0.66, 0xffffff00}}
@(private)
HOT_RAMP := [?]Stop{{0, 0xffffff14}, {0.7, 0xffffff00}}
@(private)
INSET_RAMP := [?]Stop{{0, INSET_TOP}, {1, INSET_BOTTOM}}
@(private)
GLEAM_RAMP := [?]Stop{{0.32, 0xffffff00}, {0.4, 0xffffff16}, {0.47, 0xffffff00}}
@(private)
TOP_LIGHT_RAMP := [?]Stop{{0, 0xffffff38}, {0.7, 0xffffff00}}
@(private)
EMPTY_RAMP := [?]Stop{{0, 0x1a1d24ff}, {0.7, 0x07080bff}}

@(private)
steel_color :: proc(p, size: [2]f32) -> [4]f32 {
	c := ramp(css_linear(p, size, 170), STEEL_RAMP[:])
	c = over(c, ramp(css_linear(p, size, 115), SHEEN_RAMP[:]))
	return over(c, ramp(ellipse(p, size, {0.2, 0}, {0.8, 0.5}), HOT_RAMP[:]))
}

@(private)
BEAM_RAMP := [?]Stop{{0, 0xff5a4a00}, {1, 0xff5a4a24}}
@(private)
POOL_RAMP := [?]Stop{{0, 0xff6a5570}, {0.6, 0xd8382a28}, {1, 0xd8382a00}}

// One cone of light from above the top edge, ending in its pool on the floor; all else black.
@(private)
spotlight_color :: proc(p, size: [2]f32) -> [4]f32 {
	u := p / size
	half_width := 0.03 + 0.24 * u.y
	edge := clamp(1 - abs(u.x - 0.5) / half_width, 0, 1)
	beam := edge * edge * (3 - 2 * edge) * clamp((0.9 - u.y) * 4, 0, 1)
	c := over(color(BACKGROUND), ramp(beam, BEAM_RAMP[:]))
	return over(c, ramp(ellipse(p, size, {0.5, 0.88}, {0.24, 0.07}), POOL_RAMP[:]))
}

@(private)
inset_color :: proc(p, size: [2]f32) -> [4]f32 {
	return ramp(p.y / size.y, INSET_RAMP[:])
}

@(private)
glass_color :: proc(p, size: [2]f32) -> [4]f32 {
	gleam := ramp(css_linear(p, size, 118), GLEAM_RAMP[:])
	return over(gleam, ramp(ellipse(p, size, {0.5, -0.05}, {0.6, 0.45}), TOP_LIGHT_RAMP[:]))
}

@(private)
empty_window_color :: proc(p, size: [2]f32) -> [4]f32 {
	center := size * {0.5, 0.4}
	return ramp(linalg.length(p - center) / linalg.length(size - center), EMPTY_RAMP[:])
}

// Position along a CSS linear-gradient at deg, 0 at the start, 1 at the end.
@(private)
css_linear :: proc(p, size: [2]f32, deg: f32) -> f32 {
	a := deg * math.RAD_PER_DEG
	dir := [2]f32{math.sin(a), -math.cos(a)}
	span := abs(size.x * dir.x) + abs(size.y * dir.y)
	return linalg.dot(p - size / 2, dir) / span + 0.5
}

// Distance from an ellipse centre, in radii; centre and radii are fractions of size.
@(private)
ellipse :: proc(p, size, center, radii: [2]f32) -> f32 {
	return linalg.length((p / size - center) / radii)
}

@(private)
ramp :: proc(t: f32, stops: []Stop) -> [4]f32 {
	if t <= stops[0].at {
		return color(stops[0].color)
	}
	for i in 1 ..< len(stops) {
		a, b := stops[i - 1], stops[i]
		if t <= b.at {
			return linalg.lerp(color(a.color), color(b.color), (t - a.at) / (b.at - a.at))
		}
	}
	return color(stops[len(stops) - 1].color)
}

@(private)
over :: proc(below, above: [4]f32) -> [4]f32 {
	alpha := above.a + below.a * (1 - above.a)
	if alpha == 0 {
		return 0
	}
	rgb := (above.rgb * above.a + below.rgb * below.a * (1 - above.a)) / alpha
	return {rgb.r, rgb.g, rgb.b, alpha}
}

@(private)
SHADE_CELL :: 20

// Fills rect with a shader sampled on a grid of vertices.
@(private)
shade :: proc(r: ^sdl.Renderer, rect: sdl.FRect, shader: Shader) {
	columns := clamp(int(rect.w / SHADE_CELL) + 2, 2, 64)
	rows := clamp(int(rect.h / SHADE_CELL) + 2, 2, 64)
	xs := make([]f32, columns, context.temp_allocator)
	ys := make([]f32, rows, context.temp_allocator)
	for &x, i in xs do x = rect.x + rect.w * f32(i) / f32(columns - 1)
	for &y, j in ys do y = rect.y + rect.h * f32(j) / f32(rows - 1)
	colors := make([][4]f32, columns * rows, context.temp_allocator)
	for y, j in ys {
		for x, i in xs {
			colors[j * columns + i] = shader({x - rect.x, y - rect.y}, {rect.w, rect.h})
		}
	}
	grid(r, xs, ys, colors)
}

@(private)
FADE_STEPS :: 4

// A blurred rect, like a CSS shadow: solid inside, fading out over blur centred on the edge.
@(private)
soft :: proc(r: ^sdl.Renderer, rect: sdl.FRect, blur: f32, c: [4]f32) {
	xs, x_weights := fade_axis(rect.x, rect.w, blur)
	ys, y_weights := fade_axis(rect.y, rect.h, blur)
	colors: [len(xs) * len(ys)][4]f32
	for j in 0 ..< len(ys) {
		for i in 0 ..< len(xs) {
			colors[j * len(xs) + i] = {c.r, c.g, c.b, c.a * x_weights[i] * y_weights[j]}
		}
	}
	grid(r, xs[:], ys[:], colors[:])
}

// Grid lines across one axis of a soft rect and the fade at each. Lines meet in the middle of a
// rect thinner than its blur.
@(private)
fade_axis :: proc(start, length, blur: f32) -> (lines, weights: [2 * (FADE_STEPS + 1)]f32) {
	width := max(blur, 0.01)
	outer, middle := start - width / 2, start + length / 2
	for k in 0 ..= FADE_STEPS {
		left := min(outer + width * f32(k) / FADE_STEPS, middle)
		t := clamp((left - outer) / width, 0, 1)
		lines[k] = left
		lines[len(lines) - 1 - k] = 2 * middle - left
		weights[k] = t * t * (3 - 2 * t)
		weights[len(lines) - 1 - k] = weights[k]
	}
	return
}

// Shadow on the inside of rect's edges, fading inward; widths are left, top, right, bottom.
@(private)
inner_shadow :: proc(r: ^sdl.Renderer, rect: sdl.FRect, widths: [4]f32, c: [4]f32) {
	xs := [4]f32{rect.x, rect.x + widths[0], rect.x + rect.w - widths[2], rect.x + rect.w}
	ys := [4]f32{rect.y, rect.y + widths[1], rect.y + rect.h - widths[3], rect.y + rect.h}
	colors: [16][4]f32
	for j in 0 ..< 4 {
		for i in 0 ..< 4 {
			edge := i == 0 || i == 3 || j == 0 || j == 3
			colors[j * 4 + i] = {c.r, c.g, c.b, edge ? c.a : 0}
		}
	}
	grid(r, xs[:], ys[:], colors[:])
}

// Quads between grid lines xs and ys, coloured per vertex, row by row.
@(private)
grid :: proc(r: ^sdl.Renderer, xs, ys: []f32, colors: [][4]f32) {
	columns := len(xs)
	vertices := make([]sdl.Vertex, columns * len(ys), context.temp_allocator)
	for y, j in ys {
		for x, i in xs {
			vertices[j * columns + i] = {position = {x, y}, color = sdl.FColor(colors[j * columns + i])}
		}
	}
	indices := make([dynamic]i32, 0, (columns - 1) * (len(ys) - 1) * 6, context.temp_allocator)
	for j in 0 ..< len(ys) - 1 {
		for i in 0 ..< columns - 1 {
			a := i32(j * columns + i)
			b, c, d := a + 1, a + i32(columns), a + i32(columns) + 1
			append(&indices, a, b, c, b, d, c)
		}
	}
	sdl.RenderGeometry(r, nil, raw_data(vertices), i32(len(vertices)), raw_data(indices), i32(len(indices)))
}

@(private)
lit_color :: proc(alpha: f32) -> [4]f32 {
	c := color(LED)
	return {c.r, c.g, c.b, alpha}
}

@(private)
offset :: proc(rect: sdl.FRect, x, y: f32) -> sdl.FRect {
	return {rect.x + x, rect.y + y, rect.w, rect.h}
}

@(private)
grow :: proc(rect: sdl.FRect, by: f32) -> sdl.FRect {
	return {rect.x - by, rect.y - by, rect.w + 2 * by, rect.h + 2 * by}
}

@(private)
DOT_SIZE :: 32

@(private)
bake_texture :: proc(r: ^sdl.Renderer, size: int, pixel: proc(x, y, size: int) -> [4]f32) -> ^sdl.Texture {
	pixels := make([][4]u8, size * size, context.temp_allocator)
	for y in 0 ..< size {
		for x in 0 ..< size {
			c := pixel(x, y, size) * 255 + 0.5
			pixels[y * size + x] = {u8(c.r), u8(c.g), u8(c.b), u8(c.a)}
		}
	}
	texture := sdl.CreateTexture(r, .RGBA32, .STATIC, i32(size), i32(size))
	sdl.UpdateTexture(texture, nil, raw_data(pixels), i32(size * 4))
	sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND)
	return texture
}

// Fine white grain: per-pixel noise plus a softer octave at half the frequency. Tiles seamlessly.
@(private)
grain_pixel :: proc(x, y, size: int) -> [4]f32 {
	cells := size / 2
	fx, fy := f32(x) / 2, f32(y) / 2
	x0, y0 := int(fx), int(fy)
	tx, ty := fx - f32(x0), fy - f32(y0)
	x1, y1 := (x0 + 1) % cells, (y0 + 1) % cells
	top := math.lerp(noise(x0, y0), noise(x1, y0), tx)
	bottom := math.lerp(noise(x0, y1), noise(x1, y1), tx)
	n := 0.55 * noise(x + 1000, y) + 0.45 * math.lerp(top, bottom, ty)
	return {1, 1, 1, n * GRAIN_ALPHA}
}

@(private)
dot_pixel :: proc(x, y, size: int) -> [4]f32 {
	d := linalg.length([2]f32{f32(x), f32(y)} + 0.5 - f32(size) / 2)
	return {1, 1, 1, clamp(f32(size) / 2 - 1 - d + 0.5, 0, 1)}
}

@(private)
noise :: proc(x, y: int) -> f32 {
	h := u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	h ~= h >> 16
	return f32(h & 0xffff) / 0xffff
}
