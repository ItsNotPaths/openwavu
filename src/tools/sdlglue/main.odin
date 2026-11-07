// sdlglue: writes src/imports/sdl_glue.odin, the pack SDL imports, from sdl_allow.txt and SDL's own signatures.
// Run from the repo root; build.sh runs it when an input is newer than the output.
package sdlglue

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

ALLOW :: "src/imports/sdl_allow.txt"
DYNAPI :: "vendor/sdl3/dynapi/SDL_dynapi_procs.h"
TTF :: "vendor/sdl3_ttf/include/SDL3_ttf/SDL_ttf.h"
OUT :: "src/imports/sdl_glue.odin"

Entry :: struct {
	name:          string,
	counts:        map[int]int,  // argument -> the argument holding its item count, both from 1
	destroy, hand: bool,
	result:        string,       // C types without const or spaces: "SDL_Texture*", "Uint8"
	params:        [dynamic]string,
}

// A scalar C type as a wasm value: its Odin type, how to read it from a Val ($ is the Val) and how to return it.
Scalar :: struct {
	valtype, odin, read, write: string,
}

main :: proc() {
	entries, err := read_allow()
	if err == "" do err = add_signatures(entries)
	if err == "" do err = write_glue(entries)
	if err != "" {
		fmt.eprintfln("sdlglue: %s", err)
		os.exit(1)
	}
}

scalar :: proc(c: string) -> (s: Scalar, ok: bool) {
	switch c {
	case "int", "Sint32", "SDL_PixelFormat", "SDL_TextureAccess", "SDL_ScaleMode", "SDL_FlipMode", "SDL_BlendFactor", "SDL_BlendOperation":
		return {"I32", "i32", "$.of.i32", "wasm.i32_val($)"}, true
	case "Uint32", "SDL_BlendMode", "TTF_FontStyleFlags":
		return {"I32", "u32", "u32($.of.i32)", "wasm.i32_val(i32($))"}, true
	case "Uint8":
		return {"I32", "u8", "u8($.of.i32)", "wasm.i32_val(i32($))"}, true
	case "bool":
		return {"I32", "bool", "$.of.i32 != 0", "wasm.i32_val(i32($))"}, true
	case "size_t":
		return {"I32", "uint", "uint(u32($.of.i32))", "wasm.i32_val(i32($))"}, true
	case "float":
		return {"F32", "f32", "$.of.f32", "wasm.f32_val($)"}, true
	case "double":
		return {"F64", "f64", "$.of.f64", "wasm.f64_val($)"}, true
	}
	return
}

// The Sdl_Kind of an SDL object type.
handle_kind :: proc(c: string) -> (kind: string, ok: bool) {
	switch c {
	case "SDL_Renderer*": return "Renderer", true
	case "SDL_Texture*": return "Texture", true
	case "SDL_IOStream*": return "IO_Stream", true
	case "SDL_Surface*": return "Surface", true
	case "TTF_Font*": return "Font", true
	case "TTF_TextEngine*": return "Text_Engine", true
	case "TTF_Text*": return "Text", true
	case "SDL_AudioStream*": return "Audio_Stream", true
	}
	return
}

// Bytes per item behind a pointer type; these structs have no pointers inside, so wasm32 and the host lay them out alike.
item_size :: proc(c: string) -> (size: int, ok: bool) {
	switch c {
	case "char*", "void*": return 1, true
	case "int*", "float*", "SDL_Color*": return 4, true
	case "SDL_FPoint*": return 8, true
	case "SDL_FRect*", "SDL_Rect*", "SDL_FColor*": return 16, true
	case "SDL_Vertex*": return 32, true
	}
	return
}

read_allow :: proc() -> (entries: [dynamic]Entry, err: string) {
	text, read_err := os.read_entire_file(ALLOW, context.allocator)
	if read_err != nil do return nil, "can not read " + ALLOW
	for raw_line in strings.split_lines(string(text)) {
		line := strings.trim_space(raw_line)
		if comment := strings.index(line, "//"); comment >= 0 do line = strings.trim_space(line[:comment])
		if line == "" do continue
		words := strings.fields(line)
		e := Entry{name = words[0]}
		for word in words[1:] {
			switch word {
			case "destroy": e.destroy = true
			case "hand": e.hand = true
			case:
				arg, _, count := strings.partition(word, "=")
				a, a_ok := strconv.parse_int(arg)
				c, c_ok := strconv.parse_int(count)
				if !a_ok || !c_ok do return nil, fmt.tprintf("%s: unknown note %q", e.name, word)
				e.counts[a] = c
			}
		}
		append(&entries, e)
	}
	return
}

add_signatures :: proc(entries: [dynamic]Entry) -> (err: string) {
	dynapi, dynapi_err := os.read_entire_file(DYNAPI, context.allocator)
	ttf, ttf_err := os.read_entire_file(TTF, context.allocator)
	if dynapi_err != nil || ttf_err != nil do return "can not read " + DYNAPI + " or " + TTF
	for &e in entries {
		result, params: string
		found := false
		if strings.has_prefix(e.name, "TTF_") {
			result, params, found = ttf_signature(string(ttf), e.name)
		} else {
			result, params, found = dynapi_signature(string(dynapi), e.name)
		}
		if !found do return fmt.tprintf("%s: not in SDL's headers", e.name)
		e.result = c_type(result)
		if strings.trim_space(params) != "void" {
			for param in strings.split(params, ",") do append(&e.params, c_type(drop_name(param)))
		}
		if err = check(e); err != "" do return
	}
	return
}

// SDL_DYNAPI_PROC(result,name,(params),(args),return)
dynapi_signature :: proc(text, name: string) -> (result, params: string, ok: bool) {
	at := strings.index(text, fmt.tprintf(",%s,(", name))
	if at < 0 do return
	start := strings.last_index(text[:at], "SDL_DYNAPI_PROC(") + len("SDL_DYNAPI_PROC(")
	open := at + len(name) + 3
	return text[start:at], text[open:][:strings.index(text[open:], ")")], true
}

// extern SDL_DECLSPEC result SDLCALL name(params);
ttf_signature :: proc(text, name: string) -> (result, params: string, ok: bool) {
	at := strings.index(text, fmt.tprintf(" SDLCALL %s(", name))
	if at < 0 do return
	start := strings.last_index(text[:at], "SDL_DECLSPEC ") + len("SDL_DECLSPEC ")
	open := at + len(" SDLCALL (") + len(name)
	return text[start:at], text[open:][:strings.index(text[open:], ");")], true
}

// "const SDL_FRect *rect" -> "const SDL_FRect *"
drop_name :: proc(param: string) -> string {
	p := strings.trim_space(param)
	end := len(p)
	for end > 0 && is_word(p[end - 1]) do end -= 1
	return p[:end]
}

is_word :: proc(b: byte) -> bool {
	return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

// "const SDL_FRect *" -> "SDL_FRect*"
c_type :: proc(c: string) -> string {
	t, _ := strings.replace_all(c, "const ", "")
	t, _ = strings.replace_all(t, " ", "")
	return t
}

// Every type of a generated function must be known; hand functions only need to exist.
check :: proc(e: Entry) -> (err: string) {
	if e.hand do return
	if err = check_params(e); err != "" do return
	return check_result(e)
}

check_params :: proc(e: Entry) -> (err: string) {
	for p, i in e.params {
		arg := i + 1
		if _, ok := scalar(p); ok do continue
		if _, ok := handle_kind(p); ok do continue
		if _, ok := item_size(p); !ok do return fmt.tprintf("%s: argument %d has unknown type %s", e.name, arg, p)
		if count, has := e.counts[arg]; has {
			if count < 1 || count > len(e.params) do return fmt.tprintf("%s: argument %d counts by a missing argument", e.name, arg)
			if _, ok := scalar(e.params[count - 1]); !ok do return fmt.tprintf("%s: argument %d is not a count", e.name, count)
		}
	}
	return
}

// A made handle is owned by the handles it was made with, at most 2 (Sdl_Object.owners).
check_result :: proc(e: Entry) -> (err: string) {
	if e.result == "void" do return
	if _, ok := scalar(e.result); ok do return
	if _, ok := handle_kind(e.result); !ok do return fmt.tprintf("%s: unknown result type %s", e.name, e.result)
	if e.destroy do return fmt.tprintf("%s: a destroy function makes nothing", e.name)
	owners := 0
	for p in e.params do if _, is := handle_kind(p); is do owners += 1
	if owners > 2 do return fmt.tprintf("%s: more than 2 owners", e.name)
	return
}

write_glue :: proc(entries: [dynamic]Entry) -> (err: string) {
	b: strings.Builder
	fmt.sbprintln(&b, "// Generated by src/tools/sdlglue from sdl_allow.txt; do not edit.")
	fmt.sbprintln(&b, "package imports\n")
	fmt.sbprintln(&b, "import \"base:runtime\"")
	fmt.sbprintln(&b, "import sdl \"vendor:sdl3\"")
	fmt.sbprintln(&b, "import \"vendor:sdl3/ttf\"")
	fmt.sbprintln(&b, "import \"../wasm\"\n")

	fmt.sbprintln(&b, "@(private)\nsdl_glue :: proc() -> []Sdl_Define {")
	fmt.sbprintln(&b, "\t@(static) defines := [?]Sdl_Define{")
	for e in entries do if !e.hand {
		fmt.sbprintf(&b, "\t\t{{%q, {{", e.name)
		for p, i in e.params do fmt.sbprintf(&b, "%swasm.%s", i > 0 ? ", " : "", valtype(p))
		fmt.sbprint(&b, "}, {")
		if e.result != "void" do fmt.sbprintf(&b, "wasm.%s", valtype(e.result))
		fmt.sbprintfln(&b, "}}, import_%s}},", e.name)
	}
	fmt.sbprintln(&b, "\t}\n\treturn defines[:]\n}\n")

	fmt.sbprintln(&b, "@(private)\nsdl_destroy_object :: proc(kind: Sdl_Kind, pointer: rawptr) {")
	fmt.sbprintln(&b, "\t#partial switch kind {")
	for e in entries do if e.destroy {
		kind, _ := handle_kind(e.params[0])
		fmt.sbprintfln(&b, "\tcase .%s: %s(pointer)", kind, e.name)
	}
	fmt.sbprintln(&b, "\t}\n}")

	for e in entries do if !e.hand do write_import(&b, e)

	// The binding's procs, called with plain C types: Odin allows one foreign signature per symbol.
	for e in entries do if !e.hand {
		params, types: [dynamic]string
		for p, i in e.params {
			append(&params, fmt.tprintf("p%d: %s", i + 1, odin_type(p)))
			append(&types, odin_type(p))
		}
		result := e.result == "void" ? "" : fmt.tprintf(" -> %s", odin_type(e.result))
		library, name := "sdl", e.name[len("SDL_"):]
		if strings.has_prefix(e.name, "TTF_") do library, name = "ttf", e.name[len("TTF_"):]
		fmt.sbprintfln(&b, "\n@(private = \"file\")\n%s :: proc(%s)%s {{", e.name, strings.join(params[:], ", "), result)
		fmt.sbprintfln(&b, "\t%s(proc \"c\" (%s)%s)(rawptr(%s.%s))(%s)", result != "" ? "return " : "", strings.join(types[:], ", "), result, library, name, arg_list(len(e.params)))
		fmt.sbprintln(&b, "}")
	}
	if write_err := os.write_entire_file(OUT, b.buf[:]); write_err != nil do return "can not write " + OUT
	return
}

write_import :: proc(b: ^strings.Builder, e: Entry) {
	fmt.sbprintfln(b, "\n@(private = \"file\")\nimport_%s :: proc \"c\" (env: rawptr, caller: ^wasm.C_Caller, args: [^]wasm.Val, nargs: uint, results: [^]wasm.Val, nresults: uint) -> ^wasm.C_Trap {{", e.name)
	fmt.sbprintln(b, "\tcontext = runtime.default_context()")
	fmt.sbprintfln(b, "\tcall := sdl_call(env, caller, %q)", e.name)
	owners: [dynamic]string
	for p, i in e.params {
		arg := i + 1
		value := fmt.tprintf("args[%d]", i)
		if s, ok := scalar(p); ok {
			fmt.sbprintfln(b, "\tp%d := %s", arg, fill(s.read, value))
		} else if kind, is_handle := handle_kind(p); is_handle {
			declare := e.destroy ? "_ =" : fmt.tprintf("p%d :=", arg)  // a destroy only checks its handle
			fmt.sbprintfln(b, "\t%s sdl_handle(&call, %d, %s, .%s)", declare, arg, value, kind)
			append(&owners, fmt.tprintf("u32(%s.of.i32)", value))
		} else if count, has := e.counts[arg]; has && p == "char*" {
			fmt.sbprintfln(b, "\tp%d := sdl_text(&call, %d, %s, u64(u32(args[%d].of.i32)))", arg, arg, value, count - 1)
		} else if p == "char*" {
			fmt.sbprintfln(b, "\tp%d := sdl_text(&call, %d, %s, 0)", arg, arg, value)
		} else if has {
			size, _ := item_size(p)
			fmt.sbprintfln(b, "\tp%d := sdl_bytes(&call, %d, %s, u64(u32(args[%d].of.i32)) * %d)", arg, arg, value, count - 1, size)
		} else {
			size, _ := item_size(p)
			fmt.sbprintfln(b, "\tp%d := sdl_bytes(&call, %d, %s, %d)", arg, arg, value, size)
		}
	}
	fmt.sbprintln(b, "\tif call.error != \"\" do return wasm.trap(call.error)")
	if e.destroy {
		fmt.sbprintln(b, "\tsdl_destroy(call.set, u32(args[0].of.i32))")
		if e.result != "void" do fmt.sbprintln(b, "\tresults[0] = wasm.i32_val(1)")
		fmt.sbprintln(b, "\treturn nil\n}")
		return
	}
	for len(owners) < 2 do append(&owners, "0")
	call_text := fmt.tprintf("%s(%s)", e.name, arg_list(len(e.params)))
	if kind, is_handle := handle_kind(e.result); is_handle {
		fmt.sbprintfln(b, "\tresults[0] = wasm.i32_val(i32(sdl_new(call.set, .%s, %s, {{%s}})))", kind, call_text, strings.join(owners[:], ", "))
	} else if s, ok := scalar(e.result); ok {
		fmt.sbprintfln(b, "\tresults[0] = %s", fill(s.write, call_text))
	} else {
		fmt.sbprintfln(b, "\t%s", call_text)
	}
	fmt.sbprintln(b, "\treturn nil\n}")
}

valtype :: proc(c: string) -> string {
	if s, ok := scalar(c); ok do return s.valtype
	return "I32"  // handles and pointers
}

odin_type :: proc(c: string) -> string {
	if s, ok := scalar(c); ok do return s.odin
	return "rawptr"
}

fill :: proc(template, value: string) -> string {
	out, _ := strings.replace_all(template, "$", value)
	return out
}

arg_list :: proc(n: int) -> string {
	names := make([]string, n)
	for i in 0 ..< n do names[i] = fmt.tprintf("p%d", i + 1)
	return strings.join(names, ", ")
}
