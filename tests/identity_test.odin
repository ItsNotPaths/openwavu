package tests

import "core:os"
import "core:testing"
import "../src/online"

IDENTITY_DIR :: "build/identity_test"

// The first load makes the key, later loads give the same player id, and a file that does not read is an error and is
// never replaced. A signature checks only against its own message.
@(test)
identity_key_is_kept :: proc(t: ^testing.T) {
	os.remove_all(IDENTITY_DIR)
	defer os.remove_all(IDENTITY_DIR)
	os.make_directory_all(IDENTITY_DIR)
	path := IDENTITY_DIR + "/identity.key"

	made, made_err := online.load_identity(path)
	if !testing.expect_value(t, made_err, "") do return
	loaded, loaded_err := online.load_identity(path)
	testing.expect_value(t, loaded_err, "")
	testing.expect(t, loaded.public_key == made.public_key, "a second load gives the same player id")

	challenge := transmute([]byte)string("challenge")
	signature := online.sign(loaded, challenge)
	testing.expect(t, online.signed_by(made.public_key, challenge, signature))
	testing.expect(t, !online.signed_by(made.public_key, transmute([]byte)string("other"), signature))

	broken := transmute([]byte)string("short")
	_ = os.write_entire_file(path, broken)
	_, broken_err := online.load_identity(path)
	testing.expect(t, broken_err != "", "a broken identity.key is an error")
	kept, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, string(kept) == "short", "a broken identity.key is never replaced")
}
