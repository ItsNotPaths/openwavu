-- Tekken 5 DR movesets (motbin, tk5decomp data.md §4, code-map.md). Applied after ../schema.sql.
-- (hole tekken-schema :tags importer) the tables the sim loads are the TK5 sim's record layouts (modules/tk5/load.c); they are not yet one Tekken shape that every Tekken sim reads under its own names, with game-only tables optional.
-- Columns are named after the sim's fields (arrays: name_0, name_1, ...). "(not loaded)": the sim does not read the column.
-- A row has a text key `<character>/<name>`; every cell that names a row is a declared foreign key, NULL for none.
-- Stock rows sit in the game's order (rowid); rows a mod adds follow. A list is a row of <table>_list with child rows
-- (list, pos) in <table>. Lists end where the game's do: a list's last cancel is a real one (command_code 0x8000);
-- requirement and property lists hold no end row, the loader adds it. A cell that names a move has an alias twin (the
-- move slot n of 0x8000 + n, which the game can remap).
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

CREATE TABLE move_alias (  -- move id 0x8000 + slot
	character TEXT NOT NULL REFERENCES motbin(character),
	slot      INTEGER NOT NULL,
	move      TEXT NOT NULL REFERENCES move(key),
	PRIMARY KEY (character, slot)
);

CREATE TABLE move (
	key            TEXT PRIMARY KEY,  -- <character>/<name>
	character      TEXT NOT NULL REFERENCES motbin(character),
	name           TEXT NOT NULL,
	anim_name      TEXT,
	anim_owner     TEXT NOT NULL,     -- anim(character): container owner, <char>/embedded or common
	anim_idx       INTEGER NOT NULL,
	anim           INTEGER NOT NULL,  -- the raw anim id (not loaded)
	vuln           INTEGER NOT NULL,
	hit_level      INTEGER NOT NULL,
	cancels        TEXT NOT NULL REFERENCES cancel_list(key),
	next_move      TEXT REFERENCES move(key),  -- the move it goes to when it ends
	next_alias     INTEGER,
	end_yaw        INTEGER NOT NULL,
	compare_id     NOT NULL,  -- move identity (requirements, move pools, throws): a number; a mod's own is text, numbered after every stock one
	push_speed     INTEGER NOT NULL,
	hit_conditions TEXT NOT NULL REFERENCES hit_condition_list(key),
	window_start   INTEGER NOT NULL,
	window_end     INTEGER NOT NULL,
	hold_frame     INTEGER NOT NULL,
	voiceclips     TEXT REFERENCES voiceclip_list(key),  -- (not loaded)
	extra_props    TEXT REFERENCES extra_prop_list(key),
	start_props    TEXT REFERENCES start_prop_list(key),
	end_prop       TEXT REFERENCES end_prop_list(key),
	flags          INTEGER NOT NULL,  -- +0x3c in the loader's bit order (0xc8508): bits 0..3 kept, file bit i (4..31) at 35 - i
	hit_category   INTEGER NOT NULL,  -- +0x40, the game's 4 hitbox bytes (not loaded: hit_pair_* and hits_* hold what they mean)
	first_active   INTEGER NOT NULL,
	last_active    INTEGER NOT NULL,
	push_shape     INTEGER NOT NULL,
	unk_4a         INTEGER NOT NULL,
	tracking_row        TEXT NOT NULL REFERENCES tracking_row(key),  -- default tracking
	tracking_far_row    TEXT NOT NULL REFERENCES tracking_row(key),  -- used instead when the angle of far_source is above far_angle
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
	FOREIGN KEY (anim_owner, anim_idx) REFERENCES anim(character, idx)
);
CREATE INDEX move_character ON move(character);

-- command_code 0x8000 ends a list; 0x8005 enters group_list, 0x8006 returns; 0x8007 reads the row's input_sequence.
-- (hole tk5-input-import :tags (importer tk5mod)) commands are TK5 bits (command_code, command_buttons, input_sequence and its input_extra lists, window_start/window_end/start_frame); they should be one `input` text cell (docs/commands.md), with the end, group and return rows as a `kind` column.
CREATE TABLE cancel_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX cancel_list_character ON cancel_list(character);

CREATE TABLE cancel (
	list            TEXT NOT NULL REFERENCES cancel_list(key),
	pos             INTEGER NOT NULL,
	command_code    INTEGER NOT NULL,
	command_buttons INTEGER NOT NULL,
	requirements    TEXT NOT NULL REFERENCES requirement_list(key),
	move            TEXT REFERENCES move(key),
	alias           INTEGER,
	group_list      TEXT REFERENCES group_cancel_list(key),  -- a group entry: the group cancel list it enters
	unk_0a          INTEGER,           -- (not loaded)
	extradata       INTEGER NOT NULL,
	window_start    INTEGER NOT NULL,
	window_end      INTEGER NOT NULL,
	start_frame     INTEGER NOT NULL,
	option          INTEGER NOT NULL,  -- as the loader computes it (0xc8508); the file value is ignored
	-- (hole cancel-flag-words :tags (importer tk5mod) :needs tk5-input-import) option and extradata are TK5 bits; reversal, stop, lock skip, no move and unlocking a locked fighter should be words after the timing in `input` (docs/commands.md, Open).
	tracking_override TEXT REFERENCES tracking_override(key),  -- NULL: the move's own tracking
	input_sequence  TEXT REFERENCES input_sequence(key),        -- command_code 0x8007: the sequence it reads
	PRIMARY KEY (list, pos)
);

CREATE TABLE group_cancel_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX group_cancel_list_character ON group_cancel_list(character);

CREATE TABLE group_cancel (
	list            TEXT NOT NULL REFERENCES group_cancel_list(key),
	pos             INTEGER NOT NULL,
	command_code    INTEGER NOT NULL,
	command_buttons INTEGER NOT NULL,
	requirements    TEXT NOT NULL REFERENCES requirement_list(key),
	move            TEXT REFERENCES move(key),
	alias           INTEGER,
	group_list      TEXT REFERENCES group_cancel_list(key),
	unk_0a          INTEGER,           -- (not loaded)
	extradata       INTEGER NOT NULL,
	window_start    INTEGER NOT NULL,
	window_end      INTEGER NOT NULL,
	start_frame     INTEGER NOT NULL,
	option          INTEGER NOT NULL,
	tracking_override TEXT REFERENCES tracking_override(key),
	input_sequence  TEXT REFERENCES input_sequence(key),
	PRIMARY KEY (list, pos)
);

-- A param or value that names a row is in the column of that table (param_move, value_pushback, ...), the plain
-- param NULL. Which codes name which table: src/convert/tk5/stock.odin CODE_REFS.
CREATE TABLE requirement_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX requirement_list_character ON requirement_list(character);

CREATE TABLE requirement (
	list      TEXT NOT NULL REFERENCES requirement_list(key),
	pos       INTEGER NOT NULL,
	id        INTEGER NOT NULL,  -- code_name kind 'tk5.requirement'
	param     INTEGER,           -- 0xf1, 0xf2: a phase test (stock.odin requirement_param), not the game's flow state
	param_move       TEXT REFERENCES move(key),
	param_alias      INTEGER,
	param_pushback   TEXT REFERENCES pushback(key),
	param_tracking_row TEXT REFERENCES tracking_row(key),
	param_move_pool  TEXT REFERENCES move_pool_list(key),
	param_compare_id,            -- a move identity, as move.compare_id
	PRIMARY KEY (list, pos)
);

CREATE TABLE hit_condition_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX hit_condition_list_character ON hit_condition_list(character);

CREATE TABLE hit_condition (
	list         TEXT NOT NULL REFERENCES hit_condition_list(key),
	pos          INTEGER NOT NULL,
	requirements TEXT NOT NULL REFERENCES requirement_list(key),
	damage       INTEGER,
	unk_06       INTEGER,
	reaction     TEXT NOT NULL REFERENCES reaction(key),
	PRIMARY KEY (list, pos)
);

CREATE TABLE reaction (  -- arrays by the sim's T5ReactionSlot
	key        TEXT PRIMARY KEY,
	character  TEXT NOT NULL REFERENCES motbin(character),
	pushback_0 TEXT NOT NULL REFERENCES pushback(key), pushback_1 TEXT NOT NULL REFERENCES pushback(key),
	pushback_2 TEXT NOT NULL REFERENCES pushback(key), pushback_3 TEXT NOT NULL REFERENCES pushback(key),
	pushback_4 TEXT NOT NULL REFERENCES pushback(key), pushback_5 TEXT NOT NULL REFERENCES pushback(key),
	pushback_6 TEXT NOT NULL REFERENCES pushback(key),
	angle_0 INTEGER NOT NULL, angle_1 INTEGER NOT NULL, angle_2 INTEGER NOT NULL, angle_3 INTEGER NOT NULL, angle_4 INTEGER NOT NULL, angle_5 INTEGER NOT NULL,
	yaw_0 INTEGER NOT NULL, yaw_1 INTEGER NOT NULL, yaw_2 INTEGER NOT NULL, yaw_3 INTEGER NOT NULL, yaw_4 INTEGER NOT NULL, yaw_5 INTEGER NOT NULL,
	move_0 TEXT REFERENCES move(key), move_1 TEXT REFERENCES move(key), move_2 TEXT REFERENCES move(key),
	move_3 TEXT REFERENCES move(key), move_4 TEXT REFERENCES move(key), move_5 TEXT REFERENCES move(key),
	move_6 TEXT REFERENCES move(key), move_7 TEXT REFERENCES move(key), move_8 TEXT REFERENCES move(key),
	move_9 TEXT REFERENCES move(key), move_10 TEXT REFERENCES move(key), move_11 TEXT REFERENCES move(key),
	move_12 TEXT REFERENCES move(key), move_13 TEXT REFERENCES move(key),
	alias_0 INTEGER, alias_1 INTEGER, alias_2 INTEGER, alias_3 INTEGER, alias_4 INTEGER, alias_5 INTEGER, alias_6 INTEGER,
	alias_7 INTEGER, alias_8 INTEGER, alias_9 INTEGER, alias_10 INTEGER, alias_11 INTEGER, alias_12 INTEGER, alias_13 INTEGER
);
CREATE INDEX reaction_character ON reaction(character);

CREATE TABLE pushback (
	key          TEXT PRIMARY KEY,
	character    TEXT NOT NULL REFERENCES motbin(character),
	frames       INTEGER NOT NULL,
	distance     INTEGER NOT NULL,
	curve_frames INTEGER NOT NULL,  -- values of the curve it reads, from the first
	unk_06       INTEGER,           -- (not loaded)
	curve        TEXT NOT NULL REFERENCES pushback_curve_list(key)
);
CREATE INDEX pushback_character ON pushback(character);

CREATE TABLE pushback_curve_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX pushback_curve_list_character ON pushback_curve_list(character);

CREATE TABLE pushback_curve (
	list  TEXT NOT NULL REFERENCES pushback_curve_list(key),
	pos   INTEGER NOT NULL,
	value INTEGER NOT NULL,
	PRIMARY KEY (list, pos)
);

CREATE TABLE extra_prop_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX extra_prop_list_character ON extra_prop_list(character);

CREATE TABLE extra_prop (  -- "when" is an SQL keyword: quote it
	list      TEXT NOT NULL REFERENCES extra_prop_list(key),
	pos       INTEGER NOT NULL,
	"when"    INTEGER NOT NULL,  -- frame code
	id        INTEGER NOT NULL,
	value     INTEGER,           -- property 0x8071: a tracking_row, not the game's mode
	value_move       TEXT REFERENCES move(key),
	value_alias      INTEGER,
	value_pushback   TEXT REFERENCES pushback(key),
	value_tracking_row TEXT REFERENCES tracking_row(key),
	value_move_pool  TEXT REFERENCES move_pool_list(key),
	value_compare_id,
	unk_06    INTEGER,           -- (not loaded)
	PRIMARY KEY (list, pos)
);

CREATE TABLE start_prop_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX start_prop_list_character ON start_prop_list(character);

CREATE TABLE start_prop (
	list         TEXT NOT NULL REFERENCES start_prop_list(key),
	pos          INTEGER NOT NULL,
	requirements TEXT NOT NULL REFERENCES requirement_list(key),
	id           INTEGER NOT NULL,
	value        INTEGER,
	value_move       TEXT REFERENCES move(key),
	value_alias      INTEGER,
	value_pushback   TEXT REFERENCES pushback(key),
	value_tracking_row TEXT REFERENCES tracking_row(key),
	value_move_pool  TEXT REFERENCES move_pool_list(key),
	value_compare_id,
	PRIMARY KEY (list, pos)
);

CREATE TABLE end_prop_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX end_prop_list_character ON end_prop_list(character);

CREATE TABLE end_prop (
	list         TEXT NOT NULL REFERENCES end_prop_list(key),
	pos          INTEGER NOT NULL,
	requirements TEXT NOT NULL REFERENCES requirement_list(key),
	id           INTEGER NOT NULL,
	value        INTEGER,
	value_move       TEXT REFERENCES move(key),
	value_alias      INTEGER,
	value_pushback   TEXT REFERENCES pushback(key),
	value_tracking_row TEXT REFERENCES tracking_row(key),
	value_move_pool  TEXT REFERENCES move_pool_list(key),
	value_compare_id,
	PRIMARY KEY (list, pos)
);

CREATE TABLE voiceclip_list (  -- (not loaded)
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);

CREATE TABLE voiceclip (
	list      TEXT NOT NULL REFERENCES voiceclip_list(key),
	pos       INTEGER NOT NULL,
	value     INTEGER NOT NULL,
	PRIMARY KEY (list, pos)
);

-- Command 0x8007 + n reads input sequence n.
CREATE TABLE input_sequence (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character),
	window    INTEGER NOT NULL,  -- past input frames searched for the sequence
	count     INTEGER NOT NULL,
	first     TEXT NOT NULL REFERENCES input_extra_list(key)
);
CREATE INDEX input_sequence_character ON input_sequence(character);

CREATE TABLE input_extra_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX input_extra_list_character ON input_extra_list(character);

CREATE TABLE input_extra (
	list      TEXT NOT NULL REFERENCES input_extra_list(key),
	pos       INTEGER NOT NULL,
	code      INTEGER NOT NULL,
	buttons   INTEGER NOT NULL,
	PRIMARY KEY (list, pos)
);

-- Table 0x200: pools of move identities; requirements name them.
CREATE TABLE move_pool_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX move_pool_list_character ON move_pool_list(character);

CREATE TABLE move_pool (
	list       TEXT NOT NULL REFERENCES move_pool_list(key),
	pos        INTEGER NOT NULL,
	compare_id NOT NULL,  -- as move.compare_id
	PRIMARY KEY (list, pos)
);

-- Pause menu command list. Strings are UTF-16 BE in the file, button glyphs in U+E0xx.
CREATE TABLE command_list (
	character TEXT NOT NULL REFERENCES motbin(character),
	slot      INTEGER NOT NULL,
	name_ja   TEXT,
	name_en   TEXT,
	name_ja2  TEXT,
	command_0 TEXT, command_1 TEXT, command_2 TEXT, command_3 TEXT,
	command_4 TEXT, command_5 TEXT, command_6 TEXT, command_7 TEXT,
	unk_2c INTEGER, unk_30 INTEGER, unk_34 INTEGER, unk_38 INTEGER,
	PRIMARY KEY (character, slot)
);

-- Tables not decoded yet (header 0x208, 0x210, 0x220, 0x228, 0x230, 0x238), raw.
-- 0x238: 8-byte records, +4 an extra_prop index (a list start).
CREATE TABLE unknown_table (
	character TEXT NOT NULL REFERENCES motbin(character),
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

-- Facing rows: how a move turns the fighter (law, target, gate, rate, limit, end). The first row is hold. Degrees, frames, mm.
CREATE TABLE tracking_row (
	key        TEXT PRIMARY KEY,
	character  TEXT NOT NULL REFERENCES motbin(character),
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
	end_phase INTEGER NOT NULL
);
CREATE INDEX tracking_row_character ON tracking_row(character);

-- Tracking a cancel entry names (cancel.tracking_override).
CREATE TABLE tracking_override (
	key        TEXT PRIMARY KEY,
	character  TEXT NOT NULL REFERENCES motbin(character),
	row        TEXT NOT NULL REFERENCES tracking_row(key),
	far_row    TEXT NOT NULL REFERENCES tracking_row(key),
	far_source INTEGER NOT NULL,
	far_angle  INTEGER NOT NULL
);
CREATE INDEX tracking_override_character ON tracking_override(character);

-- Fixed tracking: 0 a carried cancel the sim rewrites to motion code 2, 1 a guarding reaction.
CREATE TABLE tracking_fixed (
	character  TEXT NOT NULL REFERENCES motbin(character),
	slot       INTEGER NOT NULL,
	row        TEXT NOT NULL REFERENCES tracking_row(key),
	far_row    TEXT NOT NULL REFERENCES tracking_row(key),
	far_source INTEGER NOT NULL,
	far_angle  INTEGER NOT NULL,
	PRIMARY KEY (character, slot)
);

-- Side bands (motbin header 0x140): the sector widths of an angle, by band.
CREATE TABLE side_band (
	character TEXT NOT NULL REFERENCES motbin(character),
	slot      INTEGER NOT NULL,
	offset    INTEGER NOT NULL,  -- added to the angle
	width_0   INTEGER NOT NULL,  -- sectors 0..2; sector 3 is the rest
	width_1   INTEGER NOT NULL,
	width_2   INTEGER NOT NULL,
	PRIMARY KEY (character, slot)
);

CREATE TABLE gaze (
	character TEXT PRIMARY KEY,
	tilt      REAL NOT NULL,     -- radians, about the level axis across the line to the opponent's head
	head_turn INTEGER NOT NULL   -- angle steps (65536 a turn) about the head's y axis
);
