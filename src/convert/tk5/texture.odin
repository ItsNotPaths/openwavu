package tk5_convert

import "../../convert"
import formats "../../formats/tk5"

Textures :: map[u32]formats.Texture  // by hash, MIF placeholders already resolved

// NTP3 texture -> DDS bytes: DXT blocks as stored, ARGB8 as RGBA8.
// (hole texture-alpha-re :tags importer) any texel alpha < 128 makes the texture cut-out; some costume textures (kazuya pants) use alpha for something else, likely a colour mask, and draw see-through.
// (hole texture-mips :tags importer :sev polish) only the top mip is read; the DDS files have no mip chain.
texture_dds :: proc(t: formats.Texture, allocator := context.allocator) -> (dds: []byte, cutout: bool, ok: bool) {
	rgba := formats.decode_rgba(t, context.temp_allocator) or_return
	for i := 3; i < len(rgba); i += 4 do if rgba[i] < 128 {cutout = true; break}
	switch t.format {
	case 0: dds = convert.encode_dds(.BC1, t.width, t.height, t.data, allocator)
	case 1: dds = convert.encode_dds(.BC2, t.width, t.height, t.data, allocator)
	case 2: dds = convert.encode_dds(.BC3, t.width, t.height, t.data, allocator)
	case: dds = convert.encode_dds(.RGBA8, t.width, t.height, rgba, allocator)
	}
	return dds, cutout, true
}

// NTP3 or TIM2 section -> one PNG per picture, in order; nil for a picture that does not decode.
art_pngs :: proc(section: []byte, allocator := context.allocator) -> (pngs: [][]byte, ok: bool) {
	if textures, is_ntp3 := formats.read_ntp3(section, context.temp_allocator); is_ntp3 {
		pngs = make([][]byte, len(textures), allocator)
		for t, i in textures {
			rgba := formats.decode_rgba(t, context.temp_allocator) or_continue
			pngs[i] = convert.encode_png(rgba, t.width, t.height, allocator)
		}
		return pngs, true
	}
	pictures := formats.read_tim2(section, context.temp_allocator) or_return
	pngs = make([][]byte, len(pictures), allocator)
	for p, i in pictures do pngs[i] = convert.encode_png(p.rgba, p.width, p.height, allocator)
	return pngs, true
}
