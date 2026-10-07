package tests

import "core:bytes"
import "core:os"
import "core:testing"
import "../src/db"

TK5_SCHEMA :: #load("../src/db/tk5/schema.sql", string)

write_sample :: proc(t: ^testing.T, path: string) -> []byte {
	w, err := db.create(path, TK5_SCHEMA)
	testing.expect_value(t, err, "")
	db.insert(&w, "source", "title_id", "NPUB30009")
	db.insert(&w, "character", "kazuya", "Kazuya", i64(14))
	testing.expect_value(t, db.finish(&w), "")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return data
}

@(test)
database_is_deterministic :: proc(t: ^testing.T) {
	a := write_sample(t, "build/test_a.db")
	b := write_sample(t, "build/test_b.db")
	testing.expect(t, len(a) > 0 && bytes.equal(a, b), "same rows gave different database bytes")
	os.remove("build/test_a.db")
	os.remove("build/test_b.db")
}
