-- Tables of every game. Lengths in metres, Y up. Keys are stable strings or game indices, never rowids (overlays match on them).

CREATE TABLE source (
	key   TEXT PRIMARY KEY,  -- title_id, eboot_sha256, data_sha256, schema_version, importer_version
	value TEXT NOT NULL
);

-- Names for the raw codes of a game (requirement ids, hit levels, ...).
CREATE TABLE code_name (
	kind TEXT NOT NULL,
	code INTEGER NOT NULL,
	name TEXT NOT NULL,
	PRIMARY KEY (kind, code)
);

CREATE TABLE removed (  -- only used in overlays
	tbl TEXT NOT NULL,
	key TEXT NOT NULL,  -- primary key values, joined with '/'
	PRIMARY KEY (tbl, key)
);

CREATE TABLE character (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	game_index INTEGER
);

CREATE TABLE bone (
	skeleton      TEXT NOT NULL,
	idx           INTEGER NOT NULL,
	parent        INTEGER,
	name          TEXT,
	standard_name TEXT,  -- hips, spine, ...; NULL for helpers
	PRIMARY KEY (skeleton, idx)
);

CREATE TABLE part (
	id        TEXT PRIMARY KEY,
	character TEXT REFERENCES character(id),  -- NULL: shared item
	slot      TEXT NOT NULL,                  -- body, head, hat, ...
	skeleton  TEXT NOT NULL,
	file      TEXT NOT NULL
);

CREATE TABLE costume (
	character TEXT NOT NULL REFERENCES character(id),
	id        TEXT NOT NULL,
	PRIMARY KEY (character, id)
);

CREATE TABLE costume_part (
	character TEXT NOT NULL,
	costume   TEXT NOT NULL,
	part      TEXT NOT NULL REFERENCES part(id),
	PRIMARY KEY (character, costume, part),
	FOREIGN KEY (character, costume) REFERENCES costume(character, id)
);

CREATE TABLE anim (  -- rows with the same file are one anim: the game compares them by record
	character TEXT NOT NULL,  -- bank owner: a character, <char>/embedded, or common
	idx       INTEGER NOT NULL,
	frames    INTEGER NOT NULL,
	file      TEXT NOT NULL,
	PRIMARY KEY (character, idx)
);

CREATE TABLE stage (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	game_index INTEGER,
	file       TEXT NOT NULL
);

-- Stage collision in file units (tk5: mm).
-- MHO quads: walls and flat floor quads.
CREATE TABLE stage_quad (
	stage   TEXT NOT NULL REFERENCES stage(id),
	idx     INTEGER NOT NULL,
	object  INTEGER NOT NULL,  -- MHO object index
	x0 REAL, y0 REAL, z0 REAL,
	x1 REAL, y1 REAL, z1 REAL,
	x2 REAL, y2 REAL, z2 REAL,
	x3 REAL, y3 REAL, z3 REAL,
	nx REAL, ny REAL, nz REAL,  -- a wall normal points into the arena
	link    INTEGER,            -- stage object id (breakable prop), NULL: none
	is_wall INTEGER NOT NULL,   -- the wall test keeps it
	PRIMARY KEY (stage, idx)
);

-- Floor zones: a bounding circle, then polygons tested in XZ.
CREATE TABLE stage_floor (
	stage     TEXT NOT NULL REFERENCES stage(id),
	idx       INTEGER NOT NULL,
	cx REAL, cy REAL, cz REAL,
	radius_sq REAL,
	flags     INTEGER NOT NULL,  -- tk5: bit 0 floor, 0x4..0x800 ground kind
	PRIMARY KEY (stage, idx)
);

CREATE TABLE stage_floor_polygon (
	stage     TEXT NOT NULL,
	floor     INTEGER NOT NULL,
	idx       INTEGER NOT NULL,
	cx REAL, cy REAL, cz REAL,
	radius_sq REAL,
	nx REAL, ny REAL, nz REAL,
	PRIMARY KEY (stage, floor, idx)
);

CREATE TABLE stage_floor_point (
	stage   TEXT NOT NULL,
	floor   INTEGER NOT NULL,
	polygon INTEGER NOT NULL,
	pos     INTEGER NOT NULL,
	x REAL, y REAL, z REAL,
	PRIMARY KEY (stage, floor, polygon, pos)
);

-- The wall broadphase: nx * nz square cells, centred on 0.
CREATE TABLE stage_grid (
	stage TEXT PRIMARY KEY REFERENCES stage(id),
	nx    INTEGER NOT NULL,
	nz    INTEGER NOT NULL,
	cell  REAL NOT NULL
);

-- MHO objects by index: their quads are the stage_quad rows with this object.
CREATE TABLE stage_object (
	stage TEXT NOT NULL REFERENCES stage(id),
	idx   INTEGER NOT NULL,
	kind  INTEGER NOT NULL,  -- tk5: 3 and 9 hold quads, 5 the grid, 6 a floor cell
	link  INTEGER,           -- stage object id (breakable prop), NULL: none
	PRIMARY KEY (stage, idx)
);

-- The objects of each grid cell (z * nx + x), in the order the game tests them.
CREATE TABLE stage_cell (
	stage  TEXT NOT NULL REFERENCES stage(id),
	cell   INTEGER NOT NULL,
	pos    INTEGER NOT NULL,
	object INTEGER NOT NULL,
	PRIMARY KEY (stage, cell, pos)
);

-- Start points: two slots, each a list of groups of records with one or two points.
CREATE TABLE stage_start_slot (
	stage      TEXT NOT NULL REFERENCES stage(id),
	slot       INTEGER NOT NULL,
	pos_format INTEGER NOT NULL,  -- tk5: a POS section (groups by pair index), else TKPD (by entry id)
	PRIMARY KEY (stage, slot)
);

CREATE TABLE stage_start_group (
	stage      TEXT NOT NULL REFERENCES stage(id),
	slot       INTEGER NOT NULL,
	idx        INTEGER NOT NULL,
	id         INTEGER NOT NULL,
	count      INTEGER NOT NULL,  -- records
	per_record INTEGER NOT NULL,
	PRIMARY KEY (stage, slot, idx)
);

CREATE TABLE stage_start_point (
	stage TEXT NOT NULL REFERENCES stage(id),
	slot  INTEGER NOT NULL,
	grp   INTEGER NOT NULL,
	idx   INTEGER NOT NULL,  -- record * per_record + point
	x REAL NOT NULL, y REAL NOT NULL, z REAL NOT NULL, w REAL NOT NULL,
	rx REAL NOT NULL, ry REAL NOT NULL, rz REAL NOT NULL, rw REAL NOT NULL,
	PRIMARY KEY (stage, slot, grp, idx)
);

-- Not extracted yet.

CREATE TABLE sound (
	id   TEXT PRIMARY KEY,
	bank TEXT,
	file TEXT NOT NULL
);

-- (hole music-extract :tags (importer audio) :sev polish) where TK5 keeps its music is not known.
CREATE TABLE music (
	id   TEXT PRIMARY KEY,
	file TEXT NOT NULL
);

CREATE TABLE image (  -- UI, portraits
	id   TEXT PRIMARY KEY,
	file TEXT NOT NULL
);

-- (hole intro-timelines :tags importer :needs intro-re) no intro, win and outro timelines: fighter anim, camera track, frame events (effect, sound, voice).
-- (hole text-strings :tags importer :sev polish) no source found yet for localized UI strings.
CREATE TABLE text (
	id    TEXT NOT NULL,
	lang  TEXT NOT NULL,
	value TEXT NOT NULL,
	PRIMARY KEY (id, lang)
);
