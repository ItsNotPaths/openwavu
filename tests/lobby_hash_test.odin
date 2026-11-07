package tests

import "core:os"
import "core:testing"
import "../src/titlepack"

LOBBY_HASH_DIR :: "build/test_lobby_hash"
LOBBY_STOCK_DIR :: LOBBY_HASH_DIR + "/stock"

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
