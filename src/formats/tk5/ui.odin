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
