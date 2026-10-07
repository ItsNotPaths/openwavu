-- Tekken 5 DR movesets (motbin, tk5decomp data.md §4, code-map.md). Applied after ../schema.sql.
-- A game list (cancels, requirements, ...) is (character, list, pos). A list starts at every index
-- that something points to; the list id is that index. Joining the lists in id order gives the
-- game table back. Lists stay shared like in the game. End-marker rows stay as rows.
-- unk_XX: unknown field at record offset XX, raw.

CREATE TABLE motbin (
	character TEXT PRIMARY KEY REFERENCES character(id),
	char_id   INTEGER NOT NULL,
	name      BLOB NOT NULL,  -- SJIS, raw
	creator   BLOB,           -- SJIS, raw
	date      TEXT,
	full_date TEXT,
	unk_140   BLOB            -- header 0x140..0x188
);

CREATE TABLE move_alias (  -- move id 0x8000+n -> move
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	move      INTEGER NOT NULL,
	PRIMARY KEY (character, idx)
);

CREATE TABLE move (
	character     TEXT NOT NULL,
	idx           INTEGER NOT NULL,
	name          TEXT NOT NULL,
	anim_name     TEXT,
	anim_owner    TEXT NOT NULL,  -- anim(character): container owner, <char>/embedded or common
	anim_idx      INTEGER NOT NULL,
	anim          INTEGER NOT NULL,  -- the raw anim id
	vuln          INTEGER,
	hit_level     INTEGER,
	cancels       INTEGER NOT NULL,  -- cancel list
	transition    INTEGER,
	hit_conditions INTEGER,          -- hit_condition list
	voiceclips    INTEGER,           -- NULL: none
	extra_props   INTEGER,
	start_props   INTEGER,
	end_props     INTEGER,
	flags         INTEGER,  -- +0x3c as stored, before the loader permutes the bits
	hit_category  INTEGER,  -- +0x40, 4 bytes
	active_first  INTEGER,
	active_last   INTEGER,
	unk_1a INTEGER, unk_1c INTEGER, unk_24 INTEGER, unk_26 INTEGER, unk_28 INTEGER, unk_48 INTEGER,
	PRIMARY KEY (character, idx)
);

-- command 0x8000xxxx ends a list; 0x8005xxxx jumps to group_cancel list `move`, 0x8006 returns.
CREATE TABLE cancel (
	character    TEXT NOT NULL,
	list         INTEGER NOT NULL,
	pos          INTEGER NOT NULL,
	command      INTEGER NOT NULL,
	requirements INTEGER NOT NULL,  -- requirement list
	move         INTEGER NOT NULL,
	unk_0a       INTEGER,
	extra        INTEGER,           -- cancel_extra idx
	window_start INTEGER,
	window_end   INTEGER,
	start_frame  INTEGER,
	option       INTEGER,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE group_cancel (
	character    TEXT NOT NULL,
	list         INTEGER NOT NULL,
	pos          INTEGER NOT NULL,
	command      INTEGER NOT NULL,
	requirements INTEGER NOT NULL,
	move         INTEGER NOT NULL,
	unk_0a       INTEGER,
	extra        INTEGER,
	window_start INTEGER,
	window_end   INTEGER,
	start_frame  INTEGER,
	option       INTEGER,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE cancel_extra (
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	value     INTEGER NOT NULL,
	PRIMARY KEY (character, idx)
);

-- id 0x147 ends a list.
CREATE TABLE requirement (
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	id        INTEGER NOT NULL,  -- code_name kind 'tk5.requirement'
	param     INTEGER NOT NULL,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE hit_condition (
	character    TEXT NOT NULL,
	list         INTEGER NOT NULL,
	pos          INTEGER NOT NULL,
	requirements INTEGER NOT NULL,
	damage       INTEGER,
	unk_06       INTEGER,
	reaction     INTEGER NOT NULL,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE reaction (
	character  TEXT NOT NULL,
	idx        INTEGER NOT NULL,
	pushback_0 INTEGER, pushback_1 INTEGER, pushback_2 INTEGER, pushback_3 INTEGER,
	pushback_4 INTEGER, pushback_5 INTEGER, pushback_6 INTEGER,
	unk_1c INTEGER, unk_1e INTEGER, unk_20 INTEGER, unk_22 INTEGER, unk_24 INTEGER,
	unk_26 INTEGER, unk_28 INTEGER, unk_2a INTEGER, unk_2c INTEGER, unk_2e INTEGER,
	vertical_pushback INTEGER,
	unk_32 INTEGER,
	move_standing INTEGER, move_crouch INTEGER, move_counter INTEGER, move_crouch_counter INTEGER,
	move_left INTEGER, move_left_crouch INTEGER, move_right INTEGER, move_right_crouch INTEGER,
	move_back INTEGER, move_back_crouch INTEGER, move_block INTEGER, move_crouch_block INTEGER,
	move_wall_slump INTEGER, move_down INTEGER,
	PRIMARY KEY (character, idx)
);

CREATE TABLE pushback (
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	unk_00 INTEGER, unk_02 INTEGER, unk_04 INTEGER, unk_06 INTEGER,
	extras    INTEGER,  -- pushback_extra list
	PRIMARY KEY (character, idx)
);

CREATE TABLE pushback_extra (
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	value     INTEGER NOT NULL,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE extra_prop (
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	unk_00    INTEGER,
	unk_02    INTEGER,
	unk_04    INTEGER,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE start_prop (
	character    TEXT NOT NULL,
	list         INTEGER NOT NULL,
	pos          INTEGER NOT NULL,
	requirements INTEGER NOT NULL,
	unk_04       INTEGER,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE end_prop (
	character    TEXT NOT NULL,
	list         INTEGER NOT NULL,
	pos          INTEGER NOT NULL,
	requirements INTEGER NOT NULL,
	unk_04       INTEGER,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE voiceclip (
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	value     INTEGER NOT NULL,
	PRIMARY KEY (character, list, pos)
);

-- Command 0x8007+n reads input_sequence n.
CREATE TABLE input_sequence (
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	unk_00    INTEGER,
	unk_02    INTEGER,
	inputs    INTEGER NOT NULL,  -- input_extra list
	PRIMARY KEY (character, idx)
);

CREATE TABLE input_extra (
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	unk_00    INTEGER,
	unk_02    INTEGER,
	PRIMARY KEY (character, list, pos)
);

-- Table 0x200: u16 move id pools, 0 ends a pool; nothing in the file points to them (code-map.md 0x335f4).
CREATE TABLE move_pool (
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	move      INTEGER NOT NULL,
	PRIMARY KEY (character, list, pos)
);

-- Pause menu command list. Strings are UTF-16 BE in the file, button glyphs in U+E0xx.
CREATE TABLE command_list (
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	name_ja   TEXT,
	name_en   TEXT,
	name_ja2  TEXT,
	command_0 TEXT, command_1 TEXT, command_2 TEXT, command_3 TEXT,
	command_4 TEXT, command_5 TEXT, command_6 TEXT, command_7 TEXT,
	unk_2c INTEGER, unk_30 INTEGER, unk_34 INTEGER, unk_38 INTEGER,
	PRIMARY KEY (character, idx)
);

-- Tables not decoded yet (header 0x208, 0x210, 0x220, 0x228, 0x230, 0x238), raw.
-- 0x238: 8-byte records, +4 an extra_prop index (a list start).
CREATE TABLE unknown_table (
	character TEXT NOT NULL,
	header    INTEGER NOT NULL,  -- header offset of the table
	count     INTEGER NOT NULL,
	data      BLOB NOT NULL,
	PRIMARY KEY (character, header)
);
