// Section container used by models, anim banks and stages: LE u32 count; {u32 off, u32 size}[count].
package tk5_formats

sections :: proc(data: []byte, allocator := context.allocator) -> (out: [][]byte, ok: bool) {
	if len(data) < 4 do return nil, false
	count := int(le_u32(data, 0))
	if 4 + count * 8 > len(data) do return nil, false
	out = make([][]byte, count, allocator)
	for &s, i in out {
		off, size := int(le_u32(data, 4 + i * 8)), int(le_u32(data, 8 + i * 8))
		if off + size > len(data) do return nil, false
		s = data[off:][:size]
	}
	return out, true
}

COMMON_ANIMS :: 28
GLOBAL_CAMERAS :: 29  // the throw and hit camera tracks
MOTBIN_FIRST :: 39  // motbin entry = MOTBIN_FIRST + 2 * char id
GROUP_SIZE :: 7     // per costume: slot 0 anim container (first costume), slot 6 model. data.md §3
GROUP_MODEL :: 6
MODEL_COSTUME_BONES :: 3  // model section: block 0 is the costume's bon; section 12 is the base one
MODEL_SWINGS :: 13  // model section: block 0 is the MOP swing joint values
CHAR_GROUPS_END :: 2125  // the last character's groups end here

Character :: struct {
	id, name:  string,
	container: int,  // first group; the costumes follow until the next character's container
	model:     int,  // the body model requirements compare: the char id, shifted past Mokujin's 18; Panda has Kuma's
}

// Index = char id. Kuma and Panda, and both Jinpachi motbins, share a container and a model.
CHARACTERS :: [?]Character{
	{"paul", "Paul", 1528, 0}, {"law", "Marshall Law", 1542, 1}, {"lei", "Lei Wulong", 1563, 2},
	{"king", "King", 1577, 3}, {"yoshimitsu", "Yoshimitsu", 1591, 4}, {"nina", "Nina Williams", 1612, 5},
	{"hwoarang", "Hwoarang", 1626, 6}, {"xiaoyu", "Ling Xiaoyu", 1640, 7}, {"christie", "Christie Monteiro", 1675, 8},
	{"jin", "Jin Kazama", 1703, 9}, {"julia", "Julia Chang", 1724, 10}, {"kuma", "Kuma", 1738, 11},
	{"bryan", "Bryan Fury", 1752, 12}, {"heihachi", "Heihachi Mishima", 1766, 13}, {"kazuya", "Kazuya Mishima", 1780, 14},
	{"lee", "Lee Chaolan", 1794, 15}, {"steve", "Steve Fox", 1815, 16}, {"marduk", "Craig Marduk", 1829, 17},
	{"jack5", "Jack-5", 1857, 19}, {"roger", "Roger Jr.", 1871, 20}, {"anna", "Anna Williams", 1885, 21},
	{"wang", "Wang Jinrei", 1906, 22}, {"ganryu", "Ganryu", 1920, 23}, {"asuka", "Asuka Kazama", 1941, 24},
	{"bruce", "Bruce Irvin", 1969, 25}, {"baek", "Baek Doo San", 1990, 26}, {"devil_jin", "Devil Jin", 2004, 27},
	{"raven", "Raven", 2018, 28}, {"feng", "Feng Wei", 2039, 29}, {"armor_king", "Armor King", 2053, 30},
	{"lili", "Lili", 2067, 31}, {"dragunov", "Sergei Dragunov", 2081, 32}, {"panda", "Panda", 1738, 11},
	{"eddy", "Eddy Gordo", 1689, 33}, {"jinpachi", "Jinpachi Mishima", 2095, 34}, {"jinpachi2", "Jinpachi Mishima (boss)", 2095, 34},
}

// No move set of his own: each round he takes another's (game_index NULL).
MOKUJIN :: Character{"mokujin", "Mokujin", 1843, 18}

// Model groups of the container that starts at `container`.
costume_groups :: proc(container: int) -> (first, count: int) {
	next := CHAR_GROUPS_END
	for c in CHARACTERS do if c.container > container && c.container < next do next = c.container
	if MOKUJIN.container > container && MOKUJIN.container < next do next = MOKUJIN.container
	return container, (next - container) / GROUP_SIZE
}

// The first character that owns `container`; it names the shared anims and parts.
container_owner :: proc(container: int) -> string {
	for c in CHARACTERS do if c.container == container do return c.id
	return ""
}
