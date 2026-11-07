package game

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"
import "../content"
import "../titlepack"
import "../ui"

NETWORK :: "https://openwavu.paths.place:9443"
CACHE_DIR :: titlepack.PACKS_DIR + "/cache"  // fronts and thumbs by hash; they never change

// The network's packs (GET /store), fetched when the store column first shows.
Store :: struct {
	fetched:  bool,
	answer:   []byte,  // packs point into it
	packs:    []titlepack.Listed,
	err:      string,
	versions: Versions,
}

// Every version of the picked store pack, for the install popup.
Versions :: struct {
	id:      string,
	answer:  []byte,
	listed:  []titlepack.Listed,
	err:     string,
}

Store_Pick :: struct {
	index:     int,
	has_front: bool,  // downloaded once at the pick, so a failed download is not tried again each frame
}

store_destroy :: proc(store: ^Store) {
	delete(store.answer)
	delete(store.packs)
	delete(store.err)
	versions_destroy(&store.versions)
}

@(private = "file")
versions_destroy :: proc(versions: ^Versions) {
	delete(versions.id)
	delete(versions.answer)
	delete(versions.listed)
	delete(versions.err)
	versions^ = {}
}

store_column :: proc(l: ^Launcher, u: ^ui.Ui) {
	if !l.store.fetched do store_fetch(&l.store)
	if clay.UI()(side_column()) {
		column_head(u, "STORE", clay.ID("SearchStore"), &l.search_store)
		if l.store.err != "" do ui.label(l.store.err, tint = ui.TEXT_DIM)
		if clay.UI()(slot_list(u, clay.ID("StoreList"))) {
			for pack, index in l.store.packs {
				if !matches(pack.id, strings.to_string(l.search_store)) do continue
				picked, is_store := l.selected.(Store_Pick)
				art := store_thumb(l, u, pack)
				if ui.slot(u, clay.ID("StorePack", u32(index)), pack.id, art, is_store && picked.index == index) {
					l.selected = Store_Pick{index, store_front(pack) != ""}
				}
			}
		}
	}
}

@(private = "file")
store_fetch :: proc(store: ^Store) {
	store.fetched = true
	answer, err := content.http_get(NETWORK + "/store")
	if err != "" {
		store.err = fmt.aprintf("The store did not answer: %s", err)
		return
	}
	store.answer = answer
	store.packs = titlepack.read_listing(string(answer))
}

// Slot art by key, loaded once; nil when the pack has none or it does not load.
remember_thumb :: proc(l: ^Launcher, u: ^ui.Ui, key: string, bytes: []byte) -> ^sdl.Texture {
	texture := bytes == nil ? nil : ui.load_image(u, bytes)
	l.thumbs[strings.clone(key)] = texture
	return texture
}

installed_thumb :: proc(l: ^Launcher, u: ^ui.Ui, pack: titlepack.Title_Pack) -> ^sdl.Texture {
	key := fmt.tprintf("%s@%s", pack.path, pack.version)
	if texture, known := l.thumbs[key]; known do return texture
	files, opened := titlepack.open_files(pack.path)
	if !opened do return remember_thumb(l, u, key, nil)
	defer titlepack.close_files(&files)
	bytes, _ := titlepack.read_file(files, titlepack.THUMB)
	return remember_thumb(l, u, key, bytes)
}

@(private = "file")
store_thumb :: proc(l: ^Launcher, u: ^ui.Ui, pack: titlepack.Listed) -> ^sdl.Texture {
	if pack.thumb_sha256 == "" do return nil
	if texture, known := l.thumbs[pack.thumb_sha256]; known do return texture
	path := cached(pack.thumb_sha256, ".png", fmt.tprintf("%s@%s.thumb.png", pack.id, pack.version))
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	return remember_thumb(l, u, pack.thumb_sha256, err == nil ? bytes : nil)
}

// A cached file named by its hash, downloaded first when missing. "" when it can not be had.
cached :: proc(sha256, suffix, name: string) -> (path: string) {
	path, _ = filepath.join({CACHE_DIR, strings.concatenate({sha256, suffix}, context.temp_allocator)}, context.temp_allocator)
	if os.exists(path) do return
	os.make_directory_all(CACHE_DIR)
	if err := content.download_checked(fmt.tprintf("%s/files/%s", NETWORK, name), sha256, path); err != "" {
		fmt.eprintfln("openwavu: %s: %s", name, err)
		return ""
	}
	return
}

// A store pack's front tar, from the cache.
store_front :: proc(pack: titlepack.Listed) -> string {
	return cached(pack.front_sha256, ".front.tar", fmt.tprintf("%s@%s.front.tar", pack.id, pack.version))
}

// Every version, newest first; Install downloads it over the installed one and picks it.
store_install_popup :: proc(l: ^Launcher, u: ^ui.Ui, pick: Store_Pick) {
	pack := l.store.packs[pick.index]
	versions := &l.store.versions
	if versions.id != pack.id {
		versions_destroy(versions)
		versions.id = strings.clone(pack.id)
		answer, err := content.http_get(fmt.tprintf("%s/versions/%s", NETWORK, pack.id))
		versions.answer, versions.err = answer, strings.clone(err)
		versions.listed = titlepack.read_listing(string(answer))
	}
	ui.label(fmt.tprintf("Install %s", pack.id), ui.HEAD_SIZE, engraved = true, face = .Display)
	if versions.err != "" do ui.label(versions.err, tint = ui.WARN)
	for version, index in versions.listed {
		if clay.UI()(ui.row(8)) {
			ui.label(index == 0 ? fmt.tprintf("Latest  %s", version.version) : version.version)
			ui.spacer()
			if ui.button(u, clay.ID("InstallVersion", u32(index)), fmt.tprintf("Install  %.1f MB", f64(version.size) / 1e6)) {
				install_from_store(l, version)
			}
		}
	}
}

@(private = "file")
install_from_store :: proc(l: ^Launcher, version: titlepack.Listed) {
	path, _ := filepath.join({titlepack.PACKS_DIR, strings.concatenate({version.id, ".tar"}, context.temp_allocator)}, context.temp_allocator)
	if err := content.download_checked(fmt.tprintf("%s/files/%s@%s.tar", NETWORK, version.id, version.version), version.sha256, path); err != "" {
		delete(l.store.versions.err)
		l.store.versions.err = strings.clone(err)
		return
	}
	titlepack.destroy_installed(l.packs)
	l.packs = titlepack.installed()
	for pack, index in l.packs do if pack.id == version.id do l.selected = index
	l.popup.open = false
}
