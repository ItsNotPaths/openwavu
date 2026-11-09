package game

import "core:fmt"
import "core:os"
import "core:strings"
import clay "../../vendor/clay"
import "../download"
import "../release"
import "../ui"

// The latest GitHub release: its release.txt holds the tag and the binary's SHA-256. release.sh uploads both.
RELEASE_URL :: "https://github.com/ItsNotPaths/openwavu/releases/latest/download/"
RELEASE_BINARY :: "openwavu-linux"

// The new binary lands over this one; this process runs on until the player restarts.
Binary_Update :: struct {
	check:  ^download.Job,
	binary: ^download.Job,
}

binary_update_destroy :: proc(update: ^Binary_Update) {
	if update.check != nil do download.destroy(update.check)
	if update.binary != nil do download.destroy(update.binary)
}

// The top bar's part: an update button, then its progress.
binary_update_bar :: proc(update: ^Binary_Update, u: ^ui.Ui) {
	tag, sha256, newer := newer_binary(update)
	if !newer do return
	switch {
	case update.binary == nil:
		if ui.button(u, clay.ID("UpdateBinary"), fmt.tprintf("Update to %s", tag), ui.BAR_BUTTON, nav = false) {
			path, err := os.get_executable_path(context.temp_allocator)
			if err != nil do fmt.eprintln("openwavu: can not find this binary:", err)
			else do update.binary = download.start(RELEASE_URL + RELEASE_BINARY, sha256, path)
		}
	case !download.finished(update.binary):
		ui.label(fmt.tprintf("Downloading %s %d%%", tag, int(download.fraction(update.binary) * 100)), tint = ui.TEXT_DIM)
	case update.binary.err != "":
		ui.label(fmt.tprintf("Update failed: %s", update.binary.err), tint = ui.WARN)
	case:
		ui.label(fmt.tprintf("%s installed: restart openwavu", tag), tint = ui.TEXT_DIM)
	}
}

// The latest tag and its hash, when this build does not know the tag yet.
@(private = "file")
newer_binary :: proc(update: ^Binary_Update) -> (tag, sha256: string, newer: bool) {
	if update.check == nil do update.check = download.start(RELEASE_URL + "release.txt")
	if !download.finished(update.check) || update.check.err != "" do return
	fields := strings.fields(string(update.check.body), context.temp_allocator)
	if len(fields) != 2 do return
	return fields[0], fields[1], !release.known(fields[0])
}
