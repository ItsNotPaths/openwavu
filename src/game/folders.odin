package game

import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

// The user's folders, made when missing. data holds packs, saves and replays: $XDG_DATA_HOME/openwavu on Linux,
// %APPDATA%\openwavu on Windows. config holds the settings: $XDG_CONFIG_HOME/openwavu, the data folder on Windows.
user_folders :: proc(allocator := context.allocator) -> (data, config: string, ok: bool) {
	pref := sdl.GetPrefPath("", "openwavu")
	if pref == nil do return
	defer sdl.free(pref)
	data = strings.clone(strings.trim_right(string(cstring(pref)), "/\\"), allocator)
	when ODIN_OS == .Windows {
		config = strings.clone(data, allocator)
	} else {
		config_home := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
		if config_home == "" do config_home = strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.config"}, context.temp_allocator)
		config = strings.concatenate({config_home, "/openwavu"}, allocator)
	}
	if err := os.make_directory_all(config); err != nil && err != .Exist do return
	return data, config, true
}
