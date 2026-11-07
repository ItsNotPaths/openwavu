// 2D art entries. Names come from the art (data.md §3); the pairs differ by light or colour.
package tk5_formats

Art_Entry :: struct {
	index:  int,
	name:   string,
	screen: bool,  // SWG layout, texture container, small block; else a texture container
}

ART_ENTRIES :: [?]Art_Entry{
	{15, "misc", false}, {22, "ranks_ps2", false}, {23, "ranks", false}, {37, "hud_ps2", false}, {38, "hud", false},
	{260, "boot", true}, {261, "pause", true}, {262, "select", true}, {263, "select_lit", true},
	{264, "main_menu_lit", true}, {265, "main_menu", true}, {266, "vs", true}, {267, "results", true},
	{268, "options", true}, {269, "command_list", true}, {270, "arcade", true}, {271, "loading", true},
	{272, "loading2", true}, {273, "profiles", true}, {274, "gallery", true}, {275, "online_ranks", true},
	{276, "team_battle", true}, {277, "survival_red", true}, {278, "survival_green", true}, {279, "net", true},
	{280, "arcade_vs", true}, {281, "loading_screens", true}, {282, "pacman", true}, {283, "replay", true},
}

// Entries 16..19 hold pairs of sections: an NTP3 page, then its NFH glyph table. A font is a run of pairs.
// Names from the art: 16 and 17 hold the same three faces at PS2 and HD size; their sans pages are the same.
Font_Entry :: struct {
	index:        int,
	name:         string,
	first, pages: int,  // in pairs
}

FONTS :: [?]Font_Entry{
	{16, "sans_ps2", 0, 1}, {16, "bold_ps2", 1, 1}, {16, "wide_ps2", 2, 1},
	{17, "sans", 0, 1}, {17, "bold", 1, 1}, {17, "wide", 2, 1},
	{18, "text", 0, 14},       // Japanese
	{19, "text_big", 0, 36},  // Latin, Cyrillic, Japanese
}

// One 1008x1080 character select render per entry from 1474, named by eye. Mokujin has no character row.
SELECT_RENDERS_FIRST :: 1474

Select_Render :: struct {
	fighter:    string,
	faces_left: bool,  // else right; most fighters have one of each
}

SELECT_RENDERS :: [?]Select_Render{
	{"paul", false}, {"paul", true}, {"law", false}, {"law", true}, {"lei", false},
	{"king", false}, {"king", true}, {"yoshimitsu", false}, {"nina", false}, {"hwoarang", false},
	{"xiaoyu", true}, {"christie", false}, {"jin", false}, {"jin", true}, {"julia", false},
	{"kuma", false}, {"panda", false}, {"bryan", true}, {"bryan", false}, {"heihachi", false},
	{"heihachi", true}, {"kazuya", false}, {"kazuya", true}, {"lee", false}, {"lee", true},
	{"steve", false}, {"steve", true}, {"marduk", false}, {"marduk", true}, {"mokujin", false},
	{"eddy", false}, {"eddy", true}, {"jack5", true}, {"jack5", false}, {"roger", false},
	{"anna", false}, {"wang", false}, {"wang", true}, {"ganryu", false}, {"asuka", false},
	{"bruce", false}, {"baek", false}, {"baek", true}, {"devil_jin", false}, {"devil_jin", true},
	{"raven", false}, {"raven", true}, {"feng", false}, {"armor_king", true}, {"armor_king", false},
	{"lili", false}, {"dragunov", false}, {"dragunov", true}, {"jinpachi", false},
}

// Art inside a screen that belongs to one fighter or stage, named by eye: image ids <kind>/<id> for <screen>/<first + i>.
Art_Names :: struct {
	screen: string,
	first:  int,
	kind:   string,
	ids:    []string,
}

// The fighters in the order of their 3-letter tags (AMK ANN ASK ...), the order of most per-fighter art.
@(private = "file")
TAG_ORDER := []string{
	"armor_king", "anna", "asuka", "baek", "bruce", "bryan", "christie", "dragunov", "devil_jin", "eddy", "feng",
	"ganryu", "heihachi", "hwoarang", "jack5", "jin", "jinpachi", "julia", "kazuya", "king", "kuma", "law", "lee",
	"lei", "lili", "marduk", "mokujin", "nina", "panda", "paul", "raven", "roger", "steve", "wang", "xiaoyu",
	"yoshimitsu",
}

ART_NAMES := [?]Art_Names{
	{"select", 115, "name", TAG_ORDER},
	{"profiles", 0, "profile", {
		"armor_king", "anna", "asuka", "baek", "bruce", "bryan", "christie", "dragunov", "devil_jin", "eddy", "feng",
		"ganryu", "hwoarang", "jack5", "jin", "jinpachi", "julia", "kazuya", "king", "law", "lee", "lei", "lili",
		"marduk", "mokujin", "nina", "paul", "raven", "roger", "steve", "wang", "xiaoyu", "yoshimitsu",
	}},
	// The select grid's order; Panda has no face.
	{"select", 152, "face", {
		"random", "eddy", "baek", "mokujin", "devil_jin", "raven", "asuka", "ganryu", "feng", "wang", "armor_king",
		"jinpachi", "anna", "marduk", "law", "hwoarang", "king", "lili", "dragunov", "heihachi", "christie", "paul",
		"jack5", "bruce", "roger", "lei", "nina", "steve", "kazuya", "xiaoyu", "jin", "lee", "julia", "yoshimitsu",
		"bryan", "kuma",
	}},
	// Matched by look against the stage models; stage_15 and ground_zero are guesses. stage_14 and final_stage have none.
	{"select", 190, "stage", {
		"dragons_nest", "burning_temple", "waterfall", "urban_jungle", "city_at_sunset", "moonlit_wilderness",
		"pirates_cove", "secret_garden", "cathedral", "acid_rain", "polar_paradise", "hells_gate", "the_final_frontier",
		"poolside", "stage_15", "western_gate", "autumn_temple", "meteor_shower", "ghetto_pit", "city_lights",
		"great_plains", "galleon", "all_hallows_eve", "winter_palace", "festival", "aurora_australis", "heavens_gate",
		"space_colony", "pool_party", "wolves_den", "playroom", "industrial_complex", "ominous_mist", "inferno",
		"ground_zero",
	}},
}
