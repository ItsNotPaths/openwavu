package ui

import sdl "vendor:sdl3"
import clay "../../vendor/clay"

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
			face := Font(data.fontId)
			if command.userData == &engraved_tag {
				draw_text(ui, {rect.x, rect.y + 1}, face, str, data.fontSize, color(0x000000ff))
			}
			draw_text(ui, {rect.x, rect.y}, face, str, data.fontSize, data.textColor / 255)
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
