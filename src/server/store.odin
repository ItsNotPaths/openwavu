package server

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../titlepack"

// The files role's packs folder is the store (docs/network.md). A tar dropped in it is incorporated: renamed to
// <id>@<version>.tar, its front cut to <id>@<version>.front.tar, its thumb.png copied to <id>@<version>.thumb.png,
// and all of them hashed into <id>@<version>.sha256, written last. Each request reads the folder again, so `--prep` in another process needs no restart.
PACKS_DIR :: "/var/lib/openwavu/packs"

// Every tar in dir that is not incorporated yet.
incorporate_all :: proc(dir: string) {
	names, err := folder_names(dir)
	if err != "" {
		fmt.eprintfln("files: %s", err)
		return
	}
	for name in names {
		if !strings.has_suffix(name, ".tar") || strings.has_suffix(name, ".front.tar") do continue
		if os.exists(titlepack.join_path(dir, sidecar_name(strings.trim_suffix(name, ".tar")))) do continue
		if err = incorporate(dir, name); err != "" do fmt.eprintfln("files: %s: %s", name, err)
		else do fmt.eprintfln("files: %s incorporated", name)
	}
}

@(private = "file")
incorporate :: proc(dir, name: string) -> (err: string) {
	path := titlepack.join_path(dir, name)
	manifest, read := titlepack.read_manifest(path, context.temp_allocator)
	if !read do return "no pack.toml first in the tar"
	tp, parsed := titlepack.read_titlepack(manifest, context.temp_allocator)
	if !parsed do return "pack.toml does not read"
	if !plain_name(tp.id) || !plain_name(tp.version) do return "the id or version has characters a file name can not"
	stem := titlepack.pack_name(tp.id, tp.version)
	tar_name := strings.concatenate({stem, ".tar"}, context.temp_allocator)
	tar_path := titlepack.join_path(dir, tar_name)
	if name != tar_name {
		if os.exists(tar_path) do return fmt.tprintf("%s is already here", tar_name)
		if os.rename(path, tar_path) != nil do return "can not rename it"
	}
	files, opened := titlepack.open_files(tar_path)
	if !opened do return "the tar does not read"
	defer titlepack.close_files(&files)
	front_name := strings.concatenate({stem, ".front.tar"}, context.temp_allocator)
	if err = cut_front(files, titlepack.join_path(dir, front_name)); err != "" do return
	cut := make([dynamic]string, context.temp_allocator)
	append(&cut, tar_name, front_name)
	thumb_name := strings.concatenate({stem, ".thumb.png"}, context.temp_allocator)
	if thumb, has_thumb := titlepack.read_file(files, titlepack.THUMB); has_thumb {
		if os.write_entire_file(titlepack.join_path(dir, thumb_name), thumb) != nil do return "can not write the thumb"
		append(&cut, thumb_name)
	}
	sums: strings.Builder
	strings.builder_init(&sums, context.temp_allocator)
	for file in cut {
		sum, hashed := sha256_hex(titlepack.join_path(dir, file))
		if !hashed do return fmt.tprintf("can not hash %s", file)
		fmt.sbprintf(&sums, "%s  %s\n", sum, file)
	}
	sidecar := titlepack.join_path(dir, sidecar_name(stem))
	part := strings.concatenate({sidecar, ".part"}, context.temp_allocator)
	if os.write_entire_file(part, sums.buf[:]) != nil || os.rename(part, sidecar) != nil do return "can not write the hashes"
	return
}

// pack.toml, the front, its font and the files its elements use: what the launcher shows before a download.
@(private = "file")
cut_front :: proc(files: titlepack.Pack_Files, out_path: string) -> (err: string) {
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, titlepack.MANIFEST)
	if text, has_front := titlepack.read_file(files, titlepack.FRONT); has_front {
		append(&paths, titlepack.FRONT)
		front, front_err := titlepack.read_front(string(text), context.temp_allocator)
		if front_err != "" do return fmt.tprintf("the front does not read: %s", front_err)
		if missing := titlepack.missing_actions(front); missing != "" do return fmt.tprintf("the front has no button for: %s", missing)
		append(&paths, front.font)
		for element in front.elements do append(&paths, element.file)
	}
	used := make([dynamic]string, context.temp_allocator)
	for path in paths do if path != "" && path in files.files && !slice.contains(used[:], path) do append(&used, path)
	return titlepack.write_tar_of(files, used[:], out_path)
}

// Incorporated packs, newest version first within each id.
listing :: proc(dir: string) -> (packs: []titlepack.Listed) {
	names, err := folder_names(dir)
	if err != "" do return
	found := make([dynamic]titlepack.Listed, context.temp_allocator)
	for name in names {
		if !strings.has_suffix(name, ".sha256") do continue
		stem := strings.trim_suffix(name, ".sha256")
		id, at, version := strings.partition(stem, "@")
		if at == "" do continue
		sums, read_err := os.read_entire_file(titlepack.join_path(dir, name), context.temp_allocator)
		if read_err != nil do continue
		pack := titlepack.Listed{id = id, version = version}
		pack.sha256, pack.size = listed_file(dir, string(sums), strings.concatenate({stem, ".tar"}, context.temp_allocator))
		pack.front_sha256, pack.front_size = listed_file(dir, string(sums), strings.concatenate({stem, ".front.tar"}, context.temp_allocator))
		pack.thumb_sha256, pack.thumb_size = listed_file(dir, string(sums), strings.concatenate({stem, ".thumb.png"}, context.temp_allocator))
		if pack.sha256 != "" && pack.front_sha256 != "" do append(&found, pack)
	}
	slice.sort_by(found[:], proc(a, b: titlepack.Listed) -> bool {
		if a.id != b.id do return a.id < b.id
		return version_less(b.version, a.version)
	})
	return found[:]
}

// A file's hash from the sidecar's text, and its size on disk.
@(private = "file")
listed_file :: proc(dir, sums, file: string) -> (sha256: string, size: i64) {
	lines := sums
	for line in strings.split_lines_iterator(&lines) {
		sum, _, name := strings.partition(line, "  ")
		if name != file do continue
		info, stat_err := os.stat(titlepack.join_path(dir, file), context.temp_allocator)
		if stat_err != nil do return
		return sum, info.size
	}
	return
}

// "1.10" after "1.9": dot-separated numbers compared as numbers, anything else as text.
version_less :: proc(a, b: string) -> bool {
	a_parts, b_parts := strings.split(a, ".", context.temp_allocator), strings.split(b, ".", context.temp_allocator)
	for index in 0 ..< min(len(a_parts), len(b_parts)) {
		a_number, a_is := strconv.parse_int(a_parts[index])
		b_number, b_is := strconv.parse_int(b_parts[index])
		if a_is && b_is && a_number != b_number do return a_number < b_number
		if !(a_is && b_is) && a_parts[index] != b_parts[index] do return a_parts[index] < b_parts[index]
	}
	return len(a_parts) < len(b_parts)
}

@(private = "file")
folder_names :: proc(dir: string) -> (names: []string, err: string) {
	entries, read_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if read_err != nil do return nil, fmt.tprintf("can not read %s", dir)
	found := make([dynamic]string, context.temp_allocator)
	for entry in entries do append(&found, entry.name)
	return found[:], ""
}

@(private = "file")
sidecar_name :: proc(stem: string) -> string {
	return strings.concatenate({stem, ".sha256"}, context.temp_allocator)
}

@(private = "file")
plain_name :: proc(text: string) -> bool {
	if text == "" || text == "." || text == ".." do return false
	for character in text do if !(character == '.' || character == '-' || character == '_' || (character >= '0' && character <= '9') || (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')) do return false
	return true
}

@(private = "file")
sha256_hex :: proc(path: string) -> (text: string, ok: bool) {
	digest, err := hash.hash_file_by_name(.SHA256, path, allocator = context.temp_allocator)
	if err != nil do return
	return string(hex.encode(digest, context.temp_allocator)), true
}
