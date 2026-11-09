package download

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

// A GET on its own thread. sha256 "": not checked. path "": the body stays in memory; else it lands in path, and only
// when its hash matches, so a mangled download never lands.
Job :: struct {
	url, sha256, path: string,
	progress:          Progress,
	done:              bool,  // set last, atomically: body and err are ready
	body:              []byte,
	err:               string,
	allocator:         mem.Allocator,
	thread:            ^thread.Thread,
}

start :: proc(url: string, sha256 := "", path := "", allocator := context.allocator) -> ^Job {
	job := new(Job, allocator)
	job^ = {url = strings.clone(url, allocator), sha256 = strings.clone(sha256, allocator), path = strings.clone(path, allocator), allocator = allocator}
	job.thread = thread.create_and_start_with_poly_data(job, run)
	return job
}

finished :: proc(job: ^Job) -> bool {
	return sync.atomic_load(&job.done)
}

// 0 until the server gives the size.
fraction :: proc(job: ^Job) -> f32 {
	total := sync.atomic_load(&job.progress.total)
	return total > 0 ? f32(sync.atomic_load(&job.progress.received)) / f32(total) : 0
}

// Stops the transfer if it still runs, and waits for its thread.
destroy :: proc(job: ^Job) {
	sync.atomic_store(&job.progress.cancel, true)
	thread.destroy(job.thread)
	context.allocator = job.allocator
	delete(job.url)
	delete(job.sha256)
	delete(job.path)
	delete(job.body)
	delete(job.err)
	free(job)
}

@(private = "file")
run :: proc(job: ^Job) {
	context.allocator = job.allocator
	body, err := http_get(job.url, &job.progress)
	switch {
	case err != "":
	case job.sha256 != "" && !verify(body, job.sha256): err = "the download is damaged: its hash does not match"
	case job.path != "": err = write_landed(job.path, body)
	}
	if err != "" && !sync.atomic_load(&job.progress.cancel) do fmt.eprintfln("openwavu: %s: %s", job.url, err)
	job.err = strings.clone(err)
	if job.path == "" && err == "" do job.body = body
	else do delete(body)
	sync.atomic_store(&job.done, true)
}

// Written beside path first, then renamed over it: path is whole or untouched. A replaced file keeps its mode, so a
// replaced binary still runs.
@(private = "file")
write_landed :: proc(path: string, data: []byte) -> (err: string) {
	part := strings.concatenate({path, ".part"}, context.temp_allocator)
	if os.write_entire_file(part, data) != nil do return fmt.tprintf("can not write %s", part)
	if old, stat_err := os.stat(path, context.temp_allocator); stat_err == nil do os.chmod(part, old.mode & os.Permissions_All)
	if os.rename(part, path) != nil do return fmt.tprintf("can not write %s", path)
	return
}
