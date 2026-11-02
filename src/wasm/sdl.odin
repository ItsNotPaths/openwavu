// SDL3 for app modules: allowlisted SDL functions as imports with their SDL names (docs/app.md).
package wasm

// (hole sdl-imports :tags (wasm render sdk) :needs module-memory) no glue generated from SDL's dynapi list and the allowlist: no pointer bounds checks, no per-pack handle tables freed on unload, no deep copy of the GPU create infos.
link_sdl :: proc(l: Linker) -> (err: string) {
	return ""
}
