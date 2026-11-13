// The arena ring (FUN_001bf15c): fighters farther apart than the pull-in distance are pulled back onto a circle of
// this radius. Stage 12 (battle settings stage +0x168, FUN_001c50e4) has a wider one, and starts side 1 on the far
// side of the start line (FUN_001c548c: x -1000, stage 12 +2500; side 2 mirrors it). mm.
package tk6_convert

import "../../db"

@(private = "file")
WIDE_ARENA_STAGE :: 12

write_stage_arena :: proc(w: ^db.Writer, stage: string, number: int) {
	radius, pull_in, start_offset := 4012.0, 5931.3, -1000.0
	if number == WIDE_ARENA_STAGE do radius, pull_in, start_offset = 5000.0, 7391.95, 2500.0
	db.insert(w, "stage_arena", stage, radius, pull_in, start_offset)
}
