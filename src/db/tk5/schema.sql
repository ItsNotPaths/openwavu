-- Tekken 5 DR movesets (motbin, tk5decomp data.md §4, code-map.md). Applied after ../schema.sql.
-- (hole tekken-schema :tags importer) the tables the sim loads are the TK5 sim's record layouts (modules/tk5/load.c); they are not yet one Tekken shape that every Tekken sim reads under its own names, with game-only tables optional.
-- The tables the sim loads name their columns after the sim's fields (arrays: name_0, name_1, ...). "(not loaded)": the sim does not
-- read the column. A row points to a list by its id; -1 is none.
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
	character      TEXT NOT NULL,
	idx            INTEGER NOT NULL,
	name           TEXT NOT NULL,
	anim_name      TEXT,
	anim_owner     TEXT NOT NULL,     -- anim(character): container owner, <char>/embedded or common
	anim_idx       INTEGER NOT NULL,
	anim           INTEGER NOT NULL,  -- the raw anim id (not loaded)
	vuln           INTEGER NOT NULL,
	hit_level      INTEGER NOT NULL,
	cancels        INTEGER NOT NULL,  -- cancel list
	next_move      INTEGER NOT NULL,  -- the move it goes to when it ends
	end_yaw        INTEGER NOT NULL,
	compare_id     INTEGER NOT NULL,
	push_speed     INTEGER NOT NULL,
	hit_conditions INTEGER NOT NULL,  -- hit_condition list
	window_start   INTEGER NOT NULL,
	window_end     INTEGER NOT NULL,
	hold_frame     INTEGER NOT NULL,
	voiceclips     INTEGER NOT NULL,  -- voiceclip list, -1: none (not loaded)
	extra_props    INTEGER NOT NULL,  -- extra_prop list, -1: none
	start_props    INTEGER NOT NULL,  -- start_prop list, -1: none
	end_prop       INTEGER NOT NULL,  -- end_prop list, -1: none
	flags          INTEGER NOT NULL,  -- +0x3c in the loader's bit order (0xc8508): bits 0..3 kept, file bit i (4..31) at 35 - i
	hit_category   INTEGER NOT NULL,  -- +0x40, the game's 4 hitbox bytes (not loaded: hit_pair_* and hits_* hold what they mean)
	first_active   INTEGER NOT NULL,
	last_active    INTEGER NOT NULL,
	push_shape     INTEGER NOT NULL,
	unk_4a         INTEGER NOT NULL,
	tracking_row        INTEGER NOT NULL,  -- default tracking: tracking_row of the character
	tracking_far_row    INTEGER NOT NULL,  -- used instead when the angle of far_source is above far_angle
	tracking_far_source INTEGER NOT NULL,  -- 0 never, 1 opponent angle, 2 angle 0x84
	tracking_far_angle  INTEGER NOT NULL,
	rides_partner  INTEGER NOT NULL,  -- the thrower rides on the partner (Xiaoyu's Hien throws)
	-- The hitbox of slot n ends at the end point and starts at the start point: a kind (none, bone, special, effect, keep,
	-- fixed, hitscan, projectile) and an index.
	hit_pair_end_kind_0 INTEGER NOT NULL, hit_pair_end_index_0 INTEGER NOT NULL,
	hit_pair_start_kind_0 INTEGER NOT NULL, hit_pair_start_index_0 INTEGER NOT NULL,
	hit_pair_end_kind_1 INTEGER NOT NULL, hit_pair_end_index_1 INTEGER NOT NULL,
	hit_pair_start_kind_1 INTEGER NOT NULL, hit_pair_start_index_1 INTEGER NOT NULL,
	hits_attack_bones INTEGER NOT NULL,  -- bit b: the move attacks with bone b of skeleton B
	hits_slots     INTEGER NOT NULL,     -- hitbox slots that get points while active: 0..2
	hits_launches  INTEGER NOT NULL,     -- a hitbox runs from the projectile's point
	PRIMARY KEY (character, idx)
);

-- command_code 0x8000 ends a list; 0x8005 enters group_list, 0x8006 returns; 0x8007 + n reads input_sequence n.
CREATE TABLE cancel (
	character       TEXT NOT NULL,
	list            INTEGER NOT NULL,
	pos             INTEGER NOT NULL,
	command_code    INTEGER NOT NULL,
	command_buttons INTEGER NOT NULL,
	requirements    INTEGER NOT NULL,  -- requirement list
	move            INTEGER,           -- NULL on a group entry
	group_list      INTEGER,           -- a group entry: the group_cancel list it enters, else NULL
	unk_0a          INTEGER,           -- (not loaded)
	extradata       INTEGER NOT NULL,
	window_start    INTEGER NOT NULL,
	window_end      INTEGER NOT NULL,
	start_frame     INTEGER NOT NULL,
	option          INTEGER NOT NULL,  -- as the loader computes it (0xc8508); the file value is ignored
	tracking_pick   INTEGER NOT NULL,  -- 1 + tracking_override idx, 0: the move's default
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE group_cancel (
	character       TEXT NOT NULL,
	list            INTEGER NOT NULL,
	pos             INTEGER NOT NULL,
	command_code    INTEGER NOT NULL,
	command_buttons INTEGER NOT NULL,
	requirements    INTEGER NOT NULL,  -- requirement list
	move            INTEGER,           -- NULL on a group entry
	group_list      INTEGER,           -- a group entry: the group_cancel list it enters, else NULL
	unk_0a          INTEGER,           -- (not loaded)
	extradata       INTEGER NOT NULL,
	window_start    INTEGER NOT NULL,
	window_end      INTEGER NOT NULL,
	start_frame     INTEGER NOT NULL,
	option          INTEGER NOT NULL,  -- as the loader computes it (0xc8508); the file value is ignored
	tracking_pick   INTEGER NOT NULL,  -- 1 + tracking_override idx, 0: the move's default
	PRIMARY KEY (character, list, pos)
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

CREATE TABLE reaction (  -- arrays by the sim's T5ReactionSlot
	character  TEXT NOT NULL,
	idx        INTEGER NOT NULL,
	pushback_0 INTEGER NOT NULL, pushback_1 INTEGER NOT NULL, pushback_2 INTEGER NOT NULL, pushback_3 INTEGER NOT NULL, pushback_4 INTEGER NOT NULL, pushback_5 INTEGER NOT NULL, pushback_6 INTEGER NOT NULL,  -- pushback idx
	angle_0 INTEGER NOT NULL, angle_1 INTEGER NOT NULL, angle_2 INTEGER NOT NULL, angle_3 INTEGER NOT NULL, angle_4 INTEGER NOT NULL, angle_5 INTEGER NOT NULL,
	yaw_0 INTEGER NOT NULL, yaw_1 INTEGER NOT NULL, yaw_2 INTEGER NOT NULL, yaw_3 INTEGER NOT NULL, yaw_4 INTEGER NOT NULL, yaw_5 INTEGER NOT NULL,
	move_0 INTEGER NOT NULL, move_1 INTEGER NOT NULL, move_2 INTEGER NOT NULL, move_3 INTEGER NOT NULL, move_4 INTEGER NOT NULL, move_5 INTEGER NOT NULL, move_6 INTEGER NOT NULL,
	move_7 INTEGER NOT NULL, move_8 INTEGER NOT NULL, move_9 INTEGER NOT NULL, move_10 INTEGER NOT NULL, move_11 INTEGER NOT NULL, move_12 INTEGER NOT NULL, move_13 INTEGER NOT NULL,
	PRIMARY KEY (character, idx)
);

CREATE TABLE pushback (
	character    TEXT NOT NULL,
	idx          INTEGER NOT NULL,
	frames       INTEGER NOT NULL,
	distance     INTEGER NOT NULL,
	curve_frames INTEGER NOT NULL,
	unk_06       INTEGER,           -- (not loaded)
	curve        INTEGER NOT NULL,  -- pushback_curve list
	PRIMARY KEY (character, idx)
);

CREATE TABLE pushback_curve (
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	value     INTEGER NOT NULL,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE extra_prop (  -- "when" is an SQL keyword: quote it
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	"when"    INTEGER NOT NULL,  -- frame code; 0 ends a list
	id        INTEGER NOT NULL,
	value     INTEGER NOT NULL,  -- property 0x8071: a tracking_row, not the game's mode
	unk_06    INTEGER,           -- (not loaded)
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE start_prop (
	character    TEXT NOT NULL,
	list         INTEGER NOT NULL,
	pos          INTEGER NOT NULL,
	requirements INTEGER NOT NULL,  -- requirement list
	id           INTEGER NOT NULL,
	value        INTEGER NOT NULL,
	PRIMARY KEY (character, list, pos)
);

CREATE TABLE end_prop (
	character    TEXT NOT NULL,
	list         INTEGER NOT NULL,
	pos          INTEGER NOT NULL,
	requirements INTEGER NOT NULL,  -- requirement list
	id           INTEGER NOT NULL,
	value        INTEGER NOT NULL,
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
	window    INTEGER NOT NULL,  -- past input frames searched for the sequence
	count     INTEGER NOT NULL,
	first     INTEGER NOT NULL,  -- input_extra list
	PRIMARY KEY (character, idx)
);

CREATE TABLE input_extra (
	character TEXT NOT NULL,
	list      INTEGER NOT NULL,
	pos       INTEGER NOT NULL,
	code      INTEGER NOT NULL,
	buttons   INTEGER NOT NULL,
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

CREATE TABLE body (  -- hurtboxes: vertical cylinders on bones of skeleton B, in hit record order; push spheres: radius at rest
	character       TEXT PRIMARY KEY,
	hurt_radius_0 INTEGER NOT NULL, hurt_bone_0 INTEGER NOT NULL, hurt_lift_0 REAL NOT NULL,  -- radius: and half height
	hurt_radius_1 INTEGER NOT NULL, hurt_bone_1 INTEGER NOT NULL, hurt_lift_1 REAL NOT NULL,
	hurt_radius_2 INTEGER NOT NULL, hurt_bone_2 INTEGER NOT NULL, hurt_lift_2 REAL NOT NULL,
	hurt_radius_3 INTEGER NOT NULL, hurt_bone_3 INTEGER NOT NULL, hurt_lift_3 REAL NOT NULL,
	hurt_radius_4 INTEGER NOT NULL, hurt_bone_4 INTEGER NOT NULL, hurt_lift_4 REAL NOT NULL,
	hurt_radius_5 INTEGER NOT NULL, hurt_bone_5 INTEGER NOT NULL, hurt_lift_5 REAL NOT NULL,
	hurt_radius_6 INTEGER NOT NULL, hurt_bone_6 INTEGER NOT NULL, hurt_lift_6 REAL NOT NULL,
	hurt_radius_7 INTEGER NOT NULL, hurt_bone_7 INTEGER NOT NULL, hurt_lift_7 REAL NOT NULL,
	hurt_radius_8 INTEGER NOT NULL, hurt_bone_8 INTEGER NOT NULL, hurt_lift_8 REAL NOT NULL,
	hurt_radius_9 INTEGER NOT NULL, hurt_bone_9 INTEGER NOT NULL, hurt_lift_9 REAL NOT NULL,
	hurt_radius_10 INTEGER NOT NULL, hurt_bone_10 INTEGER NOT NULL, hurt_lift_10 REAL NOT NULL,
	hurt_radius_11 INTEGER NOT NULL, hurt_bone_11 INTEGER NOT NULL, hurt_lift_11 REAL NOT NULL,
	hurt_radius_12 INTEGER NOT NULL, hurt_bone_12 INTEGER NOT NULL, hurt_lift_12 REAL NOT NULL,
	hurt_radius_13 INTEGER NOT NULL, hurt_bone_13 INTEGER NOT NULL, hurt_lift_13 REAL NOT NULL,
	push_radius_0 REAL NOT NULL, push_bone_0 INTEGER NOT NULL,
	push_radius_1 REAL NOT NULL, push_bone_1 INTEGER NOT NULL,
	push_radius_2 REAL NOT NULL, push_bone_2 INTEGER NOT NULL,
	push_radius_3 REAL NOT NULL, push_bone_3 INTEGER NOT NULL,
	push_radius_4 REAL NOT NULL, push_bone_4 INTEGER NOT NULL,
	push_radius_5 REAL NOT NULL, push_bone_5 INTEGER NOT NULL,
	push_radius_6 REAL NOT NULL, push_bone_6 INTEGER NOT NULL,
	push_radius_7 REAL NOT NULL, push_bone_7 INTEGER NOT NULL,
	throw_range_cut REAL NOT NULL,     -- both fighters' throw range is shorter by this for this fighter
	head_probe_x    REAL NOT NULL,     -- head floor probe: point and radius, fractions of the head end bone length
	head_probe_z    REAL NOT NULL,
	head_probe_radius REAL NOT NULL,
	head_top        REAL NOT NULL      -- head end height in the standing idle (not stock: measured at import)
);

-- Points fixed to a bone of skeleton B (special slots 6, 7), and the shots: rows of the sim's hitscan and projectile lists, 0: none.
CREATE TABLE body_points (
	character TEXT PRIMARY KEY,
	count     INTEGER NOT NULL,  -- points in use
	point_bone_0 INTEGER NOT NULL, point_offset_x_0 REAL NOT NULL, point_offset_y_0 REAL NOT NULL, point_offset_z_0 REAL NOT NULL,
	point_bone_1 INTEGER NOT NULL, point_offset_x_1 REAL NOT NULL, point_offset_y_1 REAL NOT NULL, point_offset_z_1 REAL NOT NULL,
	hitscan   INTEGER NOT NULL,
	projectile INTEGER NOT NULL
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
	rate_frames_by_distance INTEGER NOT NULL,
	limit_total INTEGER NOT NULL,
	limit_sweep_0 INTEGER NOT NULL, limit_sweep_1 INTEGER NOT NULL, limit_sweep_2 INTEGER NOT NULL, limit_sweep_3 INTEGER NOT NULL,  -- front, left, back, right
	end_move_yaw_when INTEGER NOT NULL,  -- never, always, unless the anim changed
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
