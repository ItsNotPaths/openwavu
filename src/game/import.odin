package game

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import clay "../../vendor/clay"
import tk5 "../importer/tk5"
import "../titlepack"
import "../ui"

// The stock pack build, on its own thread; the launcher reads its progress each frame.
// (hole import-cancel :tags (game importer) :sev polish) an import can not be cancelled; closing openwavu waits for it.
Import_Job :: struct {
	thread:   ^thread.Thread,
	inputs:   []string,
	progress: tk5.Progress,
	err:      string,
	finished: bool,  // atomic; err is set before it
}

import_start :: proc(job: ^Import_Job, paths: []string) {
	import_destroy(job)
	job.inputs = make([]string, len(paths))
	for path, i in paths do job.inputs[i] = strings.clone(path)
	job.thread = thread.create_and_start_with_poly_data(job, proc(job: ^Import_Job) {
		job.err = strings.clone(tk5.build_pack(job.inputs, titlepack.packs_dir(), progress = &job.progress))
		sync.atomic_store(&job.finished, true)
	})
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
	if ui.button(u, clay.ID("ImportDone"), "OK") {
		import_destroy(job)
		reload_packs(l)
	}
}
