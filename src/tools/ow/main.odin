// ow: the creator tool. Builds a pack's modules with a pinned zig and SDK, so the same source
// always gives the same bytes; registry reviewers rebuild from source and compare hashes.
package ow

import "core:fmt"

// (hole ow-cli :tags (tools sdk)) no ow new (templates), ow build (reproducible, links build/sdk/libow_db.a and the SDK by itself) or ow run.
main :: proc() {
	fmt.eprintln("ow: not built")
}
