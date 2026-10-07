package ps3

import "core:encoding/endian"
import "core:strings"

// PARAM.SFO (little endian): header, then 16-byte index entries {key off, fmt, len, max len, data off}.
read_sfo_string :: proc(sfo: []byte, key: string) -> (value: string, ok: bool) {
	if len(sfo) < 0x14 || string(sfo[:4]) != "\x00PSF" do return "", false
	le32 :: proc(b: []byte, off: int) -> int {v, _ := endian.get_u32(b[off:], .Little); return int(v)}
	keys, data, count := le32(sfo, 0x08), le32(sfo, 0x0c), le32(sfo, 0x10)
	for i in 0 ..< count {
		e := sfo[0x14 + i * 16:]
		key_off := int(e[0]) | int(e[1]) << 8
		k := strings.truncate_to_byte(string(sfo[keys + key_off:]), 0)
		if k != key do continue
		v := string(sfo[data + le32(e, 12):][:le32(e, 4)])
		return strings.truncate_to_byte(v, 0), true
	}
	return "", false
}
