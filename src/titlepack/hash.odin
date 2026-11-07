// Lobby hash: what two players must share to play the same match. The pack's bytes, its bases' bytes and the final
// params. A tar is hashed whole; a stock folder by the <folder>.sha256 its importer writes.
package titlepack

import "core:crypto/hash"
import "core:encoding/hex"
import "core:os"
import "core:slice"
import "core:strings"

Hash :: [32]u8

// Every file under dir but pack.toml (its [import] names this machine's paths), as sorted "path NUL sha256" lines.
folder_hash :: proc(dir: string) -> (digest: Hash, err: string) {
	paths: []string
	if paths, err = files_under(dir, context.temp_allocator); err != "" do return
	folder: hash.Context
	hash.init(&folder, .SHA256)
	for path in paths {
		if path == MANIFEST do continue
		file, file_err := hash.hash_file_by_name(.SHA256, join_path(dir, path), allocator = context.temp_allocator)
		if file_err != nil do return {}, strings.concatenate({"cannot read ", path}, context.temp_allocator)
		hash.update(&folder, transmute([]byte)path)
		hash.update(&folder, {0})
		hash.update(&folder, file)
	}
	hash.final(&folder, digest[:])
	return
}

// The hash file of a stock folder: <dir>.sha256, hex.
folder_hash_path :: proc(dir: string) -> string {
	return strings.concatenate({dir, ".sha256"}, context.temp_allocator)
}

write_folder_hash :: proc(dir: string, digest: Hash) -> (err: string) {
	digest := digest
	text := strings.concatenate({string(hex.encode(digest[:], context.temp_allocator)), "\n"}, context.temp_allocator)
	if os.write_entire_file(folder_hash_path(dir), text) != nil do return strings.concatenate({"cannot write ", folder_hash_path(dir)}, context.temp_allocator)
	return
}

read_folder_hash :: proc(dir: string) -> (digest: Hash, ok: bool) {
	text, read_err := os.read_entire_file(folder_hash_path(dir), context.temp_allocator)
	if read_err != nil do return
	decoded := hex.decode(transmute([]byte)strings.trim_space(string(text)), context.temp_allocator) or_return
	if len(decoded) != len(digest) do return
	copy(digest[:], decoded)
	return digest, true
}

// A pack's own bytes: a tar's hash, or a stock folder's hash file.
pack_hash :: proc(tp: Title_Pack) -> (digest: Hash, err: string) {
	if os.is_dir(tp.path) {
		ok: bool
		if digest, ok = read_folder_hash(tp.path); !ok do err = strings.concatenate({tp.id, " has no hash: import it again"}, context.temp_allocator)
		return
	}
	file, file_err := hash.hash_file_by_name(.SHA256, tp.path, allocator = context.temp_allocator)
	if file_err != nil do return {}, strings.concatenate({"cannot read ", tp.path}, context.temp_allocator)
	copy(digest[:], file)
	return
}

// The pack, its bases in order, then the final params as sorted "name=value" lines.
lobby_hash :: proc(tp: Title_Pack, final: map[string]string) -> (digest: Hash, err: string) {
	lobby: hash.Context
	hash.init(&lobby, .SHA256)
	own: Hash
	if own, err = pack_hash(tp); err != "" do return
	hash.update(&lobby, own[:])
	for base in tp.bases {
		base_digest, ok := read_folder_hash(base_path(base))
		if !ok do return {}, strings.concatenate({base, " has no hash: import it again"}, context.temp_allocator)
		hash.update(&lobby, base_digest[:])
	}
	names, _ := slice.map_keys(final, context.temp_allocator)
	slice.sort(names)
	for name in names {
		hash.update(&lobby, transmute([]byte)strings.concatenate({name, "=", final[name], "\n"}, context.temp_allocator))
	}
	hash.final(&lobby, digest[:])
	return
}

// The lobby hash of a lobby's picks over this pack, as hex, and the final params it starts from; err when the pack
// refuses a pick.
lobby_hash_text :: proc(tp: Title_Pack, picks: map[string]string, allocator := context.allocator) -> (text: string, final: map[string]string, err: string) {
	if final, err = resolve_params(tp.params, picks, allocator); err != "" do return
	digest: Hash
	if digest, err = lobby_hash(tp, final); err != "" do return
	return string(hex.encode(digest[:], allocator)), final, ""
}
