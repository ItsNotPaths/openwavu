// Menu UI: Clay lays out boxes, widgets read one input model for mouse, keys and pad.
package ui

import "core:math"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"
import clay "../../vendor/clay"

Nav :: enum u8 {
	None,
	Up,
	Down,
	Left,
	Right,
}

// One frame of input. pad is set by the last key or pad press, cleared by mouse motion.
Input :: struct {
	mouse:         [2]f32,
	mouse_down:    bool,
	mouse_pressed: bool,
	wheel:         [2]f32,
	nav:           Nav,
	accept:        bool,
	back:          bool,
	pad:           bool,
}

Ui :: struct {
	renderer:  ^sdl.Renderer,
	textures:  Textures,
	text_engine: ^ttf.TextEngine,
	fonts:     map[Font_Key]^ttf.Font,
	motion:    map[u32]f32,
	input:     Input,
	typing:    Typing,
	size:      [2]f32,
	dt:        f32,
	time:      f32,
	focus:     clay.ElementId,
	focusable: [dynamic]clay.ElementId,
	memory:    []u8,
}

Widget_State :: struct {
	hovered, focused, clicked: bool,
}

init :: proc(ui: ^Ui, renderer: ^sdl.Renderer, size: [2]f32) -> bool {
	ui.renderer = renderer
	ui.textures = bake(renderer)
	ui.memory = make([]u8, clay.MinMemorySize())
	arena := clay.CreateArenaWithCapacityAndMemory(uint(len(ui.memory)), raw_data(ui.memory))
	clay.Initialize(arena, {size.x, size.y}, {handler = clay_error})
	return init_text(ui)
}

destroy :: proc(ui: ^Ui) {
	destroy_text(ui)
	unbake(ui.textures)
	delete(ui.motion)
	delete(ui.typing.edits)
	delete(ui.focusable)
	delete(ui.memory)
}

begin :: proc(ui: ^Ui, size: [2]f32, dt: f32) {
	ui.size = size
	ui.dt = dt
	ui.time += dt
	clear(&ui.focusable)
	clay.SetLayoutDimensions({size.x, size.y})
	clay.SetPointerState(ui.input.mouse, ui.input.mouse_down)
	clay.UpdateScrollContainers(false, ui.input.wheel * WHEEL_SPEED, dt)
	clay.BeginLayout()
}

end :: proc(ui: ^Ui) -> clay.ClayArray(clay.RenderCommand) {
	commands := clay.EndLayout()
	navigate(ui)
	end_typing(ui)
	pad := ui.input.pad
	ui.input = {mouse = ui.input.mouse, mouse_down = ui.input.mouse_down, pad = pad}
	return commands
}

// Hover, focus and click for the box with this id. Every widget goes through here.
interact :: proc(ui: ^Ui, id: clay.ElementId, nav := true) -> (s: Widget_State) {
	if nav {
		append(&ui.focusable, id)
	}
	s.hovered = !ui.input.pad && clay.PointerOver(id)
	if s.hovered && ui.input.mouse_pressed && nav {
		ui.focus = id
	}
	s.focused = nav && ui.input.pad && ui.focus.id == id.id
	s.clicked = (s.hovered && ui.input.mouse_pressed) || (s.focused && ui.input.accept)
	return
}

// Eases a value kept per id toward target, for lifts and slides. rate is roughly 3/seconds to settle.
ease :: proc(ui: ^Ui, id: clay.ElementId, target, rate: f32) -> f32 {
	v := ui.motion[id.id]
	v += (target - v) * (1 - math.exp(-rate * ui.dt))
	ui.motion[id.id] = v
	return v
}

// Spatial nav: move focus to the nearest focusable box in the pressed direction.
@(private)
navigate :: proc(ui: ^Ui) {
	if ui.input.nav == .None || len(ui.focusable) == 0 {
		return
	}
	from, ok := center(ui.focus)
	if !ok {
		ui.focus = ui.focusable[0]
		return
	}
	dir := NAV_DIRECTION[ui.input.nav]
	best := max(f32)
	for id in ui.focusable {
		to, found := center(id)
		if !found || id.id == ui.focus.id {
			continue
		}
		d := to - from
		along := d.x * dir.x + d.y * dir.y
		across := abs(d.x * dir.y - d.y * dir.x)
		score := along + 2 * across
		if along > 0 && score < best {
			best = score
			ui.focus = id
		}
	}
}

@(private)
NAV_DIRECTION := [Nav][2]f32 {
	.None  = {0, 0},
	.Up    = {0, -1},
	.Down  = {0, 1},
	.Left  = {-1, 0},
	.Right = {1, 0},
}

@(private)
center :: proc(id: clay.ElementId) -> (c: [2]f32, ok: bool) {
	data := clay.GetElementData(id)
	box := data.boundingBox
	return {box.x + box.width / 2, box.y + box.height / 2}, data.found
}

@(private)
clay_error :: proc "c" (error: clay.ErrorData) {
	panic_contextless(string(error.errorText.chars[:error.errorText.length]))
}
