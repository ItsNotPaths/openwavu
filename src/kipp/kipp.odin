// kipp lines (github.com/ItsNotPaths/kipp SPEC.md, version 1): tab separated, kind first, then the subject fields,
// then key=value fields. Lowercase kinds are facts from the publisher, uppercase kinds are commands to it.
package kipp

import "core:strings"

LINE_MAX :: 1024  // newline included
FIELDS_MAX :: 32

Line :: struct {
	kind:       string,
	subject:    []string,
	attributes: map[string]string,
}

Attribute :: struct {
	key, value: string,
}

// Views into text, in allocator. Reserved @ fields are skipped; ok is false for a line with no kind, over LINE_MAX or
// over FIELDS_MAX fields.
parse :: proc(text: string, allocator := context.temp_allocator) -> (line: Line, ok: bool) {
	if len(text) >= LINE_MAX do return
	rest := strings.trim_right(text, "\n")
	subject := make([dynamic]string, allocator)
	line.attributes = make(map[string]string, allocator)
	fields := 0
	for field in strings.split_iterator(&rest, "\t") {
		if field == "" do continue
		if fields += 1; fields > FIELDS_MAX do return
		if line.kind == "" {
			if strings.has_prefix(field, "@") do continue
			line.kind = field
		} else if key, equals, value := strings.partition(field, "="); equals != "" && key != "" {
			line.attributes[key] = value
		} else if len(line.attributes) == 0 {
			append(&subject, field)
		}
	}
	line.subject = subject[:]
	return line, line.kind != ""
}

// One line with its newline. Tabs, newlines and control characters are taken out of the values; a subject field
// holding '=' or nothing refuses the line.
write :: proc(kind: string, subject: []string, attributes: ..Attribute, allocator := context.temp_allocator) -> (text: string, ok: bool) {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, kind)
	for field in subject {
		if field == "" || strings.contains_rune(field, '=') do return
		strings.write_byte(&builder, '\t')
		write_clean(&builder, field)
	}
	for attribute in attributes {
		strings.write_byte(&builder, '\t')
		strings.write_string(&builder, attribute.key)
		strings.write_byte(&builder, '=')
		write_clean(&builder, attribute.value)
	}
	strings.write_byte(&builder, '\n')
	text = strings.to_string(builder)
	return text, len(text) <= LINE_MAX
}

@(private = "file")
write_clean :: proc(builder: ^strings.Builder, text: string) {
	for character in text do if character >= ' ' && character != 0x7f do strings.write_rune(builder, character)
}
