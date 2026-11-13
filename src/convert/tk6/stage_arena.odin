// The arena ring (FUN_001bf15c): fighters farther apart than the pull-in distance are pulled back onto a circle of
// this radius. Stage 12 (battle settings stage +0x168, FUN_001c50e4) has a wider one. mm.
package tk6_convert

import "../../db"

@(private = "file")
WIDE_ARENA_STAGE :: 12

write_stage_arena :: proc(w: ^db.Writer, stage: string, number: int) {
	radius, pull_in := 4012.0, 5931.3
	if number == WIDE_ARENA_STAGE do radius, pull_in = 5000.0, 7391.95
	db.insert(w, "stage_arena", stage, radius, pull_in)
}
