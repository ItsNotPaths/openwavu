package game

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

DEFAULT_NETWORK :: "openwavu.org"

// One key=value per line; favourite= repeats. A missing file, unknown keys and bad values keep the defaults.
settings_load :: proc(config_dir: string) -> (settings: Settings) {
	settings = {file = strings.concatenate({config_dir, "/settings.conf"}), frame_cap = FRAME_CAPS[0], network = strings.clone(DEFAULT_NETWORK)}
	text, err := os.read_entire_file(settings.file, context.temp_allocator)
	if err != nil do return
	caps := FRAME_CAPS
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		key, _, value := strings.partition(line, "=")
		value = strings.trim_space(value)
		switch strings.trim_space(key) {
		case "frame_cap":
			cap, parsed := strconv.parse_int(value)
			if parsed && slice.contains(caps[:], cap) do settings.frame_cap = cap
		case "favourite":
			if value != "" do append(&settings.favourites, strings.clone(value))
		case "name":
			strings.write_string(&settings.name, value)
		case "network":
			if value == "" do continue
			delete(settings.network)
			settings.network = strings.clone(value)
		}
	}
	return
}

settings_save :: proc(settings: Settings) {
	text := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&text, "frame_cap=%d", settings.frame_cap)
	fmt.sbprintfln(&text, "name=%s", strings.to_string(settings.name))
	fmt.sbprintfln(&text, "network=%s", settings.network)
	for tile in settings.favourites do fmt.sbprintfln(&text, "favourite=%s", tile)
	if os.write_entire_file(settings.file, strings.to_string(text)) != nil do fmt.eprintln("openwavu: could not save", settings.file)
}

settings_destroy :: proc(settings: ^Settings) {
	delete(settings.file)
	for tile in settings.favourites do delete(tile)
	delete(settings.favourites)
	strings.builder_destroy(&settings.name)
	delete(settings.network)
}

// The network's files host: https://serve.<network>, or the setting itself when it is a full URL (a LAN server).
network_url :: proc(network: string) -> string {
	return strings.contains(network, "://") ? network : strings.concatenate({"https://serve.", network}, context.temp_allocator)
}

// Stars or unstars a tile.
toggle_favourite :: proc(settings: ^Settings, tile: string) {
	if index, found := slice.linear_search(settings.favourites[:], tile); found {
		delete(settings.favourites[index])
		ordered_remove(&settings.favourites, index)
	} else {
		append(&settings.favourites, strings.clone(tile))
	}
	settings_save(settings^)
}
