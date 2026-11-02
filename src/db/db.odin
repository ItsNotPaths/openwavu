// Writes a game database: schema, then rows in one transaction.
package db

import "core:fmt"
import "core:os"
import "core:strings"

SCHEMA :: #load("schema.sql", string)

Null :: struct {}
Value :: union {
	Null,
	i64,
	f64,
	string,
	[]byte,
}

Writer :: struct {
	handle: ^Sqlite,
	stmts:  map[string]^Stmt,  // one INSERT per table
	err:    string,            // the first error; later writes do nothing
}

// Replaces the file at path. game_schema is applied after the shared schema.
create :: proc(path: string, game_schema: string) -> (w: Writer, err: string) {
	os.remove(path)
	if open_v2(strings.clone_to_cstring(path, context.temp_allocator), &w.handle, OPEN_READWRITE | OPEN_CREATE, nil) != OK {
		return w, fmt.tprintf("cannot create %s", path)
	}
	w.stmts = make(map[string]^Stmt)  // its allocator also holds the keys and the error
	for sql in ([]string{"PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;", SCHEMA, game_schema, "BEGIN;"}) {
		exec_sql(&w, sql)
	}
	return w, w.err
}

// Commits and closes. Returns the first error of the whole write.
finish :: proc(w: ^Writer) -> (err: string) {
	exec_sql(w, "COMMIT;")
	for table, s in w.stmts {
		finalize(s)
		delete(table)
	}
	delete(w.stmts)
	close_v2(w.handle)
	return w.err
}

exec_sql :: proc(w: ^Writer, sql: string) {
	if w.err != "" do return
	if exec(w.handle, strings.clone_to_cstring(sql, context.temp_allocator), nil, nil, nil) != OK {
		w.err = fmt.aprintf("%s", errmsg(w.handle), allocator = w.stmts.allocator)
	}
}

// INSERT INTO table VALUES (values...), in column order.
insert :: proc(w: ^Writer, table: string, values: ..Value) {
	if w.err != "" do return
	s, ok := w.stmts[table]
	if !ok {
		marks := strings.repeat("?,", len(values), context.temp_allocator)
		sql := fmt.ctprintf("INSERT INTO %s VALUES (%s)", table, marks[:len(marks) - 1])
		if prepare_v2(w.handle, sql, -1, &s, nil) != OK {
			w.err = fmt.aprintf("%s: %s", table, errmsg(w.handle), allocator = w.stmts.allocator)
			return
		}
		w.stmts[strings.clone(table, w.stmts.allocator)] = s
	}
	for v, i in values {
		n := i32(i + 1)
		switch x in v {
		case Null: bind_null(s, n)
		case i64: bind_int64(s, n, x)
		case f64: bind_double(s, n, x)
		case string: bind_text(s, n, raw_data(x), i32(len(x)), TRANSIENT)
		case []byte: bind_blob(s, n, raw_data(x), i32(len(x)), TRANSIENT)
		}
	}
	if step(s) != DONE do w.err = fmt.aprintf("%s: %s", table, errmsg(w.handle), allocator = w.stmts.allocator)
	reset(s)
}

// Every name sheet (a table of exactly name and code, filled by the schema): sheet -> code -> name.
name_sheets :: proc(w: ^Writer, allocator := context.allocator) -> map[string]map[i64]string {
	sheets := make(map[string]map[i64]string, allocator)
	tables: [dynamic]string
	s: ^Stmt
	if prepare_v2(w.handle, NAME_SHEETS, -1, &s, nil) != OK do return sheets
	for step(s) == ROW do append(&tables, strings.clone_from_cstring(column_text(s, 0), allocator))
	finalize(s)
	for table in tables {
		names := make(map[i64]string, allocator)
		if prepare_v2(w.handle, fmt.ctprintf("SELECT code, name FROM %s", table), -1, &s, nil) != OK do continue
		for step(s) == ROW do names[column_int64(s, 0)] = strings.clone_from_cstring(column_text(s, 1), allocator)
		finalize(s)
		sheets[table] = names
	}
	return sheets
}

NAME_SHEETS: cstring : "SELECT name FROM sqlite_master m WHERE type = 'table' AND (SELECT group_concat(name) FROM pragma_table_info(m.name)) = 'name,code'"
