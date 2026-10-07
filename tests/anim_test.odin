// Anim decode must equal the game decode (../tk5decomp/sim/src/anim.c, fresh key mode per frame)
// bit for bit; skeletons must equal tools/skel.py. Hashes come from those references.
package tests

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:os"
import "core:testing"
import formats "../src/formats/tk5"

// Archive entry -> sha256 of every anim: u32 frames, then frames x 23 x 3 f32.
@(private = "file")
BANK_HASHES := [?]struct {
	entry: int,
	hash:  string,
}{
	{28, "eb45cdce2e4ef60f9877eb568fc5e7a66e6aabd832879119f3c1033f6aff8e49"},  // common
	{1528, "cd884706d8fac617d90daa7b62312ec2294815665a61b05a2fbeca3791cf969c"},  // paul
	{1542, "ce830c5368553781d7e35c2c6d1146fa810e4032b136b8a16ae522dc29db599f"},  // law
	{1563, "a8aa472dbffc1771950bc699817434043f9e5fd44b8db32ba3083c6c201aa30d"},  // lei
	{1577, "2cbbab573d34300e724a398b12c28c67794079d4e402fe4659711c92a2db94d6"},  // king
	{1591, "ec7333d1a74c5e689004ab8e39a984aa7285d18953c2c87e295fd1194a0c8720"},  // yoshimitsu
	{1612, "ef9c1a0ef68f6303aeb0215da1d0b22e37b7206abfeee4dc0dba34866f9301f3"},  // nina
	{1626, "13b5e749c4d17c509b0e04be805e942d3a98bff2154bf15b91a2e412e0904810"},  // hwoarang
	{1640, "5d31a314aa6f5be8b1b27e9b5681b431498ba2bec4a10e4204906520efdfb2e7"},  // xiaoyu
	{1675, "5cf81805cd94462c087013e80295369ebab1f16fd2fa38873ae5a6b78b20da8a"},  // christie
	{1689, "127d2a1e5a8a22498416ec96c48a5afb1624de7d7501693a60b6da639cd76e34"},  // eddy
	{1703, "5b7c003a4c433bdc2acba40e27877cc634c9a9aa0022b515f44bc906cc51953e"},  // jin
	{1724, "179902e806abbdcae4772ebc57292f6dd86f71802c5ea5d0420a52be999a4a43"},  // julia
	{1738, "e3cc42036a6f08b27b964b09d6b80434f6b1a454972fd49d8670670d6096f029"},  // kuma, panda
	{1752, "18bee96f06bf02ae592cd1ef5c2e1c51bd27776e6f44f6ce77c851e95ffd0529"},  // bryan
	{1766, "a68882f1e93b4641f2801dba11cd33f582283af49b7681e5da09e6e345cb6f65"},  // heihachi
	{1780, "67359bde9d72a5d495cf88213e2b5e5e422a4b9c65e1d3dc611eaae4ea9f35bd"},  // kazuya
	{1794, "0efdb8bc4153e31e124334d74d3828281e716dbf049c50b252dd05bb13cf730a"},  // lee
	{1815, "00e6e0c99aa2b25601c4f6b36572edbfd98b92cabb255ef735fc24a4b3c14f5e"},  // steve
	{1829, "02f23282ea78864d580c2f7f46695e369e9c6c8d892ca22ca2196379c5752b79"},  // marduk
	{1857, "89585af614b38b28743dd342f15e305100b8865015277a79ae8563f97faf547c"},  // jack5
	{1871, "1ef127b3e492eb416069876a86caf9b73fc2705bb7fd8bdad9f6090b92c91b40"},  // roger
	{1885, "29409560cf1bb492971b833c8d999610f19b9dcfd1aba7b5fb6a88d2a65380a4"},  // anna
	{1906, "fd54f171986b75be56928ba61cfa8bc00c88cadb1320da56b8c65df5272a2a53"},  // wang
	{1920, "6436820811f3fae311f9d06f808b3fab9935b3060235965583ce0e2770ea9c84"},  // ganryu
	{1941, "c91dbd40f089790da56022af9f278c93807b5e691afeb38982928fb97750931d"},  // asuka
	{1969, "3ae6b4885d04ccbda72b21490b41fd70e2267a1390bcbd4346f352a5a84c2065"},  // bruce
	{1990, "c3e6e42acb94a3ac0fc85e986ce34cbc75b18497eeef2f3c65290fd4b861107a"},  // baek
	{2004, "c20b51fe5c03a269e9c79315e331559a0d95461d30d79ccba383e3f715cffc71"},  // devil_jin
	{2018, "f55ed115f702e649e6721cff46180de64d26127d2dae92e093b1f66e2445624b"},  // raven
	{2039, "8408e43f108f14c29c47f62d5829f982d24d5e639839c17c165f814d9081ee66"},  // feng
	{2053, "528cbc3cfb717cd26d2ad31e5a63a2444a4587edc5689b5a6be17133850ad90e"},  // armor_king
	{2067, "05f2b39e98472ed9dbbfbd56dae9bbff53c2810b22a8e507ecf14b1745356039"},  // lili
	{2081, "e729845d76bdba11de0dc52d1dc367514efa736b72c64c9550878a0ed7dbdf2a"},  // dragunov
	{2095, "0b768723c418e091df657f209e2dd98889cf8585a6691100bad093e33099ed66"},  // jinpachi
}

// Section 12 of every character group model (entries 1534, 1541, ..): entry, scale, bones, list, ends.
@(private = "file")
SKELETONS_HASH :: "4076936745e7c9eebecc284093e2e14a824c447a63680c7d8a5761fba0de4aea"

@(test)
anims_decode_like_the_game :: proc(t: ^testing.T) {
	archive, ok := open_archive()
	if !ok do return
	defer close_archive(&archive)
	for b in BANK_HASHES {
		data := archive_entry(&archive, b.entry)
		if b.entry != formats.COMMON_ANIMS {
			secs, _ := formats.sections(data, context.temp_allocator)
			data = secs[0]
		}
		bank, bank_ok := formats.read_bank(data)
		testing.expectf(t, bank_ok, "entry %d: bank not read", b.entry)
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		for i in 0 ..< bank.count {
			a, anim_ok := formats.read_anim(bank, i, context.temp_allocator)
			testing.expectf(t, anim_ok, "entry %d anim %d not read", b.entry, i)
			frames := u32(a.frames)
			sha2.update(&ctx, ([^]byte)(&frames)[:4])
			sha2.update(&ctx, ([^]byte)(raw_data(a.values))[:len(a.values) * size_of(a.values[0])])
		}
		testing.expectf(t, digest_hex(&ctx) == b.hash, "entry %d: anims differ from the game decode", b.entry)
		free_all(context.temp_allocator)
	}
}

@(test)
skeletons_match_reference :: proc(t: ^testing.T) {
	archive, ok := open_archive()
	if !ok do return
	defer close_archive(&archive)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	put :: proc(ctx: ^sha2.Context_256, v: $T) {
		v := v
		sha2.update(ctx, ([^]byte)(&v)[:size_of(T)])
	}
	for entry := formats.CHARACTERS[0].container + formats.GROUP_MODEL; entry < formats.CHAR_GROUPS_END; entry += formats.GROUP_SIZE {
		secs, _ := formats.sections(archive_entry(&archive, entry), context.temp_allocator)
		s, s_ok := formats.read_skeleton(secs[12], context.temp_allocator)
		testing.expectf(t, s_ok, "entry %d: skeleton not read", entry)
		put(&ctx, u32(entry))
		put(&ctx, s.scale)
		put(&ctx, u32(len(s.bones)))
		for b in s.bones do put(&ctx, b)
		put(&ctx, u32(len(s.list)))
		for v in s.list do put(&ctx, v)
		put(&ctx, u32(len(s.ends)))
		for v in s.ends do put(&ctx, v)
		free_all(context.temp_allocator)
	}
	testing.expect(t, digest_hex(&ctx) == SKELETONS_HASH, "skeletons differ from skel.py")
}

@(private = "file")
Archive :: struct {
	table: []formats.Entry,
	data:  ^os.File,
}

@(private = "file")
open_archive :: proc() -> (a: Archive, ok: bool) {
	eboot, err := os.read_entire_file(TK5 + "/game/USRDIR/EBOOT.elf", context.temp_allocator)
	if err != nil do return {}, false
	build, _ := formats.find_build("NPUB30009")
	a.table = formats.read_file_table(eboot, build) or_return
	f, open_err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if open_err != nil {
		delete(a.table)
		return {}, false
	}
	a.data = f
	return a, true
}

@(private = "file")
close_archive :: proc(a: ^Archive) {
	os.close(a.data)
	delete(a.table)
}

@(private = "file")
archive_entry :: proc(a: ^Archive, index: int) -> []byte {
	e := a.table[index]
	stored := make([]byte, e.stored_size, context.temp_allocator)
	os.read_at(a.data, stored, formats.entry_offset(e))
	data, _ := formats.unpack_entry(e, stored, context.temp_allocator)
	return data
}

@(private = "file")
digest_hex :: proc(ctx: ^sha2.Context_256) -> string {
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(ctx, digest[:])
	return string(hex.encode(digest[:], context.temp_allocator))
}
