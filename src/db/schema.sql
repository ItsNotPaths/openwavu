-- Tables of every game. Lengths in metres, Y up. Keys are stable strings (patches match on them), never rowids.
-- A row a mod adds has a key `<pack id>/<name>` (docs/formats.md). anim ids are a bank's game numbers; a mod's are text.

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

CREATE TABLE character (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	game_index INTEGER,
	model      INTEGER  -- the game's body model id, which move requirements compare
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

-- file: the visual glb; collision: floors, walls and start nodes (glb, file units under a metre scale); surfaces: JSON.
CREATE TABLE stage (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	-- (hole stage-game-index :tags (importer tools) :sev polish) game_index is read only by tk5decomp's harness (the game's stage numbers in recordings); matches name a stage by id.
	game_index INTEGER,
	file       TEXT NOT NULL,
	collision  TEXT NOT NULL,
	surfaces   TEXT NOT NULL,
	music      TEXT REFERENCES music(id)  -- NULL: none
);

-- FLAC files. A bank is one of the game's sound packs; idx: the game's record number. Loops in samples, NULL: none.
CREATE TABLE sound (
	bank        TEXT NOT NULL,  -- common, menu, round_calls, names, a stage, <costume part>/voices or /stream_voices
	idx         INTEGER NOT NULL,
	file        TEXT NOT NULL,
	volume      REAL NOT NULL,     -- dB
	pitch       INTEGER NOT NULL,  -- cents
	pan         REAL NOT NULL,     -- degrees
	loop_start  INTEGER,
	loop_length INTEGER,
	PRIMARY KEY (bank, idx)
);

CREATE TABLE music (  -- id: the game's track number
	id          TEXT PRIMARY KEY,
	file        TEXT NOT NULL,
	loop_start  INTEGER,
	loop_length INTEGER
);

CREATE TABLE image (  -- UI, portraits
	id   TEXT PRIMARY KEY,
	file TEXT NOT NULL
);

CREATE TABLE font (
	id          TEXT PRIMARY KEY,
	line_height INTEGER NOT NULL  -- px
);

CREATE TABLE glyph (  -- one character on a font page; px
	font     TEXT NOT NULL REFERENCES font(id),
	code     INTEGER NOT NULL,  -- Unicode
	image    TEXT NOT NULL REFERENCES image(id),  -- the page
	x        INTEGER NOT NULL,
	y        INTEGER NOT NULL,
	width    INTEGER NOT NULL,
	height   INTEGER NOT NULL,
	x_offset REAL NOT NULL,  -- pen to the glyph's left edge
	y_offset REAL NOT NULL,  -- line top to the glyph's top
	advance  REAL NOT NULL,  -- pen step
	PRIMARY KEY (font, code)
);

CREATE TABLE texture (  -- DDS files, which glb materials point at; hashes are unique per owner only
	owner  TEXT NOT NULL,  -- the part's owner or the stage
	hash   INTEGER NOT NULL,
	file   TEXT NOT NULL,
	PRIMARY KEY (owner, hash)
);

-- (hole intro-timelines :tags (importer round-show)) the intro and win poses have their camera (move_camera) but no frame events: effects, sounds, voices.
-- (hole text-strings :tags importer :sev polish) no source found yet for localized UI strings.
CREATE TABLE text (
	id    TEXT NOT NULL,
	lang  TEXT NOT NULL,
	value TEXT NOT NULL,
	PRIMARY KEY (id, lang)
);
