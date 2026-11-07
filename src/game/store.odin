package game

import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"
import clay "../../vendor/clay"
import "../download"
import "../titlepack"
import "../ui"

NETWORK :: "https://openwavu.paths.place:9443"
CACHE_DOWNLOADS_MAX :: 4  // cache files downloading at once

// The network's packs. Every GET runs on its own thread; the launcher polls each frame.
Store :: struct {
	listing:     Listing,  // GET /store, started when the store column first shows
	versions:    Listing,  // GET /versions/<id> of the picked store pack
	versions_id: string,
	cache:       map[string]^download.Job,  // by hash; a failed one stays, so it is not tried again
	install:     Install,
}

// A listing GET; packs read once it lands, pointing into its body.
Listing :: struct {
	job:   ^download.Job,
	packs: []titlepack.Listed,
	read:  bool,
}

// The one running install, and the error of the last one.
Install :: struct {
	job:     ^download.Job,
	id:      string,
	version: string,
	err:     string,
}

Store_Pick :: struct {
	index: int,
}

store_destroy :: proc(store: ^Store) {
	listing_destroy(&store.listing)
	listing_destroy(&store.versions)
	delete(store.versions_id)
	for hash, job in store.cache {
		download.destroy(job)
		delete(hash)
	}
	delete(store.cache)
	install_destroy(&store.install)
}

@(private = "file")
listing_destroy :: proc(listing: ^Listing) {
	if listing.job != nil do download.destroy(listing.job)
	delete(listing.packs)
	listing^ = {}
}

@(private = "file")
install_destroy :: proc(install: ^Install) {
	if install.job != nil do download.destroy(install.job)
	delete(install.id)
	delete(install.version)
	delete(install.err)
	install^ = {}
}

// "" while it downloads or when it landed; else why it failed.
@(private = "file")
listing_poll :: proc(listing: ^Listing) -> (err: string) {
	if listing.read || !download.finished(listing.job) do return
	if listing.job.err != "" do return listing.job.err
	listing.packs = titlepack.read_listing(string(listing.job.body))
	listing.read = true
	return
}

// Each frame: a finished install replaces the installed pack and picks it.
store_poll :: proc(l: ^Launcher) {
	install := &l.store.install
	if install.job == nil || !download.finished(install.job) do return
	defer {
		download.destroy(install.job)
		install.job = nil
	}
	if install.job.err != "" {
		install.err = strings.clone(install.job.err)
		return
	}
	titlepack.destroy_installed(l.packs)
	l.packs = titlepack.installed()
	for pack, index in l.packs do if pack.id == install.id do l.selected = index
	l.popup.open = false
}

store_column :: proc(l: ^Launcher, u: ^ui.Ui) {
	if l.store.listing.job == nil do l.store.listing.job = download.start(NETWORK + "/store")
	err := listing_poll(&l.store.listing)
	if clay.UI()(side_column()) {
		column_head(u, "STORE", clay.ID("SearchStore"), &l.search_store)
		if err != "" do ui.label(fmt.tprintf("The store did not answer: %s", err), tint = ui.TEXT_DIM)
		if clay.UI()(slot_list(u, clay.ID("StoreList"))) {
			for pack, index in l.store.listing.packs {
				if !matches(pack.id, strings.to_string(l.search_store)) do continue
				picked, is_store := l.selected.(Store_Pick)
				art := store_thumb(l, u, pack)
				if ui.slot(u, clay.ID("StorePack", u32(index)), pack.id, art, is_store && picked.index == index) {
					l.selected = Store_Pick{index}
				}
			}
		}
	}
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
	path, waiting := cached(&l.store, pack.thumb_sha256, ".png", fmt.tprintf("%s@%s.thumb.png", pack.id, pack.version))
	if waiting do return nil
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	return remember_thumb(l, u, pack.thumb_sha256, path != "" && err == nil ? bytes : nil)
}

// A cached file named by its hash, downloaded first when missing. waiting while it downloads; path "" when it can
// not be had.
@(private = "file")
cached :: proc(store: ^Store, sha256, suffix, name: string) -> (path: string, waiting: bool) {
	cache_dir := titlepack.join_path(titlepack.packs_dir, "cache")  // fronts and thumbs by hash; they never change
	path = titlepack.join_path(cache_dir, strings.concatenate({sha256, suffix}, context.temp_allocator))
	if os.exists(path) do return path, false
	job, started := store.cache[sha256]
	if !started {
		if cache_downloads(store) >= CACHE_DOWNLOADS_MAX do return "", true
		os.make_directory_all(cache_dir)
		store.cache[strings.clone(sha256)] = download.start(fmt.tprintf("%s/files/%s", NETWORK, name), sha256, path)
		return "", true
	}
	if !download.finished(job) do return "", true
	return job.err == "" ? path : "", false
}

@(private = "file")
cache_downloads :: proc(store: ^Store) -> (running: int) {
	for _, job in store.cache do if !download.finished(job) do running += 1
	return
}

// The picked store pack's front tar; "" until it is in the cache.
store_front :: proc(l: ^Launcher, pick: Store_Pick) -> string {
	pack := l.store.listing.packs[pick.index]
	path, _ := cached(&l.store, pack.front_sha256, ".front.tar", fmt.tprintf("%s@%s.front.tar", pack.id, pack.version))
	return path
}

// Every version, newest first; Install downloads it over the installed one and picks it. While it runs, its bar.
store_install_popup :: proc(l: ^Launcher, u: ^ui.Ui, pick: Store_Pick) {
	pack := l.store.listing.packs[pick.index]
	store := &l.store
	if store.versions_id != pack.id {
		listing_destroy(&store.versions)
		delete(store.versions_id)
		store.versions_id = strings.clone(pack.id)
		store.versions.job = download.start(fmt.tprintf("%s/versions/%s", NETWORK, pack.id))
	}
	ui.label(fmt.tprintf("Install %s", pack.id), ui.HEAD_SIZE, engraved = true, face = .Display)
	if err := listing_poll(&store.versions); err != "" do ui.label(err, tint = ui.WARN)
	if store.install.err != "" do ui.label(store.install.err, tint = ui.WARN)
	if job := store.install.job; job != nil {
		ui.label(fmt.tprintf("Downloading %s %s", store.install.id, store.install.version))
		ui.progress(download.fraction(job))
		return
	}
	for version, index in store.versions.packs {
		if clay.UI()(ui.row(8)) {
			ui.label(index == 0 ? fmt.tprintf("Latest  %s", version.version) : version.version)
			ui.spacer()
			if ui.button(u, clay.ID("InstallVersion", u32(index)), fmt.tprintf("Install  %.1f MB", f64(version.size) / 1e6)) {
				install_start(&store.install, version)
			}
		}
	}
}

// (hole orphaned-packs :tags (game titlepack saves) :needs slot-badges) an older version installs over the latest: no lock button below the favourite star, no packs/<id>@<version>.tar as its own locked tile with its own saves, and an update does not download as a new tile when the installed one is locked; a non-latest download should start locked.
@(private = "file")
install_start :: proc(install: ^Install, version: titlepack.Listed) {
	install_destroy(install)
	path := titlepack.join_path(titlepack.packs_dir, strings.concatenate({version.id, ".tar"}, context.temp_allocator))
	url := fmt.tprintf("%s/files/%s@%s.tar", NETWORK, version.id, version.version)
	install^ = {job = download.start(url, version.sha256, path), id = strings.clone(version.id), version = strings.clone(version.version)}
}
