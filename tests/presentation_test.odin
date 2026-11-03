package tests

import "core:os"
import "core:testing"
import sdl "vendor:sdl3"
import "../src/content"
import "../src/imports"
import "../src/presentation"
import "../src/wasm"

// The entry module starts and draws each frame; after the frame the host has its draw color and clip back, and a
// frame that traps comes back as an error (the host then cuts off the pack).
@(test)
entry_module_draws_and_hands_back_the_renderer :: proc(t: ^testing.T) {
	bytes, built := build_module(t, "tests/ref/entry_probe.c")
	if !built do return
	tar, written := write_test_pack(t, #procedure)
	if !written do return
	defer os.remove(tar)
	pack, opened := content.open_pack(tar)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&pack)
	surface := sdl.CreateSurface(4, 4, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	set := imports.sdl_set_create(renderer)
	defer imports.sdl_set_destroy(&set)

	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	code, compile_err := wasm.compile(engine, bytes)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(code)
	entry, err := presentation.start(engine, code, "entry_probe.wasm", &pack, &set)
	if !testing.expect_value(t, err, "") do return
	defer imports.module_destroy(entry)

	testing.expect_value(t, presentation.frame(entry, &set, 1.0 / 60), "")
	_ = sdl.FlushRenderer(renderer)
	pixels := ([^][4]u8)(surface.pixels)
	testing.expect_value(t, pixels[1 * int(surface.pitch) / 4 + 1], [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixels[3 * int(surface.pitch) / 4 + 3], [4]u8{0, 0, 0, 0})
	color: [4]u8
	_ = sdl.GetRenderDrawColor(renderer, &color.r, &color.g, &color.b, &color.a)
	testing.expect_value(t, color, [4]u8{0, 0, 0, 255})
	testing.expect(t, !sdl.RenderClipEnabled(renderer))

	testing.expect(t, presentation.frame(entry, &set, 1.0 / 60) != "")
}
