// Inner LZ layer (FUN_00012ee0): flag byte, 11-bit distance, 5-bit length. Used by motbins and NTP3.
package tk5_formats

unlz :: proc(src: []byte, allocator := context.allocator) -> (data: []byte, ok: bool) {
	out := make([dynamic]byte, 0, len(src) * 2, allocator)
	i := 0
	for i < len(src) {
		flags := src[i]
		i += 1
		if flags == 0 do return out[:], true
		for ; flags > 1; flags >>= 1 {  // the top set bit is a stop marker
			if flags & 1 != 0 {
				if i >= len(src) do return nil, false
				append(&out, src[i])
				i += 1
				continue
			}
			if i + 2 > len(src) do return nil, false
			v := int(be_u16(src, i))
			i += 2
			dist := v & 0x7ff
			if dist == 0 do dist = 0x800
			n := (v >> 11) & 0x1f
			if n == 0 do n = 0x20
			if dist > len(out) do return nil, false
			for _ in 0 ..< n do append(&out, out[len(out) - dist])
		}
	}
	return nil, false
}
