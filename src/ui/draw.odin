package ui

import "core:strings"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"

// (hole ui-font :tags game :sev gap) text uses SDL's 8x8 debug font, scaled; no TTF font or shaping.
// (hole ui-rounded :tags game :sev polish) corner radius is ignored; boxes and borders draw square.
draw :: proc(r: ^sdl.Renderer, commands: clay.ClayArray(clay.RenderCommand)) {
	for &command in commands.internalArray[:commands.length] {
		box := command.boundingBox
		rect := sdl.FRect{box.x, box.y, box.width, box.height}
		switch command.commandType {
		case .None, .Custom:
		case .Rectangle:
			fill(r, rect, command.renderData.rectangle.backgroundColor)
		case .Image:
			image := command.renderData.image
			if image.imageData != nil {
				sdl.RenderTexture(r, (^sdl.Texture)(image.imageData), nil, &rect)
			}
		case .Border:
			border(r, rect, command.renderData.border)
		case .Text:
			text(r, rect, command.renderData.text)
		case .ScissorStart:
			clip := sdl.Rect{i32(box.x), i32(box.y), i32(box.width), i32(box.height)}
			sdl.SetRenderClipRect(r, &clip)
		case .ScissorEnd:
			sdl.SetRenderClipRect(r, nil)
		}
	}
}

@(private)
fill :: proc(r: ^sdl.Renderer, rect: sdl.FRect, color: clay.Color) {
	rect := rect
	sdl.SetRenderDrawColorFloat(r, color.r / 255, color.g / 255, color.b / 255, color.a / 255)
	sdl.RenderFillRect(r, &rect)
}

@(private)
border :: proc(r: ^sdl.Renderer, rect: sdl.FRect, data: clay.BorderRenderData) {
	w := data.width
	x, y, width, height := rect.x, rect.y, rect.w, rect.h
	fill(r, {x, y, width, f32(w.top)}, data.color)
	fill(r, {x, y + height - f32(w.bottom), width, f32(w.bottom)}, data.color)
	fill(r, {x, y, f32(w.left), height}, data.color)
	fill(r, {x + width - f32(w.right), y, f32(w.right), height}, data.color)
}

@(private)
text :: proc(r: ^sdl.Renderer, rect: sdl.FRect, data: clay.TextRenderData) {
	color := data.textColor
	scale := f32(data.fontSize) / sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE
	str := strings.clone_to_cstring(string(data.stringContents.chars[:data.stringContents.length]), context.temp_allocator)
	sdl.SetRenderDrawColorFloat(r, color.r / 255, color.g / 255, color.b / 255, color.a / 255)
	sdl.SetRenderScale(r, scale, scale)
	sdl.RenderDebugText(r, rect.x / scale, rect.y / scale, str)
	sdl.SetRenderScale(r, 1, 1)
}

@(private)
measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user_data: rawptr) -> clay.Dimensions {
	size := f32(config.fontSize)
	return {f32(text.length) * size, size}
}
