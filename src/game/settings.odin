package game

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../imports"

DEFAULT_NETWORK :: "openwavu.org"

// One key=value per line; favourite= repeats. A missing file, unknown keys and bad values keep the defaults.
settings_load :: proc(config_dir: string) -> (settings: Settings) {
	settings = {file = strings.concatenate({config_dir, "/settings.conf"}), frame_cap = FRAME_CAPS[0], music_volume = 100, effects_volume = 100, blend_fighters = true, network = strings.clone(DEFAULT_NETWORK)}
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
		case "music_volume":
			settings.music_volume = parse_percent(value, settings.music_volume)
		case "effects_volume":
			settings.effects_volume = parse_percent(value, settings.effects_volume)
		case "blend_fighters":
			settings.blend_fighters = value != "false"
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
	fmt.sbprintfln(&text, "music_volume=%d", settings.music_volume)
	fmt.sbprintfln(&text, "effects_volume=%d", settings.effects_volume)
	fmt.sbprintfln(&text, "blend_fighters=%v", settings.blend_fighters)
	fmt.sbprintfln(&text, "name=%s", strings.to_string(settings.name))
	fmt.sbprintfln(&text, "network=%s", settings.network)
	for tile in settings.favourites do fmt.sbprintfln(&text, "favourite=%s", tile)
	if os.write_entire_file(settings.file, strings.to_string(text)) != nil do fmt.eprintln("openwavu: could not save", settings.file)
}

@(private = "file")
parse_percent :: proc(value: string, fallback: int) -> int {
	percent, parsed := strconv.parse_int(value)
	return parsed && percent >= 0 && percent <= 100 ? percent : fallback
}

// The volumes as gains, squared so the middle of a slider sounds like the middle.
volumes :: proc(settings: Settings) -> imports.Volumes {
	gain :: proc(percent: int) -> f32 {
		fraction := f32(percent) / 100
		return fraction * fraction
	}
	return {.Effects = gain(settings.effects_volume), .Music = gain(settings.music_volume)}
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

// The network's lobby server: serve.<network>, or the host of a full URL.
lobby_host :: proc(network: string, allocator := context.allocator) -> string {
	_, has_scheme, rest := strings.partition(network, "://")
	if has_scheme == "" do return strings.concatenate({"serve.", network}, allocator)
	end := strings.index_any(rest, ":/")
	return strings.clone(end < 0 ? rest : rest[:end], allocator)
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
