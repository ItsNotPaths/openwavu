package tests

import "core:os"
import "core:slice"
import "core:testing"
import "../src/online"
import "../src/online/wire"
import "../src/titlepack"

LOBBY_HASH_DIR :: "build/test_lobby_hash"
LOBBY_STOCK_DIR :: LOBBY_HASH_DIR + "/stock"
JOINABLE_DIR :: "build/test_joinable"
JOINABLE_STOCK_DIR :: JOINABLE_DIR + "/stock"

// Two players' stock folders match when only pack.toml differs (its [import] names each machine's paths); any other
// file, and any final param, changes the lobby hash.
@(test)
lobby_hash_covers_files_and_params :: proc(t: ^testing.T) {
	os.remove_all(LOBBY_HASH_DIR)
	defer os.remove_all(LOBBY_HASH_DIR)
	stock :: LOBBY_STOCK_DIR
	os.make_directory_all(stock + "/anims")
	testing.expect(t, os.write_entire_file(stock + "/pack.toml", "id = \"stock\"\nversion = \"1\"\n[import]\ninputs = [\"/home/one\"]\n") == nil)
	testing.expect(t, os.write_entire_file(stock + "/tk5.db", "rows") == nil)
	testing.expect(t, os.write_entire_file(stock + "/anims/paul.anim", "frames") == nil)
	tp := titlepack.Title_Pack{id = "stock", path = stock}
	params := make(map[string]string, context.temp_allocator)
	params["stage"] = "dragons_nest"
	params["damage_percent"] = "100"

	lobby_of :: proc(t: ^testing.T, stock: string, tp: titlepack.Title_Pack, params: map[string]string) -> titlepack.Hash {
		folder, folder_err := titlepack.folder_hash(stock)
		testing.expect_value(t, folder_err, "")
		testing.expect_value(t, titlepack.write_folder_hash(stock, folder), "")
		lobby, lobby_err := titlepack.lobby_hash(tp, params)
		testing.expect_value(t, lobby_err, "")
		return lobby
	}
	first := lobby_of(t, stock, tp, params)
	testing.expect(t, first == lobby_of(t, stock, tp, params), "the same folder and params hash the same")

	testing.expect(t, os.write_entire_file(stock + "/pack.toml", "id = \"stock\"\nversion = \"1\"\n[import]\ninputs = [\"/home/two\"]\n") == nil)
	testing.expect(t, first == lobby_of(t, stock, tp, params), "pack.toml is not hashed")

	params["damage_percent"] = "50"
	testing.expect(t, first != lobby_of(t, stock, tp, params), "a param changes the hash")
	params["damage_percent"] = "100"

	testing.expect(t, os.write_entire_file(stock + "/anims/paul.anim", "frameS") == nil)
	testing.expect(t, first != lobby_of(t, stock, tp, params), "a file changes the hash")
}

// The lobby list shows only lobbies this pack can play: its own id@version, the same lobby hash and room for one more
// member; a running match does not hide it (a new member watches the next). Picks the pack refuses are never joinable.
@(test)
lobby_joinable_needs_same_pack_and_hash :: proc(t: ^testing.T) {
	os.remove_all(JOINABLE_DIR)
	defer os.remove_all(JOINABLE_DIR)
	os.make_directory_all(JOINABLE_STOCK_DIR)
	testing.expect(t, os.write_entire_file(JOINABLE_STOCK_DIR + "/tk5.db", "rows") == nil)
	folder, folder_err := titlepack.folder_hash(JOINABLE_STOCK_DIR)
	testing.expect_value(t, folder_err, "")
	testing.expect_value(t, titlepack.write_folder_hash(JOINABLE_STOCK_DIR, folder), "")
	stage := titlepack.Param{name = "stage", kind = .Text, default = "dragons_nest", expose = true}
	tp := titlepack.Title_Pack{id = "stock", version = "1", path = JOINABLE_STOCK_DIR, params = []titlepack.Param{stage}}
	picks := make(map[string]string, context.temp_allocator)
	picks["stage"] = "acid_rain"
	hash, _, hash_err := titlepack.lobby_hash_text(tp, picks, context.temp_allocator)
	testing.expect_value(t, hash_err, "")

	hashes: online.Lobby_Hashes
	defer online.lobby_hashes_destroy(&hashes)
	host := []online.Lobby_Player{{key = "host"}}
	open := online.Lobby{pack = "stock@1", params = "stage=acid_rain", hash = hash, players = slice.to_dynamic(host, context.temp_allocator)}
	testing.expect(t, online.lobby_joinable(&hashes, tp, &open), "an open lobby of this pack")

	other_pack := open
	other_pack.pack = "stock@2"
	testing.expect(t, !online.lobby_joinable(&hashes, tp, &other_pack), "another version")
	other_hash := open
	other_hash.hash = "00"
	testing.expect(t, !online.lobby_joinable(&hashes, tp, &other_hash), "another lobby hash")
	refused := open
	refused.params = "rounds=9"
	testing.expect(t, !online.lobby_joinable(&hashes, tp, &refused), "picks this pack refuses")
	full := open
	full.players = make([dynamic]online.Lobby_Player, wire.LOBBY_MEMBERS_MAX, context.temp_allocator)
	testing.expect(t, !online.lobby_joinable(&hashes, tp, &full), "no room")
	playing := open
	playing.match = online.Lobby_Match{token = 1}
	testing.expect(t, online.lobby_joinable(&hashes, tp, &playing), "a match running")
}
