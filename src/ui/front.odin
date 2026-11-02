// What a pack's front draws with: its images, faded backgrounds and its buttons (docs/launcher-spec.md, Front).
package ui

import "core:c"
import stbi "vendor:stb/image"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"

// Backgrounds behind a front canvas. Each is scaled to BACKDROP_WIDTH canvas px, centred, at its y.
Backdrop :: struct {
	layers: []Layer,
	scale:  f32,  // screen px per canvas px
}

Layer :: struct {
	texture: ^sdl.Texture,
	y:       f32,
}

// A front button: the pack's glow when lit; art in place of the steel; off = recessed (installed).
Front_Button :: struct {
	art:      ^sdl.Texture,
	glow:     [4]f32,
	lit, off: bool,
}

CANVAS_WIDTH :: 1000
BACKDROP_WIDTH :: 1400

// PNG or JPEG bytes -> a texture, nil when they do not decode. stb_image: core:image/png is slow in debug builds.
load_image :: proc(ui: ^Ui, data: []byte) -> ^sdl.Texture {
	w, h, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &channels, 4)
	if pixels == nil do return nil
	defer stbi.image_free(pixels)
	texture := sdl.CreateTexture(ui.renderer, .RGBA32, .STATIC, w, h)
	if texture == nil do return nil
	sdl.UpdateTexture(texture, nil, pixels, w * 4)
	sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND)
	return texture
}

front_button :: proc(ui: ^Ui, id: clay.ElementId, text: string, size: [2]f32, text_size: u16, glow: [4]f32, art: ^sdl.Texture, off: bool) -> bool {
	s := interact(ui, id, !off)
	if clay.UI()({
		id = id,
		layout = {sizing = {clay.SizingFixed(size.x), clay.SizingFixed(size.y)}, childAlignment = {.Center, .Center}},
		custom = painted(Front_Button{art = art, glow = glow, lit = !off && (s.hovered || s.focused), off = off}),
	}) {
		if art == nil do label(text, text_size, off ? TEXT_OFF : TEXT, face = .Display)
	}
	return s.clicked && !off
}

@(private)
backdrop :: proc(r: ^sdl.Renderer, canvas: sdl.FRect, b: Backdrop) {
	width := BACKDROP_WIDTH * b.scale
	for layer in b.layers {
		w, h: f32
		sdl.GetTextureSize(layer.texture, &w, &h)
		if w <= 0 do continue
		rect := sdl.FRect{canvas.x - (width - canvas.w) / 2, canvas.y + layer.y * b.scale, width, width * h / w}
		faded(r, layer.texture, rect)
	}
}

// The texture over rect, its edges fading to clear: the sides slowly over their outer third, top and bottom over 12%.
@(private)
faded :: proc(r: ^sdl.Renderer, texture: ^sdl.Texture, rect: sdl.FRect) {
	SIDE := [?][2]f32{{0, 0}, {0.06, 0.10}, {0.13, 0.35}, {0.21, 0.65}, {0.28, 0.88}, {0.34, 1}}
	ENDS := [?][2]f32{{0, 0}, {0.12, 1}, {0.88, 1}, {1, 0}}
	xs: [2 * len(SIDE)][2]f32
	for s, i in SIDE {
		xs[i] = s
		xs[len(xs) - 1 - i] = {1 - s[0], s[1]}
	}
	vertices: [len(xs) * len(ENDS)]sdl.Vertex
	for e, j in ENDS {
		for s, i in xs {
			vertices[j * len(xs) + i] = {
				position  = {rect.x + s[0] * rect.w, rect.y + e[0] * rect.h},
				color     = {1, 1, 1, s[1] * e[1]},
				tex_coord = {s[0], e[0]},
			}
		}
	}
	indices: [(len(xs) - 1) * (len(ENDS) - 1) * 6]i32
	n := 0
	for j in 0 ..< len(ENDS) - 1 {
		for i in 0 ..< len(xs) - 1 {
			a := i32(j * len(xs) + i)
			b, c, d := a + 1, a + i32(len(xs)), a + i32(len(xs)) + 1
			for v in ([6]i32{a, b, c, b, d, c}) {
				indices[n] = v
				n += 1
			}
		}
	}
	sdl.RenderGeometry(r, texture, &vertices[0], len(vertices), &indices[0], len(indices))
}

@(private)
front_button_paint :: proc(ui: ^Ui, rect: sdl.FRect, b: Front_Button) {
	if b.lit {
		soft(ui.renderer, rect, 26, b.glow)
		for ring in 1 ..= 3 do outline(ui.renderer, grow(rect, f32(ring)), b.glow)
	}
	if b.art != nil {
		box := rect
		sdl.RenderTexture(ui.renderer, b.art, nil, &box)
	} else {
		steel(ui, rect, {face = b.off ? .Recessed : .Raised})
	}
}
