// Stage rows: MHO quads and UNDN floor zones, in metres.
package tk5_convert

import "../../db"
import formats "../../formats/tk5"

MM :: 1000.0

// (hole stage-collision-rows :tags importer) no wall broadphase grid (cells in the game's list order), object kinds/links or start points (sections 14/13) (tk5decomp export_collision.py, stage_start.py).
write_stage_rows :: proc(w: ^db.Writer, id: string, s: formats.Stage) {
	for q, i in s.quads {
		c := q.corners
		db.insert(w, "stage_quad", id, i64(i), i64(q.object),
			m(c[0].x), m(c[0].y), m(c[0].z), m(c[1].x), m(c[1].y), m(c[1].z),
			m(c[2].x), m(c[2].y), m(c[2].z), m(c[3].x), m(c[3].y), m(c[3].z),
			f64(q.normal.x), f64(q.normal.y), f64(q.normal.z),
			q.link < 0 ? db.Null{} : i64(q.link), i64(q.is_wall))
	}
	for f, i in s.floors {
		// (hole ground-kinds :tags importer :sev polish) floor flag bits 0x4..0x800 (ground kind) have no code_name rows.
		db.insert(w, "stage_floor", id, i64(i), m(f.centre.x), m(f.centre.y), m(f.centre.z),
			f64(f.radius_sq) / (MM * MM), i64(f.flags))
		for p, j in f.polygons {
			db.insert(w, "stage_floor_polygon", id, i64(i), i64(j), m(p.centre.x), m(p.centre.y), m(p.centre.z),
				f64(p.radius_sq) / (MM * MM), f64(p.normal.x), f64(p.normal.y), f64(p.normal.z))
			for pt, k in p.points {
				db.insert(w, "stage_floor_point", id, i64(i), i64(j), i64(k), m(pt.x), m(pt.y), m(pt.z))
			}
		}
	}
}

// File millimetres -> metres. f32(m(v) * MM) gives v back exactly.
m :: proc(v: f32) -> db.Value {return f64(v) / MM}
