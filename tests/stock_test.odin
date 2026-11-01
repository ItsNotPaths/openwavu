package tests

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:testing"
import convert "../src/convert/tk5"
import "../src/db"
import formats "../src/formats/tk5"
import tk5 "../src/importer/tk5"

STOCK_DB :: "build/stock_test.db"
T5M_HEAD :: 4 + 4 + 37 * 4
T5M_MOVE :: 0x4d
T5M_MOVE_FLAGS :: 52  // T5Move.flags
T5M_MOVE_RIDES :: 76  // T5Move.rides_partner
CANCEL_SIZE :: 24
CANCEL_OPTION :: 22  // T5Cancel.option
CANCEL_PICK :: 10    // T5Cancel.tracking_pick
T5M_MOVE_TRACK :: 68  // T5Move.tracking: row, far row, far source, pad, far angle u16, pad 2
BODY_HEAD_TOP :: 192  // T5Body.head_top: measured from the idle pose, not a stock rule
HEAD_TOP_TOLERANCE :: 0.001  // mm: the sim's f32 pose against body.py's f64 numpy

Packer :: #type proc(s: ^db.Stmt, out: ^[dynamic]byte)

// The stock rule rows hold exactly what tk5decomp's sim files hold, for every character.
@(test)
stock_rows_match_sim_files :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)

	im := tk5.Import{archive = {table, f}}
	characters := formats.CHARACTERS
	w, create_err := db.create(STOCK_DB, TK5_SCHEMA)
	if !testing.expect_value(t, create_err, "") do return
	for name, i in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		packed, _ := tk5.read_entry(im.archive, formats.MOTBIN_FIRST + 2 * i)
		data, unpacked := formats.unlz(packed, context.temp_allocator)
		m, read := formats.read_motbin(data, context.temp_allocator)
		if !testing.expect(t, unpacked && read, name) do continue
		testing.expect_value(t, convert.write_moveset_rows(&w, name, formats.container_owner(characters[i].container), m), "")
		skeleton, has_skeleton := tk5.character_skeleton(&im, characters[i])
		if !testing.expect(t, has_skeleton, name) do continue
		convert.write_skeleton_rows(&w, name, skeleton)
		top, measured := tk5.idle_head_top(&im, characters[i], m, data, &skeleton)
		testing.expect(t, measured, name)
		testing.expect_value(t, convert.write_stock_rows(&w, name, i, m, top), "")
	}
	if !testing.expect_value(t, db.finish(&w), "") do return
	defer os.remove(STOCK_DB)

	h: ^db.Sqlite
	if !testing.expect(t, db.open_v2(STOCK_DB, &h, db.OPEN_READWRITE, nil) == db.OK) do return
	defer db.close_v2(h)
	dumper_ok := build_sim_tool(SKELETON_DUMP, "tests/ref/skeleton_dump.c", "modules/tk5/sim/skel.c")
	testing.expect(t, dumper_ok, "tests/ref/skeleton_dump.c did not build")
	for name in MOTBIN_NAMES {
		defer free_all(context.temp_allocator)
		file, read_err := os.read_entire_file(fmt.tprintf(TK5 + "/data/%s.t5m", name), context.temp_allocator)
		if read_err != nil do continue
		want, got := tag(file, "BODY"), body_row(h, name)
		if len(want) == BODY_HEAD_TOP + 4 && len(got) == len(want) {
			want_top, _ := endian.get_f32(want[BODY_HEAD_TOP:], .Little)
			got_top, _ := endian.get_f32(got[BODY_HEAD_TOP:], .Little)
			testing.expectf(t, abs(want_top - got_top) <= HEAD_TOP_TOLERANCE, "%s head_top %v, sim file %v", name, got_top, want_top)
			copy(got[BODY_HEAD_TOP:], want[BODY_HEAD_TOP:][:4])
		}
		check(t, name, "BODY", want, got)
		check(t, name, "ANCH", tag(file, "ANCH"), anch_row(h, name))
		check(t, name, "GAZE", tag(file, "GAZE"), rows(h, name, "SELECT tilt, head_turn FROM gaze WHERE character = ?", pack_gaze))
		check(t, name, "HITP", tag(file, "HITP"), rows(h, name, "SELECT end_kind, end_index, start_kind, start_index FROM hit_pair WHERE character = ? ORDER BY move, slot", pack_hit_pair))
		check(t, name, "SBND", tag(file, "SBND"), rows(h, name, "SELECT offset, width_0, width_1, width_2 FROM side_band WHERE character = ? ORDER BY idx", pack_u16x4))
		check(t, name, "REQS", tag(file, "REQS"), rows(h, name, "SELECT id, param FROM requirement WHERE character = ? ORDER BY list, pos", pack_u16x2))
		check(t, name, "CANC option", field(tag(file, "CANC"), CANCEL_SIZE, CANCEL_OPTION, 2), rows(h, name, "SELECT option FROM cancel WHERE character = ? ORDER BY list, pos", pack_u16))
		check(t, name, "GRPC option", field(tag(file, "GRPC"), CANCEL_SIZE, CANCEL_OPTION, 2), rows(h, name, "SELECT option FROM group_cancel WHERE character = ? ORDER BY list, pos", pack_u16))
		move_count, _ := endian.get_i32(file[4:], .Little)
		moves := file[T5M_HEAD:][:int(move_count) * T5M_MOVE]
		want_moves := make([dynamic]byte, context.temp_allocator)
		append(&want_moves, ..field(moves, T5M_MOVE, T5M_MOVE_FLAGS, 4))
		append(&want_moves, ..field(moves, T5M_MOVE, T5M_MOVE_RIDES, 1))
		got_moves := make([dynamic]byte, context.temp_allocator)
		append(&got_moves, ..rows(h, name, "SELECT flags FROM move WHERE character = ? ORDER BY idx", pack_u32))
		append(&got_moves, ..rows(h, name, "SELECT rides_partner FROM move WHERE character = ? ORDER BY idx", pack_u8))
		check(t, name, "move flags/rides", want_moves[:], got_moves[:])
		check(t, name, "TRKR", tag(file, "TRKR"), rows(h, name, `SELECT law, start, target, stock_mode, gate_until, gate_min_distance, gate_kind,
			rate_normal, rate_late, rate_air, rate_late_from, rate_frames, rate_halving, rate_by_distance, limit_total,
			sweep_front, sweep_left, sweep_back, sweep_right, end_grace, end_yaw_when, end_pivot_when, end_phase
			FROM tracking_row WHERE character = ? ORDER BY idx`, pack_facing_row))
		check(t, name, "TOVR", tag(file, "TOVR"), rows(h, name, "SELECT row, far_row, far_source, far_angle FROM tracking_override WHERE character = ? ORDER BY idx", pack_track))
		check(t, name, "TFIX", tag(file, "TFIX"), rows(h, name, "SELECT row, far_row, far_source, far_angle FROM tracking_fixed WHERE character = ? ORDER BY idx", pack_track))
		check(t, name, "move tracking", field(moves, T5M_MOVE, T5M_MOVE_TRACK, 8), rows(h, name, "SELECT tracking_row, tracking_far_row, tracking_far_source, tracking_far_angle FROM move WHERE character = ? ORDER BY idx", pack_track))
		check(t, name, "CANC pick", field(tag(file, "CANC"), CANCEL_SIZE, CANCEL_PICK, 2), rows(h, name, "SELECT tracking_pick FROM cancel WHERE character = ? ORDER BY list, pos", pack_u16))
		check(t, name, "GRPC pick", field(tag(file, "GRPC"), CANCEL_SIZE, CANCEL_PICK, 2), rows(h, name, "SELECT tracking_pick FROM group_cancel WHERE character = ? ORDER BY list, pos", pack_u16))
		check(t, name, "XPRP", tag(file, "XPRP"), rows(h, name, "SELECT unk_00, unk_02, unk_04 >> 16, unk_04 & 65535 FROM extra_prop WHERE character = ? ORDER BY list, pos", pack_u16x4))
		if dumper_ok do check(t, name, "skeleton", sim_skeleton(name), skeleton_rows(h, name))
		check(t, name, "HITS", tag(file, "HITS"), rows(h, name, "SELECT attack_bones, slots, launches FROM move_hits WHERE character = ? ORDER BY move", pack_move_hits))
	}
}

SKELETON_DUMP :: "build/skeleton_dump"

// What the sim's loader builds from the character's .t5b (tests/ref/skeleton_dump.c).
@(private = "file")
sim_skeleton :: proc(name: string) -> []byte {return run_sim_tool(SKELETON_DUMP, fmt.tprintf(TK5 + "/data/%s.t5b", name))}

@(private = "file")
skeleton_rows :: proc(h: ^db.Sqlite, char: string) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, ..rows(h, char, "SELECT scale FROM skeleton WHERE character = ?", pack_f32))
	append(&out, ..rows(h, char, "SELECT parent, x, y, z, rx, ry, rz FROM skeleton_a WHERE character = ? ORDER BY slot", pack_bone))
	append(&out, ..rows(h, char, "SELECT parent, x, y, z FROM skeleton_b WHERE character = ? ORDER BY slot", pack_bone))
	return out[:]
}

@(private = "file")
check :: proc(t: ^testing.T, name, tag_name: string, want, got: []byte) {
	testing.expectf(t, bytes.equal(want, got), "%s %s: db rows differ from the sim file (%d vs %d bytes)", name, tag_name, len(got), len(want))
}

// The records of one tag of a .t5m file; nil if it has none.
@(private = "file")
tag :: proc(file: []byte, name: string) -> []byte {
	moves, _ := endian.get_i32(file[4:], .Little)
	at := T5M_HEAD + int(moves) * T5M_MOVE
	for at + 12 <= len(file) {
		count, _ := endian.get_u32(file[at + 4:], .Little)
		size, _ := endian.get_u32(file[at + 8:], .Little)
		records := file[at + 12:][:count * size]
		if string(file[at:][:4]) == name do return records
		at += 12 + len(records)
	}
	return nil
}

// Bytes [at, at + width) of every record.
@(private = "file")
field :: proc(records: []byte, size, at, width: int) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	for start := 0; start + size <= len(records); start += size do append(&out, ..records[start + at:][:width])
	return out[:]
}

// T5Body: 14 hurt rows, 8 push rows, cut, probe x z radius, head top.
@(private = "file")
body_row :: proc(h: ^db.Sqlite, char: string) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, ..rows(h, char, "SELECT radius, bone, lift FROM body_hurt WHERE character = ? ORDER BY idx", pack_hurt))
	append(&out, ..rows(h, char, "SELECT radius, bone FROM body_push WHERE character = ? ORDER BY idx", pack_push))
	append(&out, ..rows(h, char, "SELECT throw_range_cut, probe_x, probe_z, probe_radius, head_top FROM body WHERE character = ?", pack_floats))
	return out[:]
}

// T5BodyPoints: u32 count, 2 point rows (unused ones zero), u8 hitscan, u8 projectile, pad 2.
@(private = "file")
anch_row :: proc(h: ^db.Sqlite, char: string) -> []byte {
	points := rows(h, char, "SELECT bone, x, y, z FROM body_point WHERE character = ? ORDER BY idx", pack_point)
	out := make([dynamic]byte, context.temp_allocator)
	put(&out, 4, u32(len(points) / 16))
	append(&out, ..points)
	pad(&out, 32 - len(points))
	append(&out, ..rows(h, char, "SELECT hitscan, projectile FROM body WHERE character = ?", pack_shots))
	return out[:]
}

// Each row of the query packed by `pack`; the query's one parameter is the character.
@(private = "file")
rows :: proc(h: ^db.Sqlite, char: string, sql: cstring, pack: Packer) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	s: ^db.Stmt
	db.prepare_v2(h, sql, -1, &s, nil)
	defer db.finalize(s)
	db.bind_text(s, 1, raw_data(char), i32(len(char)), db.TRANSIENT)
	for db.step(s) == db.ROW do pack(s, &out)
	return out[:]
}

@(private = "file")
pack_hurt :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 2, column_u32(s, 0)); put(out, 1, column_u32(s, 1)); pad(out, 1); put_f32(out, column_f32(s, 2))}
@(private = "file")
pack_push :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put_f32(out, column_f32(s, 0)); put(out, 1, column_u32(s, 1)); pad(out, 3)}
@(private = "file")
pack_point :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 1, column_u32(s, 0)); pad(out, 3); for c in i32(1) ..< 4 do put_f32(out, column_f32(s, c))}
@(private = "file")
pack_shots :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 1, column_u32(s, 0)); put(out, 1, column_u32(s, 1)); pad(out, 2)}
@(private = "file")
pack_gaze :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put_f32(out, column_f32(s, 0)); put(out, 2, column_u32(s, 1)); pad(out, 2)}
@(private = "file")
pack_hit_pair :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {for c in i32(0) ..< 4 do put(out, 1, column_u32(s, c))}
@(private = "file")
pack_move_hits :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 4, column_u32(s, 0)); put(out, 1, column_u32(s, 1)); put(out, 1, column_u32(s, 2)); pad(out, 2)}
@(private = "file")
pack_f32 :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put_f32(out, column_f32(s, 0))}
@(private = "file")
pack_bone :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 1, column_u32(s, 0)); for c in i32(1) ..< db.column_count(s) do put_f32(out, column_f32(s, c))}
@(private = "file")
pack_floats :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {for c in i32(0) ..< 5 do put_f32(out, column_f32(s, c))}

@(private = "file")
pack_u8 :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 1, column_u32(s, 0))}
@(private = "file")
pack_u16 :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 2, column_u32(s, 0))}
@(private = "file")
pack_u32 :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {put(out, 4, column_u32(s, 0))}
@(private = "file")
pack_u16x2 :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {for c in i32(0) ..< 2 do put(out, 2, column_u32(s, c))}
@(private = "file")
pack_u16x4 :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {for c in i32(0) ..< 4 do put(out, 2, column_u32(s, c))}

// T5FacingRow, 68 bytes: 4 u8; gate i32 i32 u8 pad 3; rate 5 i32, u8 u8 pad 2; limit 5 i32; end i32 u8 u8 u8 pad.
@(private = "file")
pack_facing_row :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {
	widths := [?]int{1, 1, 1, 1, 4, 4, 1, 4, 4, 4, 4, 4, 1, 1, 4, 4, 4, 4, 4, 4, 1, 1, 1}
	pads := [?]int{6 = 3, 13 = 2, 22 = 1}
	for width, c in widths {
		put(out, width, column_u32(s, i32(c)))
		pad(out, pads[c])
	}
}

// T5MoveTracking: row, far row, far source, pad, far angle u16, pad 2.
@(private = "file")
pack_track :: proc(s: ^db.Stmt, out: ^[dynamic]byte) {
	for c in i32(0) ..< 3 do put(out, 1, column_u32(s, c))
	pad(out, 1)
	put(out, 2, column_u32(s, 3))
	pad(out, 2)
}

@(private = "file")
column_u32 :: proc(s: ^db.Stmt, column: i32) -> u32 {return u32(db.column_int64(s, column))}

@(private = "file")
column_f32 :: proc(s: ^db.Stmt, column: i32) -> f32 {return f32(db.column_double(s, column))}

@(private = "file")
put :: proc(out: ^[dynamic]byte, width: int, v: u32) {
	buf: [4]byte
	endian.put_u32(buf[:], .Little, v)
	append(out, ..buf[:width])
}

@(private = "file")
put_f32 :: proc(out: ^[dynamic]byte, v: f32) {
	buf: [4]byte
	endian.put_f32(buf[:], .Little, v)
	append(out, ..buf[:])
}

@(private = "file")
pad :: proc(out: ^[dynamic]byte, count: int) {
	for _ in 0 ..< count do append(out, 0)
}
