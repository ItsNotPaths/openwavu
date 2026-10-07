package tests

import "core:bytes"
import "core:os"
import "core:testing"
import "../src/ps3"

@(test)
eboot_decrypts_like_rpcs3 :: proc(t: ^testing.T) {
	self, e1 := os.read_entire_file(TK5 + "/game/USRDIR/EBOOT.BIN", context.temp_allocator)
	rap, e2 := os.read_entire_file(TK5 + "/game/USRDIR/UP0700-NPUB30009_00-0000000000000000.rap", context.temp_allocator)
	want, e3 := os.read_entire_file(TK5 + "/game/USRDIR/EBOOT.elf", context.temp_allocator)
	if e1 != nil || e2 != nil || e3 != nil do return
	elf, err := ps3.decrypt_self(self, rap, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(elf), len(want))
	testing.expect(t, bytes.equal(elf, want), "decrypted EBOOT differs from the RPCS3 output")
}

@(test)
sfo_title_id :: proc(t: ^testing.T) {
	sfo, err := os.read_entire_file(TK5 + "/game/PARAM.SFO", context.temp_allocator)
	if err != nil do return
	id, ok := ps3.read_sfo_string(sfo, "TITLE_ID")
	testing.expect(t, ok)
	testing.expect_value(t, id, "NPUB30009")
}
