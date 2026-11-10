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

// What uninstalling deletes: the data folder, the config folder when it is its own, this binary.
openwavu_paths :: proc(data, config: string) -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, data)
	if config != data do append(&paths, config)
	if binary, err := os.get_executable_path(context.temp_allocator); err == nil do append(&paths, binary)
	return paths[:]
}

// Windows can not delete a running binary: a shell deletes it, its .old and its .pdb once openwavu has exited.
uninstall_openwavu :: proc(data, config: string) {
	os.remove_all(data)
	os.remove_all(config)
	binary, err := os.get_executable_path(context.temp_allocator)
	if err != nil do return
	when ODIN_OS == .Windows {
		old := strings.concatenate({binary, ".old"}, context.temp_allocator)
		pdb := strings.concatenate({strings.trim_suffix(binary, ".exe"), ".pdb"}, context.temp_allocator)
		_, _ = os.process_start({command = {"cmd", "/c", "ping", "-n", "3", "127.0.0.1", ">nul", "&", "del", "/f", "/q", binary, old, pdb}})
	} else {
		os.remove(binary)
	}
}
