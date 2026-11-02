-- Tables of every game. Lengths in metres, Y up. Keys are stable strings or game indices, never rowids (patches match on them).
-- A row a mod adds has a text key `<pack id>/<name>` where the game uses a number (docs/formats.md).

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

-- file: the visual glb; collision: floors, walls and start nodes (glb, file units under a metre scale); surfaces: JSON.
CREATE TABLE stage (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	game_index INTEGER,
	file       TEXT NOT NULL,
	collision  TEXT NOT NULL,
	surfaces   TEXT NOT NULL
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
