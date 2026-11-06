// Binding of ffmpeg.c: game codecs to 16-bit samples, 16-bit samples to FLAC (ffmpeg's libavcodec).
package audio

import "core:c"

foreign import lib {
	"../../build/libow_audio.a",
	"../../vendor/ffmpeg/lib/libavcodec.a",
	"../../vendor/ffmpeg/lib/libavutil.a",
	"system:m",
}

Codec :: enum c.int {
	PS_ADPCM,
	ATRAC3_PLUS,
}

PS_ADPCM_FRAME :: 16    // bytes of one ADPCM frame
PS_ADPCM_SAMPLES :: 28  // samples in it

@(default_calling_convention = "c")
foreign lib {
	ow_audio_decode :: proc(codec: Codec, channels, rate, block: c.int, data: [^]byte, size: c.size_t, samples: ^[^]i16, frames: ^c.size_t) -> c.int ---
	ow_audio_flac :: proc(samples: [^]i16, frames: c.size_t, channels, rate: c.int, file: ^[^]byte, size: ^c.size_t) -> c.int ---
	ow_audio_free :: proc(pointer: rawptr) ---
}

// Interleaved samples. block: bytes per packet (PS ADPCM: one frame per channel).
decode :: proc(codec: Codec, channels, rate, block: int, data: []byte, allocator := context.allocator) -> (samples: []i16, ok: bool) {
	decoded: [^]i16
	frames: c.size_t
	if ow_audio_decode(codec, c.int(channels), c.int(rate), c.int(block), raw_data(data), len(data), &decoded, &frames) == 0 do return
	defer ow_audio_free(decoded)
	samples = make([]i16, int(frames) * channels, allocator)
	copy(samples, decoded[:len(samples)])
	return samples, true
}

// A whole .flac file of interleaved samples.
flac :: proc(samples: []i16, channels, rate: int, allocator := context.allocator) -> (file: []byte, ok: bool) {
	encoded: [^]byte
	size: c.size_t
	if ow_audio_flac(raw_data(samples), c.size_t(len(samples)) / c.size_t(channels), c.int(channels), c.int(rate), &encoded, &size) == 0 do return
	defer ow_audio_free(encoded)
	file = make([]byte, int(size), allocator)
	copy(file, encoded[:size])
	return file, true
}
