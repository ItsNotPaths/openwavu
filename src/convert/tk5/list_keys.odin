// The list keys of one character's rows: the shape every Tekken schema shares (a <table>_list row per list, child rows
// (list, pos) in <table>).
package tk5_convert

import "core:fmt"
import "../../db"

List_Keys :: struct {
	char:  string,
	lists: [List][]string,  // by game index: the key of the list that starts there, "" inside a list
}

// The first key given to a list start wins; without one the list is named by its table and game index.
mark :: proc(k: ^List_Keys, list: List, index: $T, key := "") {
	keys := k.lists[list]
	i := int(index)
	if i < 0 || i >= len(keys) || keys[i] != "" do return
	keys[i] = key if key != "" else row_key(k.char, LIST_TABLES[list], i)
}

// The list row i is in and its place there. A row that starts a list adds the list.
in_list :: proc(w: ^db.Writer, k: ^List_Keys, list: List, i: int) -> (key, pos: db.Value) {
	keys := k.lists[list]
	start := i
	for keys[start] == "" do start -= 1
	if start == i do db.insert(w, fmt.tprintf("%s_list", LIST_TABLES[list]), keys[i], k.char)
	return keys[start], n(i - start)
}

// A list reference: NULL for none (-1); an index past the table keeps its game name, which no list has.
list_ref :: proc(k: ^List_Keys, list: List, index: $T) -> db.Value {
	i := int(index)
	if i < 0 do return db.Null{}
	if i < len(k.lists[list]) do return k.lists[list][i]
	return row_key(k.char, LIST_TABLES[list], i)
}

row_key :: proc(char, table: string, index: $T) -> string {return fmt.tprintf("%s/%s/%d", char, table, index)}
