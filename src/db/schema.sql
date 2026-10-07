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

CREATE TABLE anim (
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

-- (hole text-strings :tags importer :sev polish) no source found yet for localized UI strings.
CREATE TABLE text (
	id    TEXT NOT NULL,
	lang  TEXT NOT NULL,
	value TEXT NOT NULL,
	PRIMARY KEY (id, lang)
);
