package tests

import "core:strings"
import "core:testing"
import "../src/titlepack"

@(test)
toml_values_and_nesting :: proc(t: ^testing.T) {
	table, err := titlepack.read_toml(`basic = "quote\" slash\\\n\t\u03bb"
literal = 'raw\text'
integer = -1_234
hex = 0xCA_FE
float = 1.25e2
boolean = true
values = [1, "two", false, [3.0], # comment
]
[a]
b.key = "nested"
b.other = 4
[[players]]
name = "first"
[players.settings]
active = true
[[players]]
name = "second"
`)
	defer delete(err)
	if !testing.expect_value(t, err, "") do return
	defer titlepack.destroy_toml(table)
	testing.expect_value(t, table.values["basic"].(string), "quote\" slash\\\n\tλ")
	testing.expect_value(t, table.values["literal"].(string), "raw\\text")
	testing.expect_value(t, table.values["integer"].(i64), -1234)
	testing.expect_value(t, table.values["hex"].(i64), 51966)
	testing.expect_value(t, table.values["float"].(f64), 125)
	testing.expect(t, table.values["boolean"].(bool))
	values := table.values["values"].([dynamic]titlepack.Toml_Value)
	testing.expect_value(t, len(values), 4)
	testing.expect_value(t, values[0].(i64), 1)
	testing.expect_value(t, values[1].(string), "two")
	testing.expect(t, !values[2].(bool))
	testing.expect_value(t, values[3].([dynamic]titlepack.Toml_Value)[0].(f64), 3)
	a := table.values["a"].(^titlepack.Toml_Table)
	b := a.values["b"].(^titlepack.Toml_Table)
	testing.expect_value(t, b.values["key"].(string), "nested")
	testing.expect_value(t, b.values["other"].(i64), 4)
	players := table.values["players"].([dynamic]titlepack.Toml_Value)
	testing.expect_value(t, len(players), 2)
	first := players[0].(^titlepack.Toml_Table)
	second := players[1].(^titlepack.Toml_Table)
	testing.expect_value(t, first.values["name"].(string), "first")
	testing.expect_value(t, second.values["name"].(string), "second")
	testing.expect(t, first.values["settings"].(^titlepack.Toml_Table).values["active"].(bool))
}

@(test)
toml_errors_name_the_line :: proc(t: ^testing.T) {
	for text in ([]string{"key = 1\nkey = 2", "good = true\nbad line", "good = 1\nbad = [2, {x = 3}]", "good = 1\nbad = \"\\uD800\"", "key = 1\nkey.child = 2", "[a]\n[a]"}) {
		table, err := titlepack.read_toml(text)
		testing.expect(t, table == nil && strings.has_prefix(err, "line 2:"), err)
		delete(err)
	}
}
