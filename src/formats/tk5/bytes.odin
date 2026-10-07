package tk5_formats

import "core:encoding/endian"

be_u16 :: proc(b: []byte, off: int) -> u16 {v, _ := endian.get_u16(b[off:], .Big); return v}
be_i16 :: proc(b: []byte, off: int) -> i16 {return i16(be_u16(b, off))}
be_u32 :: proc(b: []byte, off: int) -> u32 {v, _ := endian.get_u32(b[off:], .Big); return v}
be_i32 :: proc(b: []byte, off: int) -> i32 {return i32(be_u32(b, off))}
be_f32 :: proc(b: []byte, off: int) -> f32 {v, _ := endian.get_f32(b[off:], .Big); return v}
le_u16 :: proc(b: []byte, off: int) -> u16 {v, _ := endian.get_u16(b[off:], .Little); return v}
le_i16 :: proc(b: []byte, off: int) -> i16 {return i16(le_u16(b, off))}
le_u32 :: proc(b: []byte, off: int) -> u32 {v, _ := endian.get_u32(b[off:], .Little); return v}
le_i32 :: proc(b: []byte, off: int) -> i32 {return i32(le_u32(b, off))}
le_f32 :: proc(b: []byte, off: int) -> f32 {v, _ := endian.get_f32(b[off:], .Little); return v}

// NUL-terminated string at off.
cstring_at :: proc(b: []byte, off: int) -> string {
	for i in off ..< len(b) do if b[i] == 0 do return string(b[off:i])
	return string(b[off:])
}
