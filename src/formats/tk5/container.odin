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
MOTBIN_FIRST :: 39  // motbin entry = MOTBIN_FIRST + 2 * char id
GROUP_SIZE :: 7     // per costume: slot 0 anim container (first costume), slot 6 model. data.md §3
GROUP_MODEL :: 6
CHAR_GROUPS_END :: 2125  // the last character's groups end here

Character :: struct {
	id, name:  string,
	container: int,  // first group; the costumes follow until the next character's container
}

// Index = char id. Kuma and Panda, and both Jinpachi motbins, share a container.
CHARACTERS :: [?]Character{
	{"paul", "Paul", 1528}, {"law", "Marshall Law", 1542}, {"lei", "Lei Wulong", 1563},
	{"king", "King", 1577}, {"yoshimitsu", "Yoshimitsu", 1591}, {"nina", "Nina Williams", 1612},
	{"hwoarang", "Hwoarang", 1626}, {"xiaoyu", "Ling Xiaoyu", 1640}, {"christie", "Christie Monteiro", 1675},
	{"jin", "Jin Kazama", 1703}, {"julia", "Julia Chang", 1724}, {"kuma", "Kuma", 1738},
	{"bryan", "Bryan Fury", 1752}, {"heihachi", "Heihachi Mishima", 1766}, {"kazuya", "Kazuya Mishima", 1780},
	{"lee", "Lee Chaolan", 1794}, {"steve", "Steve Fox", 1815}, {"marduk", "Craig Marduk", 1829},
	{"jack5", "Jack-5", 1857}, {"roger", "Roger Jr.", 1871}, {"anna", "Anna Williams", 1885},
	{"wang", "Wang Jinrei", 1906}, {"ganryu", "Ganryu", 1920}, {"asuka", "Asuka Kazama", 1941},
	{"bruce", "Bruce Irvin", 1969}, {"baek", "Baek Doo San", 1990}, {"devil_jin", "Devil Jin", 2004},
	{"raven", "Raven", 2018}, {"feng", "Feng Wei", 2039}, {"armor_king", "Armor King", 2053},
	{"lili", "Lili", 2067}, {"dragunov", "Sergei Dragunov", 2081}, {"panda", "Panda", 1738},
	{"eddy", "Eddy Gordo", 1689}, {"jinpachi", "Jinpachi Mishima", 2095}, {"jinpachi2", "Jinpachi Mishima (boss)", 2095},
}

// Model groups of the container that starts at `container`.
costume_groups :: proc(container: int) -> (first, count: int) {
	next := CHAR_GROUPS_END
	for c in CHARACTERS do if c.container > container && c.container < next do next = c.container
	return container, (next - container) / GROUP_SIZE
}

// The first character that owns `container`; it names the shared anims and parts.
container_owner :: proc(container: int) -> string {
	for c in CHARACTERS do if c.container == container do return c.id
	return ""
}
