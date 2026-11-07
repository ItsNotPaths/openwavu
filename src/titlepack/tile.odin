// Tiles: each installed pack version is a tile. The latest is packs/<id>.tar with saves/<id>/; a locked (orphaned)
// tile is packs/<id>@<version>.tar with saves/<id>@<version>/ and never updates (docs/packs.md, Orphaned tiles).
package titlepack

import "core:fmt"
import "core:os"
import "core:path/filepath"

tile_name :: proc(id, version: string, locked: bool) -> string {
	return locked ? fmt.tprintf("%s@%s", id, version) : id
}

tile_path :: proc(id, version: string, locked: bool) -> string {
	return fmt.tprintf("%s/%s.tar", packs_dir(), tile_name(id, version, locked))
}

saves_path :: proc(tile: string) -> string {
	return fmt.tprintf("%s/saves/%s", data_dir, tile)
}

// Moves the tar and its saves to the other name. False when a tile already has that name.
set_locked :: proc(tp: Title_Pack, locked: bool) -> bool {
	to := tile_name(tp.id, tp.version, locked)
	tar := tile_path(tp.id, tp.version, locked)
	if os.exists(tar) || os.exists(saves_path(to)) do return false
	if os.rename(tp.path, tar) != nil do return false
	from_saves := saves_path(filepath.stem(tp.path))
	if os.exists(from_saves) do _ = os.rename(from_saves, saves_path(to))
	return true
}

// A new tile starts with a copy of from's saves, unless it has saves of its own.
copy_saves :: proc(from: Title_Pack, to: string) {
	source, target := saves_path(filepath.stem(from.path)), saves_path(to)
	if os.exists(target) || !os.exists(source) do return
	_ = os.make_directory_all(filepath.dir(target))
	if os.copy_directory_all(target, source) != nil do fmt.eprintln("openwavu: saves not copied to", target)
}
