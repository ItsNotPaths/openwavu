-- Tekken 5 DR movesets (motbin, tk5decomp data.md §4, code-map.md). Applied after ../schema.sql.
-- (hole tekken-schema :tags importer) this schema is TK5's own; it is not yet the shared Tekken shape (record layouts of the sim, the sim's tables BODY/ANCH/GAZE/HITP/HITS/TRKR/TOVR/TFIX, game-only tables optional) that every Tekken sim reads.
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
	flags         INTEGER,  -- +0x3c in the loader's bit order (0xc8508): bits 0..3 kept, file bit i (4..31) at 35 - i
	hit_category  INTEGER,  -- +0x40, 4 bytes
	active_first  INTEGER,
	active_last   INTEGER,
	unk_1a INTEGER, unk_1c INTEGER, unk_24 INTEGER, unk_26 INTEGER, unk_28 INTEGER, unk_48 INTEGER,
	tracking_row        INTEGER NOT NULL,  -- default tracking: tracking_row of the character
	tracking_far_row    INTEGER NOT NULL,  -- used instead when the angle of far_source is above far_angle
	tracking_far_source INTEGER NOT NULL,  -- 0 never, 1 opponent angle, 2 angle 0x84
	tracking_far_angle  INTEGER NOT NULL,
	rides_partner INTEGER NOT NULL,  -- the thrower rides on the partner (Xiaoyu's Hien throws)
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
	option       INTEGER,           -- as the loader computes it (0xc8508); the file value is ignored
	tracking_pick INTEGER NOT NULL,  -- 1 + tracking_override idx, 0: the move's default
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
	option       INTEGER,           -- as the loader computes it (0xc8508); the file value is ignored
	tracking_pick INTEGER NOT NULL,  -- 1 + tracking_override idx, 0: the move's default
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
	param     INTEGER NOT NULL,  -- 0xf1, 0xf2: a phase test (stock.odin requirement_param), not the game's flow state
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
	unk_04    INTEGER,           -- 0x8071: high half is a tracking_row, not the game's mode
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

-- Stock rules the game keeps in code, as rows the sim reads (tk5decomp docs/rewrite.md, Db edits). Units: mm, radians.

CREATE TABLE body (
	character       TEXT PRIMARY KEY,
	throw_range_cut REAL NOT NULL,     -- both fighters' throw range is shorter by this for this fighter
	probe_x         REAL NOT NULL,     -- head floor probe: point and radius, fractions of the head end bone length
	probe_z         REAL NOT NULL,
	probe_radius    REAL NOT NULL,
	head_top        REAL NOT NULL,     -- head end height in the standing idle (not stock: measured at import)
	hitscan         INTEGER NOT NULL,  -- row of the sim's hitscan list, 0: none
	projectile      INTEGER NOT NULL   -- row of the sim's projectile list, 0: none
);

-- The sim's two skeletons by body slot (skel.c): A 0..21 body bones, 22..26 end points, then helpers;
-- B 0..26 with its own translations, turns from A. Parent -1: the root.
CREATE TABLE skeleton (
	character TEXT PRIMARY KEY,
	scale     REAL NOT NULL  -- bon scale
);

CREATE TABLE skeleton_a (
	character TEXT NOT NULL,
	slot      INTEGER NOT NULL,
	parent    INTEGER NOT NULL,
	x REAL NOT NULL, y REAL NOT NULL, z REAL NOT NULL,
	rx REAL NOT NULL, ry REAL NOT NULL, rz REAL NOT NULL,  -- bind turn, m = Rx Ry Rz
	PRIMARY KEY (character, slot)
);

CREATE TABLE skeleton_b (
	character TEXT NOT NULL,
	slot      INTEGER NOT NULL,
	parent    INTEGER NOT NULL,
	x REAL NOT NULL, y REAL NOT NULL, z REAL NOT NULL,
	PRIMARY KEY (character, slot)
);

-- A start record the stage never takes for a next round: it takes `instead`. No row: none.
CREATE TABLE stage_start_skip (
	stage   TEXT PRIMARY KEY,
	record  INTEGER NOT NULL,
	instead INTEGER NOT NULL
);

-- Hurtboxes: vertical cylinders on bones of skeleton B, in the order of the hit record index.
CREATE TABLE body_hurt (
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	radius    INTEGER NOT NULL,  -- and half height
	bone      INTEGER NOT NULL,
	lift      REAL NOT NULL,
	PRIMARY KEY (character, idx)
);

-- Push spheres on bones of skeleton B; radius at rest.
CREATE TABLE body_push (
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	radius    REAL NOT NULL,
	bone      INTEGER NOT NULL,
	PRIMARY KEY (character, idx)
);

-- Points fixed to a bone of skeleton B (special slots 6, 7).
CREATE TABLE body_point (
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	bone      INTEGER NOT NULL,
	x REAL NOT NULL, y REAL NOT NULL, z REAL NOT NULL,
	PRIMARY KEY (character, idx)
);

-- Facing rows: how a move turns the fighter (law, target, gate, rate, limit, end). Row 0 is hold. Degrees, frames, mm.
CREATE TABLE tracking_row (
	character  TEXT NOT NULL,
	idx        INTEGER NOT NULL,
	law        INTEGER NOT NULL,  -- hold, home, settle, sweep, ease out, ease in, leave
	start      INTEGER NOT NULL,  -- phase: running, free, reaim, scripted
	target     INTEGER NOT NULL,  -- none, opponent, behind, reference, side, stage centre, start spot
	stock_mode INTEGER NOT NULL,  -- the game's mode byte (oracle and harness only)
	gate_kind  INTEGER NOT NULL,  -- none, skip, spread, spread early (while the opponent is busy)
	gate_until INTEGER NOT NULL,
	gate_min_distance INTEGER NOT NULL,
	rate_normal INTEGER NOT NULL, rate_late INTEGER NOT NULL, rate_air INTEGER NOT NULL,
	rate_late_from INTEGER NOT NULL,
	rate_frames INTEGER NOT NULL,
	rate_halving INTEGER NOT NULL,  -- none, all, late
	rate_by_distance INTEGER NOT NULL,
	limit_total INTEGER NOT NULL,
	sweep_front INTEGER NOT NULL, sweep_left INTEGER NOT NULL, sweep_back INTEGER NOT NULL, sweep_right INTEGER NOT NULL,
	end_yaw_when INTEGER NOT NULL,  -- never, always, unless the anim changed
	end_pivot_when INTEGER NOT NULL,
	end_grace INTEGER NOT NULL,
	end_phase INTEGER NOT NULL,
	PRIMARY KEY (character, idx)
);

-- Tracking a cancel entry names (cancel.tracking_pick - 1).
CREATE TABLE tracking_override (
	character  TEXT NOT NULL,
	idx        INTEGER NOT NULL,
	row        INTEGER NOT NULL,
	far_row    INTEGER NOT NULL,
	far_source INTEGER NOT NULL,
	far_angle  INTEGER NOT NULL,
	PRIMARY KEY (character, idx)
);

-- Fixed tracking: 0 a carried cancel the sim rewrites to motion code 2, 1 a guarding reaction.
CREATE TABLE tracking_fixed (
	character  TEXT NOT NULL,
	idx        INTEGER NOT NULL,
	row        INTEGER NOT NULL,
	far_row    INTEGER NOT NULL,
	far_source INTEGER NOT NULL,
	far_angle  INTEGER NOT NULL,
	PRIMARY KEY (character, idx)
);

-- Side bands (motbin header 0x140): the sector widths of an angle, by band.
CREATE TABLE side_band (
	character TEXT NOT NULL,
	idx       INTEGER NOT NULL,
	offset    INTEGER NOT NULL,  -- added to the angle
	width_0   INTEGER NOT NULL,  -- sectors 0..2; sector 3 is the rest
	width_1   INTEGER NOT NULL,
	width_2   INTEGER NOT NULL,
	PRIMARY KEY (character, idx)
);

CREATE TABLE gaze (
	character TEXT PRIMARY KEY,
	tilt      REAL NOT NULL,     -- radians, about the level axis across the line to the opponent's head
	head_turn INTEGER NOT NULL   -- angle steps (65536 a turn) about the head's y axis
);

-- The two hitbox slots of a move: end and start point, each a kind (none, bone, special, effect, keep, fixed,
-- hitscan, projectile) and an index.
CREATE TABLE hit_pair (
	character   TEXT NOT NULL,
	move        INTEGER NOT NULL,
	slot        INTEGER NOT NULL,
	end_kind    INTEGER NOT NULL,
	end_index   INTEGER NOT NULL,
	start_kind  INTEGER NOT NULL,
	start_index INTEGER NOT NULL,
	PRIMARY KEY (character, move, slot)
);

CREATE TABLE move_hits (
	character    TEXT NOT NULL,
	move         INTEGER NOT NULL,
	attack_bones INTEGER NOT NULL,  -- bit b: the move attacks with bone b of skeleton B
	slots        INTEGER NOT NULL,  -- hitbox slots that get points while active: 0..2
	launches     INTEGER NOT NULL,  -- a hitbox runs from the projectile's point
	PRIMARY KEY (character, move)
);
