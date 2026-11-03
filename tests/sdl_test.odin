package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"
import "vendor:sdl3/ttf"
import "../src/content"
import "../src/imports"
import "../src/titlepack"
import "../src/wasm"

// A module draws shapes, a texture and text on the host's renderer through the SDL imports. A bad pointer, pixels past
// its memory, a handle that is not the pack's, of the wrong kind or destroyed, a stream two fonts would close, and a
// text whose font is closed each stop it before SDL runs.
@(test)
module_draws_through_sdl_imports :: proc(t: ^testing.T) {
	code, built := build_module(t, "tests/ref/sdl_probe.c")
	if !built do return

	dir := fmt.tprintf("build/%s", #procedure)
	os.make_directory(dir)
	defer os.remove_all(dir)
	font, _ := os.read_entire_file("vendor/fonts/Michroma-Regular.ttf", context.temp_allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/font.ttf", dir), font)
	_ = os.write_entire_file(fmt.tprintf("%s/%s", dir, titlepack.MANIFEST), transmute([]byte)string("id = \"x\"\nversion = \"1\"\n"))
	tar := fmt.tprintf("%s.tar", dir)
	if !testing.expect_value(t, titlepack.write_tar(dir, tar), "") do return
	defer os.remove(tar)
	p, opened := content.open_pack(tar)
	if !testing.expect(t, opened) do return
	defer content.close_pack(&p)

	if !testing.expect(t, ttf.Init()) do return
	defer ttf.Quit()
	surface := sdl.CreateSurface(16, 16, .RGBA32)
	defer sdl.DestroySurface(surface)
	renderer := sdl.CreateSoftwareRenderer(surface)
	defer sdl.DestroyRenderer(renderer)
	set := imports.sdl_set_create(renderer)
	defer imports.sdl_set_destroy(&set)

	r := rig_create(64 << 20)
	defer rig_destroy(r)
	testing.expect_value(t, imports.define_content(r.linker, &p), "")
	testing.expect_value(t, imports.define_sdl(r.linker, &set), "")
	m, compile_err := wasm.compile(r.engine, code)
	if !testing.expect_value(t, compile_err, "") do return
	defer wasm.module_destroy(m)
	inst, inst_err := wasm.instantiate(r.linker, r.store, m)
	if !testing.expect_value(t, inst_err, "") do return

	got := []wasm.Val{{}}
	testing.expect_value(t, wasm.call(r.store, inst, "draw", nil, got), "")
	testing.expect_value(t, got[0].of.i32, 1)
	testing.expect_value(t, wasm.call(r.store, inst, "text", nil, got), "")
	testing.expect_value(t, got[0].of.i32, 1)
	_ = sdl.FlushRenderer(renderer)
	pixel :: proc(s: ^sdl.Surface, x, y: int) -> [4]u8 {
		return ([^][4]u8)(s.pixels)[y * int(s.pitch) / 4 + x]
	}
	testing.expect_value(t, pixel(surface, 1, 1), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel(surface, 9, 1), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixel(surface, 6, 1), [4]u8{0, 0, 0, 0})
	lit := 0
	for y in 8 ..< 16 do for x in 0 ..< 16 do if pixel(surface, x, y).r > 0 do lit += 1
	testing.expectf(t, lit > 4, "text lit %d pixels", lit)

	traps := [][2]string{
		{"bad_rect", "SDL_RenderFillRect: argument 2 is outside the module's memory"},
		{"bad_handle", "SDL_RenderTexture: argument 2 is not a Texture handle"},
		{"pixels_past_memory", "SDL_UpdateTexture: argument 3 is outside the module's memory"},
		{"closeio_on_shared_stream", "TTF_OpenFontIO: closeio on a stream another font still reads"},
		{"stale_texture", "SDL_RenderTexture: argument 2 is not a Texture handle"},
		{"font_as_texture", "SDL_RenderTexture: argument 2 is not a Texture handle"},
		{"text_after_font_closed", "TTF_DrawRendererText: argument 1 is not a Text handle"},
	}
	for trap in traps {
		message := wasm.call(r.store, inst, trap[0])
		testing.expectf(t, strings.contains(message, trap[1]), "%s: got %q", trap[0], message)
	}
}

// An SDL function outside the allowlist (a window) is not there to link, so the module does not load.
@(test)
module_with_unlisted_sdl_call_does_not_load :: proc(t: ^testing.T) {
	set := imports.sdl_set_create(nil)
	defer imports.sdl_set_destroy(&set)
	r := rig_create()
	defer rig_destroy(r)
	testing.expect_value(t, imports.define_sdl(r.linker, &set), "")
	code, wat_err := wasm.wat_to_wasm(`(module (import "env" "SDL_CreateWindow" (func (param i32 i32 i32 i64) (result i32))))`, context.temp_allocator)
	if !testing.expect_value(t, wat_err, "") do return
	m, _ := wasm.compile(r.engine, code)
	defer wasm.module_destroy(m)
	_, err := wasm.instantiate(r.linker, r.store, m)
	testing.expectf(t, strings.contains(err, "SDL_CreateWindow"), "got %q", err)
}
