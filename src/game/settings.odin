package game

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// One key=value per line. A missing file, unknown keys and bad values keep the defaults.
settings_load :: proc(config_dir: string) -> (settings: Settings) {
	settings = {file = strings.concatenate({config_dir, "/settings.conf"}), frame_cap = FRAME_CAPS[0]}
	text, err := os.read_entire_file(settings.file, context.temp_allocator)
	if err != nil do return
	caps := FRAME_CAPS
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		key, _, value := strings.partition(line, "=")
		if strings.trim_space(key) == "frame_cap" {
			cap, parsed := strconv.parse_int(strings.trim_space(value))
			if parsed && slice.contains(caps[:], cap) do settings.frame_cap = cap
		}
	}
	return
}

settings_save :: proc(settings: Settings) {
	text := fmt.tprintf("frame_cap=%d\n", settings.frame_cap)
	if os.write_entire_file(settings.file, text) != nil do fmt.eprintln("openwavu: could not save", settings.file)
}
