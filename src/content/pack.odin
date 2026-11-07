// A pack file at run time: its tar, read in place, and its databases in memory.
package content

import "core:mem"
import "core:strings"
import "../db"
import "../titlepack"

DB_EXTENSION :: ".db"

Pack :: struct {
	files: titlepack.Pack_Files,
	dbs:   map[string]^db.Sqlite,  // by path; in memory, so patches from the packs above can apply
}

// A tar, or a stock pack's folder.
open_pack :: proc(path: string) -> (p: Pack, ok: bool) {
	p.files = titlepack.open_files(path) or_return
	p.dbs = make(map[string]^db.Sqlite)
	for file in p.files.files {
		if !strings.has_suffix(file, DB_EXTENSION) do continue
		handle, loaded := load_db(p.files, file)
		if !loaded {
			close_pack(&p)
			return {}, false
		}
		p.dbs[file] = handle
	}
	return p, true
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

// What a pack sees: its bases in pack.toml order, then the pack itself; the same path in a later layer wins.
// A stock pack has no bases and is a view of one layer.
View :: struct {
	layers: []Pack,
}

// (hole content-view :tags (content titlepack) :needs (patch-apply pack-base)) no file view of a pack over its stock base behind content_read (two layers: the base, then the pack), with the pack's db patch applied to the base's database.
open_view :: proc(tars: []string) -> (v: View, ok: bool) {
	return {}, false
}
