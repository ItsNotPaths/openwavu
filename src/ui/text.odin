package ui

import "base:runtime"
import "core:c"
import "core:math"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"
import clay "../../vendor/clay"

// A typeface role; the Clay fontId of a text element.
Font :: enum u16 {
	Body,
	Display,
}

@(private)
FONT_DATA := [Font][]u8 {
	.Body    = BODY_FONT,
	.Display = DISPLAY_FONT,
}

@(private)
Font_Key :: struct {
	face: Font,
	size: u16,
}

@(private)
init_text :: proc(ui: ^Ui) -> bool {
	if !ttf.Init() {
		return false
	}
	ui.text_engine = ttf.CreateRendererTextEngine(ui.renderer)
	clay.SetMeasureTextFunction(measure_text, ui)
	return ui.text_engine != nil
}

@(private)
destroy_text :: proc(ui: ^Ui) {
	for _, f in ui.fonts {
		ttf.CloseFont(f)
	}
	delete(ui.fonts)
	ttf.DestroyRendererTextEngine(ui.text_engine)
	ttf.Quit()
}

// One open font per face and size, opened on first use.
@(private)
font :: proc(ui: ^Ui, face: Font, size: u16) -> ^ttf.Font {
	key := Font_Key{face, size}
	if f, ok := ui.fonts[key]; ok {
		return f
	}
	data := FONT_DATA[face]
	f := ttf.OpenFontIO(sdl.IOFromConstMem(raw_data(data), uint(len(data))), true, f32(size))
	ui.fonts[key] = f
	return f
}

@(private)
text_size :: proc(ui: ^Ui, face: Font, str: string, size: u16) -> [2]f32 {
	f := font(ui, face, size)
	w, h: c.int
	ttf.GetStringSize(f, raw_data(str), len(str), &w, &h)
	return {f32(w), f32(ttf.GetFontHeight(f))}
}

@(private)
draw_text :: proc(ui: ^Ui, at: [2]f32, face: Font, str: string, size: u16, tint: [4]f32) {
	text := ttf.CreateText(ui.text_engine, font(ui, face, size), raw_data(str), len(str))
	defer ttf.DestroyText(text)
	ttf.SetTextColorFloat(text, tint.r, tint.g, tint.b, tint.a)
	ttf.DrawRendererText(text, math.round(at.x), math.round(at.y))
}

@(private)
measure_text :: proc "c" (str: clay.StringSlice, config: ^clay.TextElementConfig, user_data: rawptr) -> clay.Dimensions {
	context = runtime.default_context()
	size := text_size((^Ui)(user_data), Font(config.fontId), string(str.chars[:str.length]), config.fontSize)
	return {size.x, size.y}
}

// Plate names that don't fit scroll right to left, pause at the end, jump back, pause, and repeat.
@(private)
marquee :: proc(overflow, time: f32) -> f32 {
	travel := overflow / MARQUEE_SPEED
	t := math.mod(time, travel + 2 * MARQUEE_PAUSE)
	return clamp((t - MARQUEE_PAUSE) * MARQUEE_SPEED, 0, overflow)
}
