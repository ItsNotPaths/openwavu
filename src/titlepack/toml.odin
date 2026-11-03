// pack.toml through tomlc17 (vendor/tomlc17): the part of its API read_titlepack uses.
package titlepack

import "core:c"

foreign import tomlc17 "../../vendor/tomlc17/libtomlc17.a"

@(private)
Toml_Type :: enum c.int {Unknown, String, Int64, Fp64, Boolean, Date, Time, Datetime, Datetime_Tz, Array, Table}

// toml_datum_t. The union holds only the members read here; table is its largest, so the size matches.
@(private)
Toml_Datum :: struct {
	type:         Toml_Type,
	flag:         u32,
	line, column: c.int,
	source:       cstring,
	using value:  struct #raw_union {
		text:  struct {data: [^]u8, length: c.int},
		array: struct {size: i32, elements: [^]Toml_Datum},
		table: struct {size: i32, keys: [^][^]u8, key_lengths: [^]c.int, values: [^]Toml_Datum},
	},
}

@(private)
Toml_Result :: struct {
	ok:       bool,
	top:      Toml_Datum,
	error:    [200]u8,
	internal: rawptr,
}

@(private, default_calling_convention = "c")
foreign tomlc17 {
	toml_parse :: proc(text: [^]u8, length: c.int) -> Toml_Result ---
	toml_free :: proc(result: Toml_Result) ---
	toml_get :: proc(table: Toml_Datum, key: cstring) -> Toml_Datum ---  // type Unknown when the key is missing
}

// A string datum as a view into its result.
@(private)
toml_text :: proc(datum: Toml_Datum) -> (text: string, ok: bool) {
	if datum.type != .String do return
	return string(datum.text.data[:datum.text.length]), true
}
