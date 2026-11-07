package titlepack

import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

// A pack's files: its tar mapped into memory, or a folder (a stock base, or the front preview). files lists this
// layer's paths; a folder's entries hold no offsets. below is the base this pack sits on: a path this layer lacks is
// read there.
Pack_Files :: struct {
	data:   []byte,
	files:  map[string]Tar_Entry,
	dir:    string,
	folder: ^Folder_Files,
	below:  ^Pack_Files,  // owned: closed with this one
}

// A folder's files, each mapped on its first read and kept until close_files: a big pack has more files than the
// kernel allows mappings.
Folder_Files :: struct {
	lock:      sync.Mutex,
	mapped:    map[string]Folder_File,
	allocator: mem.Allocator,  // the opener's: reads come from wasm imports, which run in a default context
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
		p.folder.allocator = context.allocator
		p.folder.mapped = make(map[string]Folder_File, context.allocator)
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
			else do delete(file.data, p.folder.allocator)
			delete(path, p.folder.allocator)
		}
		delete(p.folder.mapped)
		free(p.folder)
	}
	if p.below != nil {
		close_files(p.below)
		free(p.below)
	}
	delete(p.dir)
	p^ = {}
}

// A file's bytes from the top layer that has it, valid until close_files.
read_file :: proc(p: Pack_Files, path: string) -> (data: []byte, ok: bool) {
	if p.folder != nil {
		if data, ok = read_folder_file(p, path); ok do return
	} else if e, has := p.files[path]; has {
		return p.data[e.offset:][:e.size], true
	}
	if p.below != nil do return read_file(p.below^, path)
	return
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
		if file.data, read_err = os.read_entire_file(full, p.folder.allocator); read_err != nil do return
	}
	p.folder.mapped[strings.clone(path, p.folder.allocator)] = file
	return file.data, true
}
