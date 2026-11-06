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
	-- (hole motbin-header :tags importer :sev polish) header 0x140..0x188 is a raw blob; side_band already reads 0x140, the rest is not decoded.
	unk_140   BLOB            -- header 0x140..0x188
);

CREATE TABLE move_alias (  -- move id 0x8000 + slot
	character TEXT NOT NULL REFERENCES motbin(character),
	slot      INTEGER NOT NULL,
	move      TEXT NOT NULL REFERENCES move(key),
	PRIMARY KEY (character, slot)
);

-- The class of a state (state.h): the game reads the number only for launched, launched_downed, jump, jump_alternate and
-- air_guard; the others are labels of a fixed state bit pattern.
CREATE TABLE state_class (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO state_class VALUES
	('stand_open', 1), ('stand_guard', 2), ('stand_walk', 3), ('stand_wall_pose', 4), ('crouch_open', 5), ('crouch_guard', 6),
	('crouch_guard_locked', 7), ('lying_face_up', 12), ('lying_face_down', 13), ('launched', 14), ('launched_downed', 15),
	('invulnerable', 20),
	('unknown_vuln_class_21', 21),  -- the bits of launched, read by nothing
	('crouch_launched', 22), ('jump', 23), ('jump_alternate', 24), ('air_guard', 25);

-- What an attack is (hit.h): the guards that block it and the reaction it gives.
CREATE TABLE attack_kind (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO attack_kind VALUES
	('none', 0), ('low', 1), ('mid', 2), ('mid_either_guard', 3), ('low_either_guard', 4), ('high', 5), ('mid_unblockable', 7),
	('high_unblockable', 8), ('low_unblockable', 9), ('no_height', 10), ('air_only', 11),
	('slide', 12);  -- no stock move

CREATE TABLE move (
	key            TEXT PRIMARY KEY,  -- <character>/<name>
	character      TEXT NOT NULL REFERENCES motbin(character),
	name           TEXT NOT NULL,
	anim_name      TEXT,
	anim_owner     TEXT NOT NULL,     -- anim(character): container owner, <char>/embedded or common
	anim_idx       INTEGER NOT NULL,
	-- (hole move-copy-columns :tags (importer content) :sev polish) anim repeats anim_owner and anim_idx (every stock row); hit_category is the raw hitbox bytes hit_pair_* and hits_* are made from, not yet proven lossless. Both still in the sheet.
	anim           INTEGER NOT NULL,  -- the raw anim id (not loaded)
	-- state_*: the fighter's state while in the move (state.h): which heights hit them, guard, which throws take them.
	state_class    TEXT NOT NULL REFERENCES state_class(name),
	state_hurt_crouching INTEGER NOT NULL DEFAULT 0 CHECK (state_hurt_crouching IN (0, 1)),
	state_hurt_standing INTEGER NOT NULL DEFAULT 0 CHECK (state_hurt_standing IN (0, 1)),
	state_hurt_lying INTEGER NOT NULL DEFAULT 0 CHECK (state_hurt_lying IN (0, 1)),
	state_guard_crouch INTEGER NOT NULL DEFAULT 0 CHECK (state_guard_crouch IN (0, 1)),
	state_guard_stand INTEGER NOT NULL DEFAULT 0 CHECK (state_guard_stand IN (0, 1)),
	state_throw_crouching INTEGER NOT NULL DEFAULT 0 CHECK (state_throw_crouching IN (0, 1)),
	state_throw_standing INTEGER NOT NULL DEFAULT 0 CHECK (state_throw_standing IN (0, 1)),
	state_throw_lying INTEGER NOT NULL DEFAULT 0 CHECK (state_throw_lying IN (0, 1)),
	state_guard_locked INTEGER NOT NULL DEFAULT 0 CHECK (state_guard_locked IN (0, 1)),
	state_downed INTEGER NOT NULL DEFAULT 0 CHECK (state_downed IN (0, 1)),
	state_launched INTEGER NOT NULL DEFAULT 0 CHECK (state_launched IN (0, 1)),
	attack_kind    TEXT NOT NULL REFERENCES attack_kind(name),
	attack_hits_crouching INTEGER NOT NULL DEFAULT 0 CHECK (attack_hits_crouching IN (0, 1)),
	attack_hits_standing INTEGER NOT NULL DEFAULT 0 CHECK (attack_hits_standing IN (0, 1)),
	attack_hits_lying INTEGER NOT NULL DEFAULT 0 CHECK (attack_hits_lying IN (0, 1)),
	attack_blocked_by_crouch_guard INTEGER NOT NULL DEFAULT 0 CHECK (attack_blocked_by_crouch_guard IN (0, 1)),
	attack_blocked_by_stand_guard INTEGER NOT NULL DEFAULT 0 CHECK (attack_blocked_by_stand_guard IN (0, 1)),
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
	-- The move's flags (motbin.h T5_MOVE_*).
	keeps_hips INTEGER NOT NULL DEFAULT 0 CHECK (keeps_hips IN (0, 1)),
	turns_at_end INTEGER NOT NULL DEFAULT 0 CHECK (turns_at_end IN (0, 1)),
	looks_at_opponent INTEGER NOT NULL DEFAULT 0 CHECK (looks_at_opponent IN (0, 1)),
	follows_floor INTEGER NOT NULL DEFAULT 0 CHECK (follows_floor IN (0, 1)),
	no_blend_in INTEGER NOT NULL DEFAULT 0 CHECK (no_blend_in IN (0, 1)),
	no_blend_out INTEGER NOT NULL DEFAULT 0 CHECK (no_blend_out IN (0, 1)),
	hit_reaction INTEGER NOT NULL DEFAULT 0 CHECK (hit_reaction IN (0, 1)),
	guard_by_input INTEGER NOT NULL DEFAULT 0 CHECK (guard_by_input IN (0, 1)),
	no_leg_push INTEGER NOT NULL DEFAULT 0 CHECK (no_leg_push IN (0, 1)),
	sets_hurt_lying INTEGER NOT NULL DEFAULT 0 CHECK (sets_hurt_lying IN (0, 1)),
	throw_resync INTEGER NOT NULL DEFAULT 0 CHECK (throw_resync IN (0, 1)),
	starts_on_partner INTEGER NOT NULL DEFAULT 0 CHECK (starts_on_partner IN (0, 1)),
	thrown_stays INTEGER NOT NULL DEFAULT 0 CHECK (thrown_stays IN (0, 1)),
	keeps_root_yaw INTEGER NOT NULL DEFAULT 0 CHECK (keeps_root_yaw IN (0, 1)),
	no_ko_cut INTEGER NOT NULL DEFAULT 0 CHECK (no_ko_cut IN (0, 1)),
	holds_face_expression INTEGER NOT NULL DEFAULT 0 CHECK (holds_face_expression IN (0, 1)),
	no_start_shift INTEGER NOT NULL DEFAULT 0 CHECK (no_start_shift IN (0, 1)),
	no_sword_trail INTEGER NOT NULL DEFAULT 0 CHECK (no_sword_trail IN (0, 1)),
	forces_sword_trail INTEGER NOT NULL DEFAULT 0 CHECK (forces_sword_trail IN (0, 1)),
	grounded_reaction INTEGER NOT NULL DEFAULT 0 CHECK (grounded_reaction IN (0, 1)),
	keeps_took_damage INTEGER NOT NULL DEFAULT 0 CHECK (keeps_took_damage IN (0, 1)),
	string_move INTEGER NOT NULL DEFAULT 0 CHECK (string_move IN (0, 1)),
	practice_dummy_recovery INTEGER NOT NULL DEFAULT 0 CHECK (practice_dummy_recovery IN (0, 1)),
	reaction_continues INTEGER NOT NULL DEFAULT 0 CHECK (reaction_continues IN (0, 1)),
	blends_in_active INTEGER NOT NULL DEFAULT 0 CHECK (blends_in_active IN (0, 1)),
	hit_category   INTEGER NOT NULL,  -- +0x40, the game's 4 hitbox bytes (not loaded: hit_pair_* and hits_* hold what they mean)
	first_active   INTEGER NOT NULL,
	last_active    INTEGER NOT NULL,
	push_shape     INTEGER NOT NULL,
	tracking_row        TEXT NOT NULL REFERENCES tracking_row(key),  -- default tracking
	tracking_far_row    TEXT NOT NULL REFERENCES tracking_row(key),  -- used instead when the angle of far_source is above far_angle
	tracking_far_source TEXT NOT NULL REFERENCES tracking_far_source(name),
	tracking_far_angle  INTEGER NOT NULL,
	rides_partner  INTEGER NOT NULL,  -- the thrower rides on the partner (Xiaoyu's Hien throws)
	-- The hitbox of slot n ends at the end point and starts at the start point: a kind (none, bone, special, effect, keep,
	-- fixed, hitscan, projectile) and an index.
	hit_pair_end_kind_0 TEXT NOT NULL REFERENCES hit_point_kind(name), hit_pair_end_index_0 INTEGER NOT NULL,
	hit_pair_start_kind_0 TEXT NOT NULL REFERENCES hit_point_kind(name), hit_pair_start_index_0 INTEGER NOT NULL,
	hit_pair_end_kind_1 TEXT NOT NULL REFERENCES hit_point_kind(name), hit_pair_end_index_1 INTEGER NOT NULL,
	hit_pair_start_kind_1 TEXT NOT NULL REFERENCES hit_point_kind(name), hit_pair_start_index_1 INTEGER NOT NULL,
	hits_attack_bones INTEGER NOT NULL,  -- bit b: the move attacks with bone b of skeleton B
	hits_slots     INTEGER NOT NULL,     -- hitbox slots that get points while active: 0..2
	hits_launches  INTEGER NOT NULL,     -- a hitbox runs from the projectile's point
	FOREIGN KEY (anim_owner, anim_idx) REFERENCES anim(character, idx)
);
CREATE INDEX move_character ON move(character);

-- The stock CPU's reading of a move (rows only for moves with one set).
-- (hole cpu-ai-rewrite :tags (sim tk5mod) :sev gap) not final: openwavu rewrites the CPU AI and ghosts behind an API of its own; these columns are the stock AI's inputs, kept until then.
CREATE TABLE move_ai (
	move TEXT PRIMARY KEY REFERENCES move(key),
	ai_any_range INTEGER NOT NULL DEFAULT 0 CHECK (ai_any_range IN (0, 1)),
	ai_not_an_attack INTEGER NOT NULL DEFAULT 0 CHECK (ai_not_an_attack IN (0, 1)),
	ai_attack_move INTEGER NOT NULL DEFAULT 0 CHECK (ai_attack_move IN (0, 1)),
	ai_treat_as_unblockable INTEGER NOT NULL DEFAULT 0 CHECK (ai_treat_as_unblockable IN (0, 1)),
	ai_evading INTEGER NOT NULL DEFAULT 0 CHECK (ai_evading IN (0, 1)),
	ai_never_picks INTEGER NOT NULL DEFAULT 0 CHECK (ai_never_picks IN (0, 1)),
	ai_low_attack INTEGER NOT NULL DEFAULT 0 CHECK (ai_low_attack IN (0, 1)),
	ai_reach_short INTEGER NOT NULL DEFAULT 0 CHECK (ai_reach_short IN (0, 1)),
	ai_reach_medium INTEGER NOT NULL DEFAULT 0 CHECK (ai_reach_medium IN (0, 1)),
	ai_reach_long INTEGER NOT NULL DEFAULT 0 CHECK (ai_reach_long IN (0, 1)),
	ai_strike_option INTEGER NOT NULL DEFAULT 0 CHECK (ai_strike_option IN (0, 1)),
	ai_throw INTEGER NOT NULL DEFAULT 0 CHECK (ai_throw IN (0, 1)),
	ai_follow_up_input INTEGER NOT NULL DEFAULT 0 CHECK (ai_follow_up_input IN (0, 1))
);

-- How a cancel starts its move (modules/tk5/sim/transition.h): which frame (transition), how the fighter re-aligns
-- (start_align) and what turns it after (motion, the stock tracking of tools/tracking.py). no_move in all three: a
-- matched entry starts nothing and falls to the list's end.
CREATE TABLE transition (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO transition VALUES
	('start', 0),     -- frame 1
	('carry', 1),     -- the next frame of the old move (frame 1 when the new move's active frames are past)
	('param', 2),     -- the frame start_param names
	('end', 3),       -- the last frame, playing backward
	('back', 4),      -- the frame before, playing backward
	('next', 5),      -- the next frame
	('thrower', 6),   -- frame 1; the thrower's side of a throw, linked to the opponent
	('thrown', 7),    -- frame 1; the victim of a throw
	('juggle', 8),    -- the frame the reaction asks for; the launch starts
	('pass', 9),      -- as start, but the entry does not end the cancel scan
	('no_move', 15);

CREATE TABLE start_align (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);  -- to_*: facing and move yaw, yaw_to_*: move yaw only
INSERT INTO start_align VALUES
	('keep', 0), ('keep_root', 1), ('yaw_to_facing', 2), ('yaw_to_facing_root', 3), ('to_opponent', 4), ('yaw_to_opponent', 5),
	('yaw_to_opponent_or_reference', 6), ('to_reference', 7), ('yaw_to_reference', 8), ('to_look', 9), ('yaw_to_look', 10),
	('throw_partner', 11), ('to_wall', 12), ('half_turn', 13), ('yaw_to_reference_less_reaction', 14), ('no_move', 15);

-- homing: turns to the opponent in startup, re-aims only when they are far round (*_any_angle: always homes); settle_*: closes
-- the angle to the target over 40 (very_slow), 30, 20, 10 or 5 (very_fast) frames; chase_*: homing at turn rate 3 (slowest)
-- to 23 (fastest), the steady ones without the slow-down while the opponent is busy.
CREATE TABLE motion (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO motion VALUES
	('none', 0),               -- tracking stays as it is
	('free', 1),               -- nothing steers; a running turn goes on
	('homing_soft', 2), ('homing_halved', 3), ('homing', 4), ('homing_soft_any_angle', 8), ('homing_halved_any_angle', 9),
	('homing_any_angle', 10),
	('homing_reference', 11),  -- strong homing on the reference direction
	('homing_behind_halved', 12), ('homing_behind', 13),
	('approach', 14),          -- turns to the target until the first active frame and slides in
	('ease_in', 15),           -- turns to the opponent, the pull ramping up over 8 frames
	('sweep_locked', 16),      -- swings to one side of the reference; cancels locked for 24 frames
	('sweep', 17),
	('face_start_spot', 18),   -- turns to where the opponent stood at the start, while 1200 apart or more
	('turn_to_target', 19),    -- turns to the target until the first active frame; from behind, half a turn more
	('turn_to_target_ahead', 20),
	('turn_to_move_yaw', 21),  -- 21..23 turn to the move yaw over 16 frames; the pushback stops
	('thrower', 22), ('thrown', 23),
	('guard', 24), ('juggle', 25), ('hit_down', 26), ('counter', 27), ('hit_front', 28), ('hit_back', 29), ('hit_left', 30),
	('hit_right', 31), ('hit_to_target', 32),
	('settle_to_opponent_very_slow', 33), ('settle_to_opponent_slow', 34), ('settle_to_opponent_medium', 35),
	('settle_to_opponent_fast', 36), ('settle_to_opponent_very_fast', 37), ('settle_to_opponent_by_distance', 38),
	('settle_to_side_very_slow', 39), ('settle_to_side_slow', 40), ('settle_to_side_medium', 41), ('settle_to_side_fast', 42),
	('settle_to_side_very_fast', 43), ('settle_to_side_by_distance', 44),
	('chase_slowest', 45), ('chase_slow', 46), ('chase_medium', 47), ('chase_fast', 48), ('chase_fastest', 49),
	('chase_steady_slowest', 50), ('chase_steady_slow', 51), ('chase_steady_medium', 52), ('chase_steady_fast', 53),
	('chase_steady_fastest', 54),
	('face_stage_centre', 55),  -- turns to the middle of the stage in 5 frames
	('no_move', 63);

-- input: the command, its timing and words as text (docs/commands.md). The cancel options are not stored: the loader
-- computes them, as the game does. kind: NULL for a cancel; end ends the list, group enters group_list, return goes back
-- after the group row; their input is timing only. The flags carry over to the move change.
CREATE TABLE cancel_list (
	key       TEXT PRIMARY KEY,
	character TEXT NOT NULL REFERENCES motbin(character)
);
CREATE INDEX cancel_list_character ON cancel_list(character);

CREATE TABLE cancel (
	list            TEXT NOT NULL REFERENCES cancel_list(key),
	pos             INTEGER NOT NULL,
	kind            TEXT CHECK (kind IN ('end', 'group', 'return')),
	input           TEXT NOT NULL,
	requirements    TEXT NOT NULL REFERENCES requirement_list(key),
	move            TEXT REFERENCES move(key),
	alias           INTEGER,
	group_list      TEXT REFERENCES group_cancel_list(key),  -- a group entry: the group cancel list it enters
	transition      TEXT NOT NULL REFERENCES transition(name),
	start_align     TEXT NOT NULL REFERENCES start_align(name),
	motion          TEXT NOT NULL REFERENCES motion(name),
	turn            INTEGER NOT NULL DEFAULT 0 CHECK (turn IN (0, 1)),          -- half a turn more
	no_blend_out    INTEGER NOT NULL DEFAULT 0 CHECK (no_blend_out IN (0, 1)),  -- no blend out into the next move
	no_root_fix     INTEGER NOT NULL DEFAULT 0 CHECK (no_root_fix IN (0, 1)),   -- the root is not re-placed for the new move
	root_hips       INTEGER NOT NULL DEFAULT 0 CHECK (root_hips IN (0, 1)),     -- the root fix places the fighter by the hips
	tracking_override TEXT REFERENCES tracking_override(key),  -- NULL: the move's own tracking
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
	kind            TEXT CHECK (kind IN ('end', 'group', 'return')),
	input           TEXT NOT NULL,
	requirements    TEXT NOT NULL REFERENCES requirement_list(key),
	move            TEXT REFERENCES move(key),
	alias           INTEGER,
	group_list      TEXT REFERENCES group_cancel_list(key),
	transition      TEXT NOT NULL REFERENCES transition(name),
	start_align     TEXT NOT NULL REFERENCES start_align(name),
	motion          TEXT NOT NULL REFERENCES motion(name),
	turn            INTEGER NOT NULL DEFAULT 0 CHECK (turn IN (0, 1)),
	no_blend_out    INTEGER NOT NULL DEFAULT 0 CHECK (no_blend_out IN (0, 1)),
	no_root_fix     INTEGER NOT NULL DEFAULT 0 CHECK (no_root_fix IN (0, 1)),
	root_hips       INTEGER NOT NULL DEFAULT 0 CHECK (root_hips IN (0, 1)),
	tracking_override TEXT REFERENCES tracking_override(key),
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
	-- (hole requirement-names :tags (importer tk5mod content) :sev polish) requirement ids are numbers with no names; code_name is empty.
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
	-- (hole property-names :tags (importer tk5mod content) :sev polish) property ids (extra, start and end properties) and the frame code "when" are numbers with no names.
	"when"    INTEGER NOT NULL,  -- frame code
	id        INTEGER NOT NULL,
	value     INTEGER,           -- property 0x8071: a tracking_row, not the game's mode
	value_move       TEXT REFERENCES move(key),
	value_alias      INTEGER,
	value_pushback   TEXT REFERENCES pushback(key),
	value_tracking_row TEXT REFERENCES tracking_row(key),
	value_move_pool  TEXT REFERENCES move_pool_list(key),
	value_compare_id,
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
	-- (hole command-list-unknowns :tags importer :sev polish) unk_2c..unk_38 hold real values (200 to 500 distinct), not decoded.
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

-- Where a hitbox point lies (modules/tk5/sim/motbin.h T5HitPointKind); hit_pair_*_index is read by the kind.
CREATE TABLE hit_point_kind (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO hit_point_kind VALUES
	('none', 0),        -- no point: the hitbox starts where its end point was before the motion step
	('bone', 1),        -- index: a bone of skeleton B
	('special', 2),     -- index: a special point slot
	('effect', 3),      -- the effect hitboxes of the move's side; the previous point stays
	('keep', 4),        -- the previous point stays
	('fixed', 5),       -- index: a fixed bone point of the character (body_points)
	('hitscan', 6),     -- index: 0 tip, 1 tail
	('projectile', 7);  -- index: 0 front, 1 back left, 2 back right

-- The names of the tracking codes (modules/tk5/sim/tracking.h).
CREATE TABLE tracking_law (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO tracking_law VALUES
	('hold', 0),      -- facing stays on the move yaw
	('home', 1),      -- turns toward the target, capped by the rate and the total limit
	('settle', 2),    -- closes a share of the gap to the target each frame
	('sweep', 3),     -- swings the yaw to one side of the target over the move
	('ease_out', 4),  -- a share of the gap that grows over the move
	('ease_in', 5),   -- a share of the gap that ramps up over the first frames
	('leave', 6);     -- faces the spot where the opponent stood, on the near side

CREATE TABLE tracking_phase (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO tracking_phase VALUES
	('running', 0),   -- the row's law runs
	('free', 1),      -- nothing runs, only the scripted turn of the move
	('reaim', 2),     -- every few frames, one scripted turn to the reference angle
	('scripted', 3);  -- a spread turn does the work

CREATE TABLE tracking_target (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO tracking_target VALUES
	('none', 0), ('opponent', 1), ('behind_opponent', 2),
	('reference', 3),            -- the opponent, or the opposite way when they stand behind
	('side_of_opponent', 4),     -- offset to the side the root leans to
	('stage_centre', 5), ('opponent_start_spot', 6);

CREATE TABLE tracking_when (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO tracking_when VALUES ('never', 0), ('always', 1), ('unless_anim_changed', 2);

CREATE TABLE tracking_gate (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO tracking_gate VALUES
	('none', 0), ('skip_while_busy', 1), ('spread_while_busy', 2),
	('spread_early_while_busy', 3);  -- only while the move clock is at most gate_until

CREATE TABLE tracking_halving (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO tracking_halving VALUES ('none', 0), ('all', 1), ('late', 2);  -- all: the picked rate halves; late: rate_late is half of rate_normal

-- The angle that picks the far row at move start.
CREATE TABLE tracking_far_source (name TEXT PRIMARY KEY, code INTEGER NOT NULL UNIQUE);
INSERT INTO tracking_far_source VALUES
	('never', 0), ('opponent_angle', 1),
	('angle_84', 2);  -- the fighter's angle at +0x84, not named yet; no stock row

-- Facing rows: how a move turns the fighter (law, target, gate, rate, limit, end). The first row is hold. Degrees, frames, mm.
CREATE TABLE tracking_row (
	key        TEXT PRIMARY KEY,
	character  TEXT NOT NULL REFERENCES motbin(character),
	law        TEXT NOT NULL REFERENCES tracking_law(name),
	start      TEXT NOT NULL REFERENCES tracking_phase(name),
	target     TEXT NOT NULL REFERENCES tracking_target(name),
	-- (hole tracking-stock-mode :tags (importer tools) :sev polish) stock_mode is data for the tk5decomp oracle and harness only, kept in a gameplay sheet that mods edit.
	stock_mode INTEGER NOT NULL,  -- the game's mode byte (oracle and harness only)
	gate_kind  TEXT NOT NULL REFERENCES tracking_gate(name),
	gate_until INTEGER NOT NULL,
	gate_min_distance INTEGER NOT NULL,
	rate_normal INTEGER NOT NULL, rate_late INTEGER NOT NULL, rate_air INTEGER NOT NULL,
	rate_late_from INTEGER NOT NULL,
	rate_frames INTEGER NOT NULL,
	rate_halving TEXT NOT NULL REFERENCES tracking_halving(name),
	rate_frames_by_distance INTEGER NOT NULL,
	limit_total INTEGER NOT NULL,
	limit_sweep_0 INTEGER NOT NULL, limit_sweep_1 INTEGER NOT NULL, limit_sweep_2 INTEGER NOT NULL, limit_sweep_3 INTEGER NOT NULL,  -- front, left, back, right
	end_move_yaw_when TEXT NOT NULL REFERENCES tracking_when(name),
	end_pivot_when TEXT NOT NULL REFERENCES tracking_when(name),
	end_grace INTEGER NOT NULL,
	end_phase TEXT NOT NULL REFERENCES tracking_phase(name)
);
CREATE INDEX tracking_row_character ON tracking_row(character);

-- Tracking a cancel entry names (cancel.tracking_override).
CREATE TABLE tracking_override (
	key        TEXT PRIMARY KEY,
	character  TEXT NOT NULL REFERENCES motbin(character),
	row        TEXT NOT NULL REFERENCES tracking_row(key),
	far_row    TEXT NOT NULL REFERENCES tracking_row(key),
	far_source TEXT NOT NULL REFERENCES tracking_far_source(name),
	far_angle  INTEGER NOT NULL
);
CREATE INDEX tracking_override_character ON tracking_override(character);

-- Fixed tracking: 0 a carried cancel the sim rewrites to motion code 2, 1 a guarding reaction.
CREATE TABLE tracking_fixed (
	character  TEXT NOT NULL REFERENCES motbin(character),
	slot       INTEGER NOT NULL,
	row        TEXT NOT NULL REFERENCES tracking_row(key),
	far_row    TEXT NOT NULL REFERENCES tracking_row(key),
	far_source TEXT NOT NULL REFERENCES tracking_far_source(name),
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

-- Throw cameras (EBOOT 0x3513f8): a throw's camera category (extra property 0x815f) picks one row by weight (libc rand).
-- A camera is a clip of the global camera bank (anim owner cameras) or a hand-coded shot (ids below 0x67).
-- left_* is used when the thrower is on the left of the screen, right_* on the right; the mirror bits count only on the right.
CREATE TABLE throw_camera (
	category        INTEGER NOT NULL,
	pos             INTEGER NOT NULL,
	weight          INTEGER NOT NULL,
	tracks          TEXT NOT NULL DEFAULT 'cameras',
	left_track      INTEGER,  -- NULL: a coded shot
	left_coded      INTEGER,
	right_track     INTEGER,
	right_coded     INTEGER,
	hold            INTEGER NOT NULL DEFAULT 0,  -- 0x04: keep the camera at least 15 frames
	wide            INTEGER NOT NULL DEFAULT 0,  -- 0x08: coded shots: fov +5, a smaller turn
	wall_check      INTEGER NOT NULL DEFAULT 0,  -- 0x20: both fighters away from a wall, else row 0
	track_target    INTEGER NOT NULL DEFAULT 0,  -- 0x40: the target comes from the track
	aim_at_fighters INTEGER NOT NULL DEFAULT 0,  -- 0x80 without track_target: the target follows the fighters
	mirror_x        INTEGER NOT NULL DEFAULT 0,  -- 0x200, and 0x100 mirror_z: axes of the track as imported (the game's z and x)
	mirror_z        INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (category, pos),
	FOREIGN KEY (tracks, left_track) REFERENCES anim(character, idx),
	FOREIGN KEY (tracks, right_track) REFERENCES anim(character, idx)
);

-- Camera shots of moves (the intro and win poses: property 0x8153). From move frame `frame` on, the track plays one key a
-- frame, placed at the fighter that plays the move.
CREATE TABLE move_camera (
	move   TEXT PRIMARY KEY REFERENCES move(key),
	tracks TEXT NOT NULL,
	track  INTEGER NOT NULL,
	frame  INTEGER NOT NULL,  -- the move frame (1-based) of the track's first key
	FOREIGN KEY (tracks, track) REFERENCES anim(character, idx)
);

-- A fighter's own effects: record n of the character's EFP as an effect def (tk5decomp docs/effects.md section 4).
-- Characters that share a model container share the files.
CREATE TABLE character_effect (
	character TEXT NOT NULL REFERENCES character(id),
	record    INTEGER NOT NULL,
	file      TEXT NOT NULL,  -- effects/<owner>/<record>.fx
	PRIMARY KEY (character, record)
);

-- The character hit table: a heavy clean hit plays row 0, properties 0x8019..0x801d play a row of their own.
CREATE TABLE character_effect_row (
	character TEXT NOT NULL REFERENCES character(id),
	row       INTEGER NOT NULL,  -- 0..15
	records   INTEGER NOT NULL,  -- bit n: record n plays
	sound_row INTEGER NOT NULL,  -- -1: none
	light     INTEGER NOT NULL,  -- 1: record 0's colour also lights the hit point for a moment
	PRIMARY KEY (character, row)
);
