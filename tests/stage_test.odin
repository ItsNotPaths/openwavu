package tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import formats "../src/formats/tk5"

// Dumps stage_collision.py's walls, grid, cells and floors and stage_start.py's start points, with float bits.
STAGE_DUMP :: `
import sys, numpy as np
sys.path.insert(0, 'tools')
import stage_collision as sc
from stage_start import start_points
def h(a): return ' '.join('%08x' % v for v in np.asarray(a, dtype='<f4').reshape(-1).view('<u4'))
for s in range(sc.COUNT):
    got = sc.load(s)
    if got is None:
        print('S', s, 'none'); continue
    mho, zones = got
    print('S', s)
    for q in mho.quads:
        print('Q', q.obj, q.link, int(q.is_wall), h(q.corners), h(q.normal))
    print('G', mho.grid[0], mho.grid[1], h(mho.grid[2]))
    for o in mho.objects:
        print('O', o.kind, o.link)
    for c in mho.cells:
        print('C', *c)
    for slot in start_points(sc.stage_file(s))['slots']:
        print('T', slot['format'])
        for g in slot['groups']:
            print('R', g['id'], g['count'], g['per_record'], h(g['points']))
    for z in zones:
        print('Z %d %s %016x %d' % (z.flags, h(z.centre), np.float64(z.radius).view('<u8'), len(z.polys)))
        for poly in z.polys:
            print('P', h(np.r_[poly.centre, poly.radius2, poly.normal]), h(poly.points))
`

bits :: proc(b: ^strings.Builder, v: []f32) {
	for f, i in v do fmt.sbprintf(b, i == 0 ? "%08x" : " %08x", transmute(u32)f)
}

dump_stage :: proc(b: ^strings.Builder, id: int, s: formats.Stage, has: bool) {
	if !has || len(s.sections[formats.STAGE_MHO]) < 0x98 {
		fmt.sbprintf(b, "S %d none\n", id)
		return
	}
	fmt.sbprintf(b, "S %d\n", id)
	for &q in s.quads {
		fmt.sbprintf(b, "Q %d %d %d ", q.object, q.link, int(q.is_wall))
		bits(b, (cast([^]f32)&q.corners)[:12])
		strings.write_byte(b, ' ')
		bits(b, q.normal[:])
		strings.write_byte(b, '\n')
	}
	fmt.sbprintf(b, "G %d %d %08x\n", s.grid.nx, s.grid.nz, transmute(u32)s.grid.cell)
	for o in s.objects do fmt.sbprintf(b, "O %d %d\n", o.kind, o.link)
	for c in s.cells {
		strings.write_byte(b, 'C')
		for o in c do fmt.sbprintf(b, " %d", o)
		strings.write_byte(b, '\n')
	}
	for slot in s.start {
		fmt.sbprintf(b, "T %s\n", slot.pos_format ? "pos" : "tkpd")
		for &g in slot.groups {
			fmt.sbprintf(b, "R %d %d %d ", g.id, g.count, g.per_record)
			bits(b, (cast([^]f32)raw_data(g.points))[:8 * len(g.points)])
			strings.write_byte(b, '\n')
		}
	}
	for &z in s.floors {
		fmt.sbprintf(b, "Z %d ", z.flags)
		bits(b, z.centre[:])
		fmt.sbprintf(b, " %016x %d\n", transmute(u64)math.sqrt(f64(z.radius_sq)), len(z.polygons))
		for &p in z.polygons {
			head := [7]f32{p.centre.x, p.centre.y, p.centre.z, p.radius_sq, p.normal.x, p.normal.y, p.normal.z}
			strings.write_string(b, "P ")
			bits(b, head[:])
			strings.write_byte(b, ' ')
			bits(b, (cast([^]f32)raw_data(p.points))[:3 * len(p.points)])
			strings.write_byte(b, '\n')
		}
	}
}

@(test)
stage_collision_matches_reference :: proc(t: ^testing.T) {
	table, ok := read_table()
	if !ok do return
	defer delete(table)
	f, err := os.open(TK5 + "/game/USRDIR/T55DATA1.BIN")
	if err != nil do return
	defer os.close(f)

	cwd, _ := os.get_working_directory(context.temp_allocator)
	python := strings.concatenate({cwd, "/", TK5, "/.venv/bin/python"}, context.temp_allocator)  // not resolved: the venv is a symlink
	state, want, stderr, perr := os.process_exec({working_dir = TK5, command = {python, "-c", STAGE_DUMP}}, context.allocator)
	defer delete(want)
	defer delete(stderr)
	if perr != nil || state.exit_code != 0 {
		testing.expectf(t, false, "reference dump failed: %v %s", perr, stderr)
		return
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for id in 0 ..< formats.STAGE_COUNT {
		e := table[formats.STAGE_FIRST + 3 * id]
		s: formats.Stage
		has := false
		if !formats.entry_missing(e) {
			stored := make([]byte, e.stored_size, context.temp_allocator)
			os.read_at(f, stored, formats.entry_offset(e))
			data, unpacked := formats.unpack_entry(e, stored, context.temp_allocator)
			testing.expectf(t, unpacked, "stage %d entry did not unpack", id)
			s, has = formats.read_stage(data, context.temp_allocator)
			testing.expectf(t, has, "stage %d did not read", id)
		}
		dump_stage(&b, id, s, has)
		free_all(context.temp_allocator)
	}

	got_lines := strings.split_lines(strings.to_string(b), context.temp_allocator)
	want_lines := strings.split_lines(string(want), context.temp_allocator)
	testing.expect_value(t, len(got_lines), len(want_lines))
	for i in 0 ..< min(len(got_lines), len(want_lines)) {
		if got_lines[i] != want_lines[i] {
			testing.expectf(t, false, "line %d differs:\n got  %s\n want %s", i, got_lines[i], want_lines[i])
			break
		}
	}
}
