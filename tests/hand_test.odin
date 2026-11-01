package tests

import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:testing"
import convert "../src/convert/tk5"
import "../src/db"
import formats "../src/formats/tk5"
import tk5 "../src/importer/tk5"

HAND_DUMP :: "build/hand_dump"
HAND_ROOT :: "build/hand_test"

// sha256 of tests/ref/hand_dump.c's output, taken from tk5decomp's .t5h through the game's bit decoder (visual/hand_bank.c
// before 2026-11-01).
@(private = "file")
HAND_HASHES := [?]struct {
	name, hash: string,
}{
	{"paul", "e9dc7ec0613176a6c5761a555eeb03ed9a8b0c2dca5dd478093589d9dd13b1d7"},
	{"law", "0a65ee308e4c49b4d7e1f540350e07e0bfcb04e4a96fdd572999abddc0065640"},
	{"lei", "6cec6d1188e4f4109acab9b6b077af5f4d0f5a536fdfce85ab74c1bd604b0868"},
	{"king", "7e6bd639e0a0f7f2345d69844b84c0be83dda88200af3968c44104e1c3d937dd"},
	{"yoshimitsu", "8ad5084970c3803faa18fd7d7ea354f5326df3296956410cb579d8aa8867e435"},
	{"nina", "d265162359c4e015f2716f329767f01be6ad7555b4e15d9beeb51a6819963d1d"},
	{"hwoarang", "a07b3f506b8da765d0d01d4c102941625a880bbbb928bc2905e10dc28f15ab0d"},
	{"xiaoyu", "ae95e8fe6861d341bd8fea61ef944b3cca94f557b739bfbab12078639d001576"},
	{"christie", "7890ed8d6590234336427e93ee483807a56a97d95bbcdd43ef3cf74eb67cefab"},
	{"jin", "e53c73acd001a375b0c93b9c5063443ca7f770f6360f6d93e2c12a670200fe5e"},
	{"julia", "cc2e8bcad56419a0f6f0e4ec3786cabbbb5a7de9239d93be9258aa7f7b533329"},
	{"kuma", "f545179dd7e2358870a1d46d263faaa125611766f6553adec92d61fc222c9f18"},
	{"bryan", "246a91dab033912fd328709017cf3b8035e155bfcc109243bbb57d56a4c7e256"},
	{"heihachi", "9f9a0bdc9022edea1bc7425976fcbe8aa0dab5394ddd60ab923fba06808d353c"},
	{"kazuya", "e2eee88a74d526d37c37a2bf5302a741af5a038f33da1304039bf88d2ef81968"},
	{"lee", "80504bd96413a3f25ee016bdac612197b363c58f7e4e2519728e5081b628fbc8"},
	{"steve", "bded30329ce39c34c2fcec9ae547f5913ea7bc113e4538531da93ca4ff7aa694"},
	{"marduk", "c57817004c37c454e9e010e5088527ebfb77db39ea603383369c1b004e3fe6c7"},
	{"jack5", "a26f06019aa7b93f09fe7046b49f327c3f9133a901c0dadb7b66696d9182ffd6"},
	{"roger", "986202a27cecaa5efc759e362d582cef632ee5309c1abad3aa61819f4e50bb86"},
	{"anna", "3472c2221f97c4ae1e6aa906850eca884d84cc80d91206a93b4920540381a1dd"},
	{"wang", "5fa60094aec2fd33bb843be6074446cf6223fa979f76d1c3dca9aaabde34c82b"},
	{"ganryu", "163ea3e60cf7df69f7ad2033b50fca744181d13ced1fe2d10e71aaaaccaadd3f"},
	{"asuka", "d029e00a7cd0dc5cca31bf80ff26eac1a4bf81ad7d4cb2d7fbaa9b538805134c"},
	{"bruce", "09896a26ddae866dd5e104a6e9a4434a6edaec282ab52ea0f0652ba1d86f3e5c"},
	{"baek", "d7e004ed3cf6fc2d9525dddc741a816c356773added62431da90ebda1f662629"},
	{"devil_jin", "7491819e47cf2539e529d0d845436db576ca02a4800a2c24ddde85977afdffd3"},
	{"raven", "dd572100d731c1fe50a9f668960fa554ff82442ce9f8c86a757f0284f59043bf"},
	{"feng", "9504fc2f623956aa7106086489e7faec2c58e1f60a7c27607460d2a6cfd6f55e"},
	{"armor_king", "e74d3c20767ff462ef977b41807dd36c1f74a62ead5af7bde8bbc5cc04676907"},
	{"lili", "63cfe3a465c1f8506d0312927fdedd5142e739430b0566800ab2cb514cbaf866"},
	{"dragunov", "310da52a956f93bf2389243829367edaab4ed1da116fe07c0c28c899258550bd"},
	{"panda", "f545179dd7e2358870a1d46d263faaa125611766f6553adec92d61fc222c9f18"},
	{"eddy", "1f46c71f8c322fad9a9359201b035519f67219a89f8a269b87ef78ddaa5b418d"},
	{"jinpachi", "c865c31b3069bfddb24eb3100e101525bb4934e5bb95809d7948723bcc5fe4fe"},
	{"jinpachi2", "7d2433cce1ce3caf95f788486a6d9aff96d128e06202766e45ba35d2c3d186ac"},
}

// The finger clips the visual loads from the db (modules/tk5/load.c) are the frames the game decodes, bit for bit.
@(test)
hand_clips_load_like_the_game :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)
	built := build_sim_tool(HAND_DUMP, "-Ivendor/sqlite", "tests/ref/hand_dump.c", "modules/tk5/load.c", "modules/tk5/sim/stage_file.c", "modules/tk5/sim/anim.c",
		"vendor/sqlite/libsqlite3.a", "-lpthread")
	if !testing.expect(t, built, "tests/ref/hand_dump.c did not build") do return

	os.remove_all(HAND_ROOT)
	defer os.remove_all(HAND_ROOT)
	im := tk5.Import{archive = {table, f}, root = HAND_ROOT}
	create_err: string
	im.w, create_err = db.create(HAND_ROOT + ".db", TK5_SCHEMA)
	if !testing.expect_value(t, create_err, "") do return
	defer os.remove(HAND_ROOT + ".db")

	characters := formats.CHARACTERS
	for name, i in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		packed, _ := tk5.read_entry(im.archive, formats.MOTBIN_FIRST + 2 * i)
		data, unpacked := formats.unlz(packed, context.temp_allocator)
		m, read := formats.read_motbin(data, context.temp_allocator)
		container, has := tk5.read_entry(im.archive, characters[i].container)
		sections, split := formats.sections(container, context.temp_allocator)
		if !testing.expect(t, unpacked && read && has && split && len(sections) > formats.BANK_HANDS, name) do continue
		owner := formats.container_owner(characters[i].container)
		testing.expect_value(t, convert.write_moveset_rows(&im.w, name, owner, i, m), "")  // the moves name the gesture owner
		tk5.write_hand_bank(&im, fmt.tprintf("%s/hand_poses", name), data[m.bank_offsets[formats.BANK_HANDS]:])
		if owner == name do tk5.write_hand_bank(&im, fmt.tprintf("%s/hand_gestures", owner), sections[formats.BANK_HANDS])
	}
	if !testing.expect_value(t, db.finish(&im.w), "") do return

	for h in HAND_HASHES {
		state, stdout, stderr, exec_err := os.process_exec({command = {HAND_DUMP, HAND_ROOT + ".db", HAND_ROOT, h.name}}, context.temp_allocator)
		if !testing.expectf(t, exec_err == nil && state.exit_code == 0, "%s: %s", h.name, string(stderr)) do continue
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, stdout)
		testing.expectf(t, digest_hex(&ctx) == h.hash, "%s: hand clips differ from the game decode", h.name)
	}
}
