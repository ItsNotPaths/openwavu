// Stage rows: MHO quads, objects and grid, UNDN floor zones, start points. File units (mm).
package tk5_convert

import "../../db"
import formats "../../formats/tk5"

// (hole efp-import :tags importer :needs fx-spec) TK5 effect data (EFP, character slot +2, stage effects) is not converted to effect defs.
Start_Skip :: struct {stage, record, instead: int}
// The start record a stage never takes for a next round (tk5decomp harness/stock_round.c, 0x1a5c8).
@(rodata)
START_SKIPS := [?]Start_Skip{{5, 3, 0}, {3, 2, 1}}

// index: the game's stage id.
write_stage_rows :: proc(w: ^db.Writer, id: string, index: int, s: formats.Stage) {
	for k in START_SKIPS do if k.stage == index do db.insert(w, "stage_start_skip", id, i64(k.record), i64(k.instead))
	for q, i in s.quads {
		c := q.corners
		db.insert(w, "stage_quad", id, i64(i), i64(q.object),
			f(c[0].x), f(c[0].y), f(c[0].z), f(c[1].x), f(c[1].y), f(c[1].z),
			f(c[2].x), f(c[2].y), f(c[2].z), f(c[3].x), f(c[3].y), f(c[3].z),
			f(q.normal.x), f(q.normal.y), f(q.normal.z), link(q.link), i64(q.is_wall))
	}
	// (hole stage-grid-rows :tags importer :needs wall-grid-drop :sev polish) stage_grid and stage_cell are only the wall broadphase; drop them and their tables once the sim tests every wall.
	db.insert(w, "stage_grid", id, i64(s.grid.nx), i64(s.grid.nz), f(s.grid.cell))
	for o, i in s.objects do db.insert(w, "stage_object", id, i64(i), i64(o.kind), link(o.link))
	for c, i in s.cells do for o, k in c do db.insert(w, "stage_cell", id, i64(i), i64(k), i64(o))
	for slot, k in s.start {
		db.insert(w, "stage_start_slot", id, i64(k), i64(slot.pos_format))
		for g, i in slot.groups {
			db.insert(w, "stage_start_group", id, i64(k), i64(i), i64(g.id), i64(g.count), i64(g.per_record))
			for p, j in g.points {
				db.insert(w, "stage_start_point", id, i64(k), i64(i), i64(j), f(p[0]), f(p[1]), f(p[2]), f(p[3]), f(p[4]), f(p[5]), f(p[6]), f(p[7]))
			}
		}
	}
	for z, i in s.floors {
		// (hole ground-kinds :tags importer :sev polish) floor flag bits 0x4..0x800 (ground kind) have no code_name rows.
		db.insert(w, "stage_floor", id, i64(i), f(z.centre.x), f(z.centre.y), f(z.centre.z), f(z.radius_sq), i64(z.flags))
		for p, j in z.polygons {
			db.insert(w, "stage_floor_polygon", id, i64(i), i64(j), f(p.centre.x), f(p.centre.y), f(p.centre.z),
				f(p.radius_sq), f(p.normal.x), f(p.normal.y), f(p.normal.z))
			for pt, k in p.points {
				db.insert(w, "stage_floor_point", id, i64(i), i64(j), i64(k), f(pt.x), f(pt.y), f(pt.z))
			}
		}
	}
}

@(private = "file")
f :: proc(v: f32) -> db.Value {return f64(v)}

// -1: none.
@(private = "file")
link :: proc(v: i32) -> db.Value {return v < 0 ? db.Null{} : i64(v)}
