package match

// (hole replay-file :tags (net sim)) no replay file: confirmed inputs of both pads run-length encoded, with format version, pack hash, mode, params, seed, sides, loadouts, names, match id, start time, end frame and result; byte-identical for both players (docs/packs.md).
write_replay :: proc(m: ^Match, path: string) -> (ok: bool) {
	return false
}
