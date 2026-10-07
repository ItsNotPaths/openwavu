package titlepack

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Toml_Table :: struct {values: map[string]Toml_Value}
Toml_Value :: union {string, i64, f64, bool, [dynamic]Toml_Value, ^Toml_Table}

// The caller owns the table and the error string.
read_toml :: proc(text: string, allocator := context.allocator) -> (table: ^Toml_Table, err: string) {
	context.allocator = allocator
	p := Toml_Parser{text = text, line = 1}
	table = new(Toml_Table)
	current := table
	declared := make(map[^Toml_Table]bool)
	defer delete(declared)
	for p.pos < len(text) && p.error == "" {
		toml_space(&p, true)
		if p.pos == len(text) do break
		if text[p.pos] == '[' {
			p.pos += 1
			array := toml_take(&p, '[')
			keys := toml_keys(&p)
			if !toml_take(&p, ']') || (array && !toml_take(&p, ']')) do p.error = "bad table"
			if p.error == "" {
				current = toml_table(&p, table, keys[:], array)
				if !array && declared[current] do p.error = "duplicate table"
				declared[current] = true
			}
			toml_free_keys(keys)
		} else {
			keys := toml_keys(&p)
			if !toml_take(&p, '=') do p.error = "expected ="
			if p.error == "" {
				value := toml_value(&p)
				if p.error == "" {
					parent := toml_table(&p, current, keys[:len(keys) - 1], false)
					key := keys[len(keys) - 1]
					if _, exists := parent.values[key]; exists do p.error = "duplicate key"
					if p.error == "" do parent.values[strings.clone(key)] = value
					else do destroy_toml_value(value)
				} else do destroy_toml_value(value)
			}
			toml_free_keys(keys)
		}
		toml_space(&p, false)
		if p.pos < len(text) && text[p.pos] != '\n' do p.error = "bad line"
		if p.error == "" && p.pos < len(text) {
			p.pos += 1
			p.line += 1
		}
	}
	if p.error != "" {
		destroy_toml(table)
		return nil, fmt.aprintf("line %d: %s", p.line, p.error)
	}
	return
}

destroy_toml :: proc(table: ^Toml_Table, allocator := context.allocator) {
	context.allocator = allocator
	if table == nil do return
	for key, value in table.values {
		delete(key)
		destroy_toml_value(value)
	}
	delete(table.values)
	free(table)
}

@(private = "file")
destroy_toml_value :: proc(value: Toml_Value) {
	switch v in value {
	case string: delete(v)
	case [dynamic]Toml_Value:
		for x in v do destroy_toml_value(x)
		delete(v)
	case ^Toml_Table: destroy_toml(v)
	case i64, f64, bool:
	}
}

@(private = "file")
Toml_Parser :: struct {text: string, pos, line: int, error: string}

@(private = "file")
toml_space :: proc(p: ^Toml_Parser, newlines: bool) {
	for p.pos < len(p.text) {
		switch p.text[p.pos] {
		case ' ', '\t', '\r': p.pos += 1
		case '#':
			for p.pos < len(p.text) && p.text[p.pos] != '\n' do p.pos += 1
		case '\n':
			if !newlines do return
			p.line += 1
			p.pos += 1
		case: return
		}
	}
}

@(private = "file")
toml_take :: proc(p: ^Toml_Parser, b: byte) -> bool {
	toml_space(p, false)
	if p.pos == len(p.text) || p.text[p.pos] != b do return false
	p.pos += 1
	return true
}

@(private = "file")
toml_string :: proc(p: ^Toml_Parser) -> string {
	quote := p.text[p.pos]
	p.pos += 1
	out := make([dynamic]byte)
	defer delete(out)
	chars: for p.pos < len(p.text) {
		b := p.text[p.pos]
		p.pos += 1
		if b == quote do return strings.clone(string(out[:]))
		if b < 32 && b != '\t' do break chars
		if b == '\\' && quote == '"' {
			if p.pos == len(p.text) do break chars
			b = p.text[p.pos]
			p.pos += 1
			switch b {
			case '"', '\\': append(&out, b)
			case 'n': append(&out, '\n')
			case 't': append(&out, '\t')
			case 'u':
				if len(p.text) - p.pos < 4 do break chars
				n, ok := strconv.parse_uint(p.text[p.pos:p.pos + 4], 16)
				if !ok || (n >= 0xd800 && n <= 0xdfff) do break chars
				encoded, count := utf8.encode_rune(rune(n))
				append(&out, ..encoded[:count])
				p.pos += 4
			case: break chars
			}
		} else do append(&out, b)
	}
	p.error = "bad string"
	return ""
}

@(private = "file")
toml_keys :: proc(p: ^Toml_Parser) -> (keys: [dynamic]string) {
	for {
		toml_space(p, false)
		key: string
		if p.pos < len(p.text) && (p.text[p.pos] == '"' || p.text[p.pos] == '\'') {
			key = toml_string(p)
		} else {
			start := p.pos
			for p.pos < len(p.text) {
				b := p.text[p.pos]
				if !(b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_' || b == '-') do break
				p.pos += 1
			}
			if start == p.pos do p.error = "expected key"
			key = strings.clone(p.text[start:p.pos])
		}
		append(&keys, key)
		if p.error != "" || !toml_take(p, '.') do break
	}
	return
}

@(private = "file")
toml_free_keys :: proc(keys: [dynamic]string) {
	for key in keys do delete(key)
	delete(keys)
}

@(private = "file")
toml_table :: proc(p: ^Toml_Parser, root: ^Toml_Table, keys: []string, array: bool) -> ^Toml_Table {
	table := root
	for original, i in keys {
		key := original
		value, exists := table.values[key]
		if array && i == len(keys) - 1 {
			values: [dynamic]Toml_Value
			if exists {
				valid: bool
				values, valid = value.([dynamic]Toml_Value)
				if !valid {
					p.error = "duplicate key"
					return table
				}
			}
			next := new(Toml_Table)
			append(&values, next)
			if !exists do key = strings.clone(key)
			table.values[key] = values
			table = next
		} else if !exists {
			next := new(Toml_Table)
			table.values[strings.clone(key)] = next
			table = next
		} else {
			switch v in value {
			case ^Toml_Table: table = v
			case [dynamic]Toml_Value:
				if len(v) == 0 {
					p.error = "expected table"
					return table
				}
				next, valid := v[len(v) - 1].(^Toml_Table)
				if !valid do p.error = "expected table"
				else do table = next
			case string, i64, f64, bool: p.error = "duplicate key"
			}
		}
		if p.error != "" do return table
	}
	return table
}

@(private = "file")
toml_value :: proc(p: ^Toml_Parser) -> Toml_Value {
	toml_space(p, false)
	if p.pos == len(p.text) {
		p.error = "expected value"
		return nil
	}
	if p.text[p.pos] == '"' || p.text[p.pos] == '\'' do return toml_string(p)
	if toml_take(p, '[') {
		values := make([dynamic]Toml_Value)
		for {
			toml_space(p, true)
			if toml_take(p, ']') do return values
			append(&values, toml_value(p))
			if p.error != "" do return values
			toml_space(p, true)
			if toml_take(p, ']') do return values
			if !toml_take(p, ',') {
				p.error = "expected comma"
				return values
			}
		}
	}
	start := p.pos
	for p.pos < len(p.text) && !strings.contains_rune(" \t\r\n#,]", rune(p.text[p.pos])) do p.pos += 1
	text := p.text[start:p.pos]
	if text == "true" do return true
	if text == "false" do return false
	clean := make([dynamic]byte)
	defer delete(clean)
	for b, i in transmute([]byte)text {
		if b == '_' {
			if i == 0 || i + 1 == len(text) || text[i - 1] == '_' || text[i + 1] == '_' {
				p.error = "bad number"
				return nil
			}
		} else do append(&clean, b)
	}
	text = string(clean[:])
	if strings.contains_any(text, ".eE") && !strings.has_prefix(text, "0x") {
		n, ok := strconv.parse_f64(text)
		if ok do return n
	} else {
		base := 10
		if strings.has_prefix(text, "0x") {
			base = 16
			text = text[2:]
		}
		n, ok := strconv.parse_i64(text, base)
		if ok do return n
	}
	p.error = "bad value"
	return nil
}
