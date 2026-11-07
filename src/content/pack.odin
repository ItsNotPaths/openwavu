// A pack file at run time: its tar, read in place, and its databases in memory.
package content

import "core:fmt"
import "core:mem"
import "core:strings"
import "../db"
import "../titlepack"

DB_EXTENSION :: ".db"

Pack :: struct {
	files: titlepack.Pack_Files,
	dbs:   map[string]^db.Sqlite,  // by path; in memory, so patches from the packs above can apply
}

// A tar, or a stock pack's folder, over its bases: the stock folders its pack.toml names, the last one right under
// it. Each database loads from the top layer that has it, then every layer's <db>.patch applies to it, bottom first.
open_pack :: proc(path: string) -> (p: Pack, ok: bool) {
	p.files = titlepack.open_files(path) or_return
	p.dbs = make(map[string]^db.Sqlite)
	defer if !ok do close_pack(&p)
	stack_bases(&p.files) or_return
	layers := make([dynamic]^titlepack.Pack_Files, context.temp_allocator)
	for layer := &p.files; layer != nil; layer = layer.below do inject_at(&layers, 0, layer)
	for layer in layers do for file in layer.files {
		if !strings.has_suffix(file, DB_EXTENSION) || file in p.dbs do continue
		p.dbs[file] = load_db(p.files, file) or_return
	}
	for layer in layers do for file in layer.files {
		if !strings.has_suffix(file, DB_EXTENSION + PATCH_EXTENSION) do continue
		target := p.dbs[strings.trim_suffix(file, PATCH_EXTENSION)] or_return
		manifest := titlepack.read_file(layer^, titlepack.MANIFEST) or_return
		tp := titlepack.read_titlepack(string(manifest), context.temp_allocator) or_return
		patch := titlepack.read_file(layer^, file) or_return
		if err := apply_patch(target, patch, tp.id); err != "" {
			fmt.eprintfln("openwavu: %s %s: %s", tp.id, file, err)
			return
		}
	}
	return p, true
}

// The pack's bases under it, bottom first. A base is a stock pack: one with no bases of its own.
@(private = "file")
stack_bases :: proc(files: ^titlepack.Pack_Files) -> (ok: bool) {
	manifest := titlepack.read_file(files^, titlepack.MANIFEST) or_return
	tp := titlepack.read_titlepack(string(manifest), context.temp_allocator) or_return
	for base in tp.bases {
		layer := new(titlepack.Pack_Files)
		opened: bool
		if layer^, opened = titlepack.open_files(titlepack.base_path(base)); !opened {
			free(layer)
			return
		}
		layer.below = files.below
		files.below = layer
		base_manifest := titlepack.read_file(layer^, titlepack.MANIFEST) or_return
		base_tp := titlepack.read_titlepack(string(base_manifest), context.temp_allocator) or_return
		if len(base_tp.bases) > 0 do return
	}
	return true
}

close_pack :: proc(p: ^Pack) {
	for _, handle in p.dbs do db.close_v2(handle)
	delete(p.dbs)
	titlepack.close_files(&p.files)
	p^ = {}
}

// The bytes of a file as modules see it: a database as it is now in memory, else the tar's copy.
pack_file :: proc(p: Pack, path: string) -> (data: []byte, ok: bool) {
	if handle, is_db := p.dbs[path]; is_db {
		size: i64
		bytes := db.serialize(handle, "main", &size, db.SERIALIZE_NOCOPY)
		return bytes[:size], bytes != nil
	}
	return titlepack.read_file(p.files, path)
}

pack_size :: proc(p: Pack, path: string) -> (size: int, ok: bool) {
	data := pack_file(p, path) or_return
	return len(data), true
}

// Copies the file's bytes from offset into buf; returns how many, fewer at the end of the file.
pack_read :: proc(p: Pack, path: string, offset: int, buf: []byte) -> (n: int, ok: bool) {
	data := pack_file(p, path) or_return
	if offset < 0 || offset > len(data) do return
	return copy(buf, data[offset:]), true
}

// A copy of the file in an in-memory database that SQLite owns and frees on close.
@(private = "file")
load_db :: proc(files: titlepack.Pack_Files, path: string) -> (handle: ^db.Sqlite, ok: bool) {
	data := titlepack.read_file(files, path) or_return
	if db.open_v2(":memory:", &handle, db.OPEN_READWRITE, nil) != db.OK {
		db.close_v2(handle)
		return nil, false
	}
	copied := ([^]u8)(db.malloc64(u64(len(data))))
	if copied == nil {
		db.close_v2(handle)
		return nil, false
	}
	mem.copy(copied, raw_data(data), len(data))
	flags := u32(db.DESERIALIZE_FREEONCLOSE | db.DESERIALIZE_RESIZEABLE)
	if db.deserialize(handle, "main", copied, i64(len(data)), i64(len(data)), flags) != db.OK {
		db.close_v2(handle)  // FREEONCLOSE: SQLite frees copied even when the call fails
		return nil, false
	}
	return handle, true
}

