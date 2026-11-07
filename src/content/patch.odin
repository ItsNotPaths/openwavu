// A db patch: `<db>.patch` in a pack, same schema as <db>. Its rows replace rows with the same key, and its lists
// replace whole lists (docs/formats.md).
package content

import "core:fmt"
import "core:mem"
import "core:strings"
import "../db"

PATCH_EXTENSION :: ".patch"

// Into handle, the database below: per table, a list table (key list, pos) loses every list the patch has, then takes
// the patch's rows; any other table takes each row in place of the one with its key (an upsert keeps its spot, so the
// game's order holds). A new text key outside `<pack_id>/` refuses the whole patch.
apply_patch :: proc(handle: ^db.Sqlite, patch: []byte, pack_id: string) -> (err: string) {
	if err = run(handle, "ATTACH DATABASE ':memory:' AS patch"); err != "" do return
	defer run(handle, "DETACH DATABASE patch")
	copied := ([^]u8)(db.malloc64(u64(len(patch))))
	if copied == nil do return "out of memory"
	mem.copy(copied, raw_data(patch), len(patch))
	if db.deserialize(handle, "patch", copied, i64(len(patch)), i64(len(patch)), db.DESERIALIZE_FREEONCLOSE) != db.OK {
		return "the patch is not a database"
	}
	if err = run(handle, "BEGIN"); err != "" do return
	for table in rows(handle, "SELECT name FROM patch.sqlite_master WHERE type = 'table'") {
		if err = patch_table(handle, table[0], pack_id); err != "" {
			run(handle, "ROLLBACK")
			return fmt.tprintf("%s: %s", table[0], err)
		}
	}
	return run(handle, "COMMIT")
}

@(private = "file")
patch_table :: proc(handle: ^db.Sqlite, table, pack_id: string) -> (err: string) {
	columns, keys: [dynamic]string
	columns.allocator, keys.allocator = context.temp_allocator, context.temp_allocator
	key_type := ""
	for column in rows(handle, fmt.tprintf("SELECT name, type, pk FROM pragma_table_info('%s', 'main') ORDER BY pk", quoted(table, '\''))) {
		append(&columns, fmt.tprintf("\"%s\"", quoted(column[0], '"')))
		if column[2] != "0" {
			append(&keys, columns[len(columns) - 1])
			key_type = column[1]
		}
	}
	if len(columns) == 0 do return "no such table below"
	names := strings.join(columns[:], ", ", context.temp_allocator)
	name := fmt.tprintf("\"%s\"", quoted(table, '"'))
	if len(keys) == 2 && keys[0] == "\"list\"" && keys[1] == "\"pos\"" {
		if err = run(handle, fmt.tprintf("DELETE FROM main.%s WHERE list IN (SELECT list FROM patch.%s)", name, name)); err != "" do return
		return run(handle, fmt.tprintf("INSERT INTO main.%s (%s) SELECT %s FROM patch.%s", name, names, names, name))
	}
	if len(keys) == 0 do return "has no key"
	if len(keys) == 1 && strings.to_upper(key_type, context.temp_allocator) == "TEXT" {
		prefix := strings.concatenate({pack_id, "/"}, context.temp_allocator)
		outside := rows(handle, fmt.tprintf("SELECT %s FROM patch.%s WHERE %s NOT IN (SELECT %s FROM main.%s) AND substr(%s, 1, %d) != '%s' LIMIT 1", keys[0], name, keys[0], keys[0], name, keys[0], len(prefix), quoted(prefix, '\'')))
		if len(outside) > 0 do return fmt.tprintf("adds %s outside its namespace %s", outside[0][0], prefix)
	}
	updates := make([dynamic]string, context.temp_allocator)
	for column in columns do append(&updates, fmt.tprintf("%s = excluded.%s", column, column))
	key_names := strings.join(keys[:], ", ", context.temp_allocator)
	return run(handle, fmt.tprintf("INSERT INTO main.%s (%s) SELECT %s FROM patch.%s WHERE true ON CONFLICT (%s) DO UPDATE SET %s", name, names, names, name, key_names, strings.join(updates[:], ", ", context.temp_allocator)))
}

@(private = "file")
run :: proc(handle: ^db.Sqlite, sql: string) -> (err: string) {
	if db.exec(handle, strings.clone_to_cstring(sql, context.temp_allocator), nil, nil, nil) != db.OK {
		return strings.clone(string(db.errmsg(handle)), context.temp_allocator)
	}
	return
}

// Every row as text, in temp memory.
@(private = "file")
rows :: proc(handle: ^db.Sqlite, sql: string) -> [][]string {
	found := make([dynamic][]string, context.temp_allocator)
	statement: ^db.Stmt
	if db.prepare_v2(handle, strings.clone_to_cstring(sql, context.temp_allocator), -1, &statement, nil) != db.OK do return nil
	defer db.finalize(statement)
	for db.step(statement) == db.ROW {
		row := make([]string, db.column_count(statement), context.temp_allocator)
		for &cell, index in row do cell = strings.clone(string(db.column_text(statement, i32(index))), context.temp_allocator)
		append(&found, row)
	}
	return found[:]
}

// text with quote doubled, for inside quotes in SQL.
@(private = "file")
quoted :: proc(text: string, quote: rune) -> string {
	single := fmt.tprintf("%c", quote)
	result, _ := strings.replace_all(text, single, strings.concatenate({single, single}, context.temp_allocator), context.temp_allocator)
	return result
}

// (hole patch-write :tags (content editor)) no way to diff an edited database into a db patch.
write_patch :: proc(base, edited: ^Pack, path: string) -> (ok: bool) {
	return false
}
