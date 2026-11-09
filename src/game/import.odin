package game

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import clay "../../vendor/clay"
import tk5 "../importer/tk5"
import "../download"
import "../release"
import "../titlepack"
import "../ui"

// The stock pack build, on its own thread; the launcher reads its progress each frame.
// (hole import-cancel :tags (game importer) :sev polish) an import can not be cancelled; closing openwavu waits for it.
Import_Job :: struct {
	thread:   ^thread.Thread,
	inputs:   []string,
	progress: tk5.Progress,
	err:      string,
	refresh:  bool,  // a .mod update: rewrite the stock pack's root files, no import
	finished: bool,  // atomic; err is set before it
	listed:   bool,  // the launcher reloaded its packs after it finished
}

import_start :: proc(job: ^Import_Job, paths: []string, refresh := false) {
	import_destroy(job)
	job.inputs = make([]string, len(paths))
	for path, i in paths do job.inputs[i] = strings.clone(path)
	job.refresh = refresh
	job.thread = thread.create_and_start_with_poly_data(job, proc(job: ^Import_Job) {
		if job.refresh {
			job.err = tk5.refresh_pack(titlepack.base_path(tk5.STOCK_PACK), &job.progress)
		} else {
			job.err = strings.clone(tk5.build_pack(job.inputs, titlepack.packs_dir(), progress = &job.progress))
		}
		sync.atomic_store(&job.finished, true)
	})
}

importing :: proc(job: ^Import_Job) -> bool {
	return job.thread != nil && !sync.atomic_load(&job.finished)
}

// A tile waits for an update when it is not locked and this release or the network has a newer one.
update_waiting :: proc(l: ^Launcher, pack: titlepack.Title_Pack) -> bool {
	if pack.locked do return false
	if os.is_dir(pack.path) do return release.stock_update(pack.version) != .None
	for listed in l.store.listing.packs do if listed.id == pack.id do return listed.version != pack.version
	return false
}

// A .mod release rewrites the stock pack where it is; a .imp release imports it again on the install screen.
// A store pack downloads the network's latest over its tile.
update_pack :: proc(l: ^Launcher, pick: int) {
	pack := l.packs[pick]
	if importing(&l.importer) || l.store.install.job != nil do return
	if !os.is_dir(pack.path) {
		l.popup = {.Update, true}
		for listed, index in l.store.listing.packs {
			if listed.id == pack.id do install_start(&l.store.install, l.settings.network, l.store.listing.packs[index:][:1], 0)
		}
		return
	}
	l.popup = {.Update, true}
	switch release.stock_update(pack.version) {
	case .None:
	case .Files:
		import_start(&l.importer, nil, refresh = true)
	case .Import:
		l.popup.open = false
		inputs, has_inputs := titlepack.import_inputs(pack.path, context.temp_allocator)
		l.selected = Install_Screen{}
		l.source = .Game_Files
		if has_inputs do import_start(&l.importer, inputs)
	}
}

import_destroy :: proc(job: ^Import_Job) {
	if job.thread != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
	}
	for path in job.inputs do delete(path)
	delete(job.inputs)
	delete(job.err)
	job^ = {}
}

import_status :: proc(l: ^Launcher, u: ^ui.Ui) {
	job := &l.importer
	if !sync.atomic_load(&job.finished) {
		done, total := sync.atomic_load(&job.progress.done), sync.atomic_load(&job.progress.total)
		ui.label(fmt.tprintf("Importing...  %d%%", total > 0 ? 100 * done / total : 0), tint = ui.LED)
		return
	}
	if job.err == "" {
		ui.label(fmt.tprintf("Built %s/%s", titlepack.packs_dir(), tk5.STOCK_PACK), tint = ui.LED)
	} else {
		ui.label(job.err, tint = ui.WARN)
	}
	if ui.button(u, clay.ID("ImportDone"), "OK") do import_destroy(job)
}

// Reloads the packs once an import finishes, keeping the picked tile.
import_poll :: proc(l: ^Launcher) {
	job := &l.importer
	if job.thread == nil || job.listed || !sync.atomic_load(&job.finished) do return
	job.listed = true
	picked, is_pack := l.selected.(int)
	tile := is_pack ? strings.clone(filepath.stem(l.packs[picked].path), context.temp_allocator) : ""
	front_close(&l.front)  // a rewritten stock pack has a new front
	reload_packs(l)
	if is_pack do select_tile(l, tile)
	if job.refresh && job.err == "" do import_destroy(job)  // a failed one stays for the update popup
}

// The game files set in the settings, offered above the browser when they look importable. The path when Import is pressed.
settings_game :: proc(l: ^Launcher, u: ^ui.Ui) -> (picked: Maybe(string)) {
	path := strings.to_string(l.settings.tk5_files)
	if !game_files(path) do return
	if clay.UI()(ui.row(8)) {
		ui.label("Tekken 5 DR", face = .Display)
		ui.label(path, tint = ui.TEXT_DIM)
		ui.spacer()
		if ui.button(u, clay.ID("ImportSettingsGame"), "Import") do picked = path
	}
	return
}

// The running update's bar, its error, or the pack's version once done.
update_popup :: proc(l: ^Launcher, pick: int) {
	pack := l.packs[pick]
	job := &l.importer
	ui.label(fmt.tprintf("Update %s", pack.name), ui.HEAD_SIZE, engraved = true, face = .Display)
	switch {
	case l.store.install.job != nil:
		ui.label(fmt.tprintf("Downloading %s", l.store.install.version))
		ui.progress(download.fraction(l.store.install.job))
	case l.store.install.err != "":
		ui.label(l.store.install.err, tint = ui.WARN)
	case importing(job) && job.refresh:
		done, total := sync.atomic_load(&job.progress.done), sync.atomic_load(&job.progress.total)
		ui.label("Writing this release's modules and hashing the pack")
		ui.progress(total > 0 ? f32(done) / f32(total) : 0)
	case job.refresh && job.err != "":
		ui.label(job.err, tint = ui.WARN)
	case update_waiting(l, pack):
		ui.label("Waiting to start.", tint = ui.TEXT_DIM)
	case:
		ui.label(fmt.tprintf("Up to date: %s", pack.version), tint = ui.LED)
	}
}
