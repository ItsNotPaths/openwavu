// openwavu's releases, oldest first in releases.txt; the last is this build. A tag ends in .imp when the importer
// changed, so the stock pack is imported again, or .mod when only the stock modules did, so its files are rewritten.
package release

import "core:slice"
import "core:strings"

HISTORY :: #load("../../releases.txt", string)

Stock_Update :: enum {None, Files, Import}

current :: proc() -> string {
	tags := strings.fields(HISTORY, context.temp_allocator)
	return tags[len(tags) - 1]
}

// A tag this build does not list is a newer release.
known :: proc(tag: string) -> bool {
	return slice.contains(strings.fields(HISTORY, context.temp_allocator), tag)
}

// What a stock pack stamped with release `built` needs to match this build. An unknown stamp imports again.
stock_update :: proc(built: string) -> Stock_Update {
	tags := strings.fields(HISTORY, context.temp_allocator)
	index, found := slice.linear_search(tags, built)
	if !found do return .Import
	later := tags[index + 1:]
	if len(later) == 0 do return .None
	for tag in later do if strings.has_suffix(tag, ".imp") do return .Import
	return .Files
}
