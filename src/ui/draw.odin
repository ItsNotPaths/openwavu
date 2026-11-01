package ui

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"

// (hole ui-font :tags game :sev gap) text uses SDL's 8x8 debug font, scaled; no TTF font or shaping.
// (hole ui-rounded :tags game :sev polish) corner radius is ignored; steel faces, windows and glows draw square.
draw :: proc(ui: ^Ui, commands: clay.ClayArray(clay.RenderCommand)) {
	r := ui.renderer
	for &command in commands.internalArray[:commands.length] {
		box := command.boundingBox
		rect := sdl.FRect{box.x, box.y, box.width, box.height}
		switch command.commandType {
		case .None, .Border:
		case .Rectangle:
			fill(r, rect, command.renderData.rectangle.backgroundColor / 255)
		case .Custom:
			paint(ui, rect, (^Paint)(command.renderData.custom.customData)^)
		case .Image:
			image := command.renderData.image
			if image.imageData != nil {
				sdl.RenderTexture(r, (^sdl.Texture)(image.imageData), nil, &rect)
			}
		case .Text:
			data := command.renderData.text
			str := string(data.stringContents.chars[:data.stringContents.length])
			if command.userData == &engraved_tag {
				text(r, {rect.x, rect.y + 1}, str, data.fontSize, color(0x000000ff))
			}
			text(r, {rect.x, rect.y}, str, data.fontSize, data.textColor / 255)
		case .ScissorStart:
			clip := sdl.Rect{i32(box.x), i32(box.y), i32(box.width), i32(box.height)}
			sdl.SetRenderClipRect(r, &clip)
		case .ScissorEnd:
			sdl.SetRenderClipRect(r, nil)
		}
	}
}

@(private)
engraved_tag: u8

// The debug font draws at a render scale, and SDL scales the clip rect with it, so the clip rect is
// divided by the scale while the text draws.
@(private)
text :: proc(r: ^sdl.Renderer, at: [2]f32, str: string, size: u16, c: [4]f32) {
	scale := f32(size) / sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE
	clipped := sdl.RenderClipEnabled(r)
	clip: sdl.Rect
	sdl.GetRenderClipRect(r, &clip)
	sdl.SetRenderDrawColorFloat(r, c.r, c.g, c.b, c.a)
	sdl.SetRenderScale(r, scale, scale)
	if clipped {
		x0, y0 := math.floor(f32(clip.x) / scale), math.floor(f32(clip.y) / scale)
		x1, y1 := math.ceil(f32(clip.x + clip.w) / scale), math.ceil(f32(clip.y + clip.h) / scale)
		scaled := sdl.Rect{i32(x0), i32(y0), i32(x1 - x0), i32(y1 - y0)}
		sdl.SetRenderClipRect(r, &scaled)
	}
	sdl.RenderDebugText(r, at.x / scale, at.y / scale, strings.clone_to_cstring(str, context.temp_allocator))
	sdl.SetRenderScale(r, 1, 1)
	if clipped {
		sdl.SetRenderClipRect(r, &clip)
	}
}

@(private)
text_width :: proc(str: string, size: u16) -> f32 {
	return f32(utf8.rune_count_in_string(str)) * f32(size)
}

@(private)
measure_text :: proc "c" (str: clay.StringSlice, config: ^clay.TextElementConfig, user_data: rawptr) -> clay.Dimensions {
	size := f32(config.fontSize)
	return {f32(utf8.rune_count_in_bytes(str.chars[:str.length])) * size, size}
}
