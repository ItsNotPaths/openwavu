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
