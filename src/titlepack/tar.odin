// A pack file is one plain ustar tar (docs/packs.md).
package titlepack

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

TAR_BLOCK :: 512
MANIFEST :: "pack.toml"
MANIFEST_READ :: 8 * TAR_BLOCK  // one read holds the header and a usual pack.toml
MANIFEST_MAX :: 1 << 20

Tar_Entry :: struct {
	offset, size: int,
}

// Every file under dir into one tar at out_path. Same files, same bytes: paths sorted, times and owners zero.
// pack.toml goes first, so read_manifest finds it with one read.
write_tar :: proc(dir, out_path: string) -> (err: string) {
	paths: []string
	if paths, err = files_under(dir, context.temp_allocator); err != "" do return
	return write_tar_of({dir = dir}, paths, out_path)
}

// The given files of a pack, in that order, into one tar at out_path; pack.toml is moved first.
write_tar_of :: proc(from: Pack_Files, paths: []string, out_path: string) -> (err: string) {
	if i, found := slice.linear_search(paths, MANIFEST); found do slice.rotate_right(paths[:i + 1], 1)
	part := strings.concatenate({out_path, ".part"}, context.temp_allocator)
	out, open_err := os.open(part, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User})
	if open_err != nil do return strings.concatenate({"cannot write ", part})
	ok := true
	for path in paths {
		data, read := tar_input(from, path)
		header, fits := tar_header(path, len(data))
		ok = read && fits && write_block(out, header[:]) && write_block(out, data)
		if from.dir != "" do delete(data)
		if !ok {
			err = strings.concatenate({"cannot pack ", path})
			break
		}
	}
	zeros: [2 * TAR_BLOCK]byte
	ok = ok && write_block(out, zeros[:])
	os.close(out)
	if ok && os.rename(part, out_path) != nil do err = strings.concatenate({"cannot write ", out_path})
	if err != "" do os.remove(part)
	return
}

// A folder's file is read whole (the caller deletes it); a tar's is a slice of the mapping.
@(private = "file")
tar_input :: proc(from: Pack_Files, path: string) -> (data: []byte, ok: bool) {
	if from.dir == "" do return read_file(from, path)
	read_err: os.Error
	data, read_err = os.read_entire_file(join_path(from.dir, path), context.allocator)
	return data, read_err == nil
}

// Path -> where its bytes sit in data. Regular files and folders; pax `path` and GNU `L` entries for long names.
// Refused: links, devices, paths that leave the pack, and a path twice (a reviewer could read one copy, the game the other).
read_tar :: proc(data: []byte, allocator := context.allocator) -> (files: map[string]Tar_Entry, ok: bool) {
	files = make(map[string]Tar_Entry, allocator)
	long_name: string
	for at := 0; at + TAR_BLOCK <= len(data); {
		header := data[at:][:TAR_BLOCK]
		if slice.all_of(header, 0) do return files, true
		size, has_size := strconv.parse_int(field(header[124:136]), 8)
		body := at + TAR_BLOCK
		if !has_size || !checksum_ok(header) || size < 0 || body + size > len(data) do break
		name := long_name
		long_name = ""
		if name == "" {
			name = field(header[0:100])
			if prefix := field(header[345:500]); prefix != "" do name = strings.concatenate({prefix, "/", name}, context.temp_allocator)
		}
		kind := header[156]
		if kind == 'x' {
			long_name = pax_path(data[body:][:size])
		} else if kind == 'L' {
			long_name = field(data[body:][:size])
		} else if kind == '0' || kind == 0 {
			if !safe_path(name) || name in files do break
			files[strings.clone(name, allocator)] = {body, size}
		} else if kind != '5' && kind != 'g' {
			break
		}
		at = body + (size + TAR_BLOCK - 1) / TAR_BLOCK * TAR_BLOCK
	}
	destroy_tar(files)
	return nil, false
}

// pack.toml of the tar at path, read from the first entry only; a tar that does not start with it has none.
read_manifest :: proc(path: string, allocator := context.allocator) -> (text: string, ok: bool) {
	f, open_err := os.open(path)
	if open_err != nil do return
	defer os.close(f)
	buf: [MANIFEST_READ]byte
	n, _ := os.read_at(f, buf[:], 0)
	if n < TAR_BLOCK do return
	header := buf[:TAR_BLOCK]
	kind := header[156]
	if field(header[0:100]) != MANIFEST || field(header[345:500]) != "" || (kind != '0' && kind != 0) || !checksum_ok(header) do return
	size, has_size := strconv.parse_int(field(header[124:136]), 8)
	if !has_size || size < 0 || size > MANIFEST_MAX do return
	if TAR_BLOCK + size <= n do return strings.clone(string(buf[TAR_BLOCK:][:size]), allocator), true
	data := make([]byte, size, allocator)
	if got, _ := os.read_at(f, data, TAR_BLOCK); got != size {
		delete(data, allocator)
		return
	}
	return string(data), true
}

destroy_tar :: proc(files: map[string]Tar_Entry) {
	for path in files do delete(path)
	delete(files)
}

// A ustar file header. Names over 100 bytes split at a slash into prefix and name.
tar_header :: proc(path: string, size: int) -> (h: [TAR_BLOCK]byte, fits: bool) {
	name, prefix := path, ""
	if len(path) > 100 {
		cut := strings.last_index_byte(path[:min(len(path), 156)], '/')
		if cut < 0 || len(path) - cut - 1 > 100 do return
		prefix, name = path[:cut], path[cut + 1:]
	}
	copy(h[0:100], name)
	octal(h[100:108], 0o644)
	octal(h[108:116], 0)
	octal(h[116:124], 0)
	octal(h[124:136], size)
	octal(h[136:148], 0)
	h[156] = '0'
	copy(h[257:265], "ustar\x0000")
	copy(h[345:500], prefix)
	octal(h[148:156], checksum(h[:]))
	return h, true
}

@(private = "file")
octal :: proc(out: []byte, n: int) {
	n := n
	out[len(out) - 1] = 0
	#reverse for &digit in out[:len(out) - 1] {
		digit = '0' + byte(n & 7)
		n >>= 3
	}
}

// Header byte sum, the checksum field counted as spaces.
@(private = "file")
checksum :: proc(h: []byte) -> (sum: int) {
	for b, i in h do sum += i >= 148 && i < 156 ? ' ' : int(b)
	return
}

@(private = "file")
checksum_ok :: proc(h: []byte) -> bool {
	stored, ok := strconv.parse_int(field(h[148:156]), 8)
	return ok && stored == checksum(h)
}

// A NUL- or space-ended header field.
@(private = "file")
field :: proc(b: []byte) -> string {
	end := slice.linear_search(b, 0) or_else len(b)
	return strings.trim_space(string(b[:end]))
}

// Records are "<len> key=value\n".
@(private = "file")
pax_path :: proc(records: []byte) -> (path: string) {
	rest := string(records)
	for len(rest) > 0 {
		space := strings.index_byte(rest, ' ')
		length, ok := strconv.parse_int(rest[:max(space, 0)])
		if space < 0 || !ok || length <= space || length > len(rest) do return
		record := rest[space + 1:length - 1]
		if strings.has_prefix(record, "path=") do path = record[len("path="):]
		rest = rest[length:]
	}
	return
}

@(private)
safe_path :: proc(path: string) -> bool {
	if path == "" || path[0] == '/' || strings.contains_any(path, ":\\") do return false
	rest := path
	for part in strings.split_iterator(&rest, "/") do if part == ".." do return false
	return true
}

// Files under dir, relative with forward slashes, sorted.
@(private = "file")
files_under :: proc(dir: string, allocator := context.allocator) -> (paths: []string, err: string) {
	list := make([dynamic]string, allocator)
	base, abs_err := os.get_absolute_path(dir, allocator)  // the walker gives absolute paths
	if abs_err != nil do return nil, strings.concatenate({"cannot read ", dir})
	w := os.walker_create(base)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if info.type == .Directory do continue
		relative, rel_err := os.get_relative_path(base, info.fullpath, allocator)
		if rel_err != nil do return nil, strings.concatenate({"cannot read ", info.fullpath})
		slashed, _ := strings.replace_all(relative, "\\", "/", allocator)
		append(&list, slashed)
	}
	if path, walk_err := os.walker_error(&w); walk_err != nil do return nil, strings.concatenate({"cannot read ", path})
	slice.sort(list[:])
	return list[:], ""
}

@(private = "file")
join_path :: proc(dir, path: string) -> string {
	return strings.concatenate({dir, "/", path}, context.temp_allocator)
}

// Data padded to whole blocks.
@(private = "file")
write_block :: proc(f: ^os.File, data: []byte) -> bool {
	zeros: [TAR_BLOCK]byte
	pad := (TAR_BLOCK - len(data) % TAR_BLOCK) % TAR_BLOCK
	_, data_err := os.write(f, data)
	_, pad_err := os.write(f, zeros[:pad])
	return data_err == nil && pad_err == nil
}
