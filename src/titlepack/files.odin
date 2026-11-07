package titlepack

import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

// A pack's files: its tar mapped into memory, or a folder (a stock base, or the front preview). files lists every
// path; a folder's entries hold no offsets.
Pack_Files :: struct {
	data:   []byte,
	files:  map[string]Tar_Entry,
	dir:    string,
	folder: ^Folder_Files,
}

// A folder's files, each mapped on its first read and kept until close_files: a big pack has more files than the
// kernel allows mappings.
Folder_Files :: struct {
	lock:   sync.Mutex,
	mapped: map[string]Folder_File,
}

Folder_File :: struct {
	data:   []byte,
	mapped: bool,  // else read whole: an empty file can not be mapped
}

open_files :: proc(path: string) -> (p: Pack_Files, ok: bool) {
	if os.is_dir(path) {
		paths, err := files_under(path, context.temp_allocator)
		if err != "" do return
		p = {dir = strings.clone(path), folder = new(Folder_Files)}
		for file in paths do p.files[strings.clone(file)] = {}
		return p, true
	}
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
	if p.folder != nil {
		for path, file in p.folder.mapped {
			if file.mapped do virtual.unmap_file(file.data)
			else do delete(file.data)
			delete(path)
		}
		delete(p.folder.mapped)
		free(p.folder)
	}
	delete(p.dir)
	p^ = {}
}

// A file's bytes, valid until close_files.
read_file :: proc(p: Pack_Files, path: string) -> (data: []byte, ok: bool) {
	if p.folder != nil do return read_folder_file(p, path)
	e := p.files[path] or_return
	return p.data[e.offset:][:e.size], true
}

@(private = "file")
read_folder_file :: proc(p: Pack_Files, path: string) -> (data: []byte, ok: bool) {
	if !(path in p.files) do return
	sync.guard(&p.folder.lock)
	if file, known := p.folder.mapped[path]; known do return file.data, true
	full, _ := filepath.join({p.dir, path}, context.temp_allocator)
	file: Folder_File
	map_err: virtual.Map_File_Error
	file.data, map_err = virtual.map_file_from_path(full, {.Read})
	file.mapped = map_err == nil
	if !file.mapped {
		read_err: os.Error
		if file.data, read_err = os.read_entire_file(full, context.allocator); read_err != nil do return
	}
	p.folder.mapped[strings.clone(path)] = file
	return file.data, true
}
