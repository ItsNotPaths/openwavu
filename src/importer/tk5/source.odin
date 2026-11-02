package tk5_importer

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import formats "../../formats/tk5"
import "../../ps3"

Game :: struct {
	build:       formats.Build,
	dir:         string,  // holds PARAM.SFO and the PS3 menu art
	eboot:       []byte,  // decrypted ELF, read for the archive file table
	data:        string,  // path to T55DATA1.BIN (574 MB, read per entry)
	data_sha256: string,
}

// Inputs: an RPCS3 dir (holds dev_hdd0/), or a game dir (holds PARAM.SFO) and optionally a .rap.
// Without a .rap input, the RAP is searched in the game's USRDIR and in RPCS3's exdata.
find_game :: proc(inputs: []string) -> (game: Game, err: string) {
	game_dir, rap_path, rpcs3_hdd: string
	for in_path in inputs {
		switch {
		case strings.has_suffix(strings.to_lower(in_path, context.temp_allocator), ".rap"): rap_path = in_path
		case os.exists(join(in_path, "PARAM.SFO")): game_dir = in_path
		case os.is_dir(join(in_path, "dev_hdd0")):
			rpcs3_hdd = join(in_path, "dev_hdd0")
		case: return game, fmt.tprintf("%s is not an RPCS3 dir, a game dir or a .rap file", in_path)
		}
	}
	if game_dir == "" && rpcs3_hdd != "" {
		for b in formats.BUILDS {
			dir := join(rpcs3_hdd, "game", b.title_id)
			if os.is_dir(dir) do game_dir = dir
		}
	}
	if game_dir == "" do return game, "no supported game found (Tekken 5 DR, NPUB30009)"

	sfo, sfo_err := os.read_entire_file(join(game_dir, "PARAM.SFO"), context.temp_allocator)
	if sfo_err != nil do return game, "cannot read PARAM.SFO"
	title_id, _ := ps3.read_sfo_string(sfo, "TITLE_ID")
	build, known := formats.find_build(title_id)
	if !known do return game, fmt.tprintf("unsupported game %q", title_id)

	if rap_path == "" {
		patterns := make([dynamic]string, context.temp_allocator)
		append(&patterns, join(game_dir, "USRDIR", "*.rap"))
		if rpcs3_hdd != "" do append(&patterns, join(rpcs3_hdd, "home", "*", "exdata", "*.rap"))
		for pattern in patterns {
			matches, _ := filepath.glob(pattern, context.temp_allocator)
			for m in matches do if strings.contains(m, title_id) do rap_path = m
		}
	}
	if rap_path == "" do return game, fmt.tprintf("no .rap license for %s; pass it as an input", title_id)

	self, self_err := os.read_entire_file(join(game_dir, "USRDIR", "EBOOT.BIN"), context.temp_allocator)
	rap, rap_err := os.read_entire_file(rap_path, context.temp_allocator)
	if self_err != nil || rap_err != nil do return game, "cannot read EBOOT.BIN or the .rap"
	elf, decrypt_err := ps3.decrypt_self(self, rap)
	if decrypt_err != "" do return game, decrypt_err
	if sha256_hex(elf) != build.elf_sha256 do return game, fmt.tprintf("%s EBOOT is a different version (game update?)", title_id)

	game.build = build
	game.dir = strings.clone(game_dir)
	game.eboot = elf
	game.data = strings.clone(join(game_dir, "USRDIR", "T55DATA1.BIN"))
	digest, io_err := hash.hash_file_by_name(.SHA256, game.data, allocator = context.temp_allocator)
	if io_err != nil do return game, "cannot read T55DATA1.BIN"
	game.data_sha256 = string(hex.encode(digest))
	return game, ""
}

destroy_game :: proc(game: Game) {
	delete(game.eboot)
	delete(game.dir)
	delete(game.data)
	delete(game.data_sha256)
}

sha256_hex :: proc(data: []byte) -> string {
	return string(hex.encode(hash.hash_bytes(.SHA256, data, context.temp_allocator), context.temp_allocator))
}

join :: proc(parts: ..string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}
