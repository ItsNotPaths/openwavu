// Minimal SQLite binding: the procs the importer and the game use.
package db

import "core:c"

// (hole static-sqlite :tags importer) links the system libsqlite3; shipped builds need the amalgamation linked statically.
foreign import sqlite "system:sqlite3"

Sqlite :: struct {}
Stmt :: struct {}

OK :: 0
ROW :: 100
DONE :: 101
OPEN_READWRITE :: 0x02
OPEN_CREATE :: 0x04
TRANSIENT :: rawptr(~uintptr(0))

@(default_calling_convention = "c", link_prefix = "sqlite3_")
foreign sqlite {
	open_v2 :: proc(filename: cstring, db: ^^Sqlite, flags: c.int, vfs: cstring) -> c.int ---
	close_v2 :: proc(db: ^Sqlite) -> c.int ---
	exec :: proc(db: ^Sqlite, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
	errmsg :: proc(db: ^Sqlite) -> cstring ---
	prepare_v2 :: proc(db: ^Sqlite, sql: cstring, n: c.int, stmt: ^^Stmt, tail: ^cstring) -> c.int ---
	step :: proc(stmt: ^Stmt) -> c.int ---
	reset :: proc(stmt: ^Stmt) -> c.int ---
	finalize :: proc(stmt: ^Stmt) -> c.int ---
	bind_null :: proc(stmt: ^Stmt, i: c.int) -> c.int ---
	bind_int64 :: proc(stmt: ^Stmt, i: c.int, v: i64) -> c.int ---
	bind_double :: proc(stmt: ^Stmt, i: c.int, v: f64) -> c.int ---
	bind_text :: proc(stmt: ^Stmt, i: c.int, v: [^]u8, n: c.int, destructor: rawptr) -> c.int ---
	bind_blob :: proc(stmt: ^Stmt, i: c.int, v: rawptr, n: c.int, destructor: rawptr) -> c.int ---
	column_int64 :: proc(stmt: ^Stmt, i: c.int) -> i64 ---
	column_double :: proc(stmt: ^Stmt, i: c.int) -> f64 ---
	column_text :: proc(stmt: ^Stmt, i: c.int) -> cstring ---
}
