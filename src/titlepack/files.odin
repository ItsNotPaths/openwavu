package titlepack

import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

// A pack's files: its tar mapped into memory, or a folder (the front preview).
// (hole pack-view :tags titlepack :needs pack-base) only the pack's own files; its bases' files are not layered under them.
Pack_Files :: struct {
	data:  []byte,
	files: map[string]Tar_Entry,
	dir:   string,
}

open_files :: proc(path: string) -> (p: Pack_Files, ok: bool) {
	if os.is_dir(path) do return {dir = strings.clone(path)}, true
	data, err := virtual.map_file_from_path(path, {.Read})
	if err != nil do return
	files, read := read_tar(data)
	if !read {
		virtual.unmap_file(data)
		return
	}
	return {data = data, files = files}, true
}

close_files :: proc(p: ^Pack_Files) {
	if p.data != nil do virtual.unmap_file(p.data)
	if p.files != nil do destroy_tar(p.files)
	delete(p.dir)
	p^ = {}
}

// A file's bytes, valid until close_files; a folder's are read into temp memory.
read_file :: proc(p: Pack_Files, path: string) -> (data: []byte, ok: bool) {
	if p.dir != "" {
		if !safe_path(path) do return
		full, _ := filepath.join({p.dir, path}, context.temp_allocator)
		read_err: os.Error
		data, read_err = os.read_entire_file(full, context.temp_allocator)
		return data, read_err == nil
	}
	e := p.files[path] or_return
	return p.data[e.offset:][:e.size], true
}
