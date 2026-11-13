// The game's fighter table (FUN_0023ade0 fills 0x66 rows at *0x8e51d4 + 0x158, 0x6c each): a costume is a row, and
// costume requirements compare the row (P+0x5c) or its variant (word 1, FUN_0023a798).
package tk6_convert

import "../../db"
import tk6 "../../formats/tk6"

@(private = "file")
Fighter_Row :: struct {model, chara, variant: u8}  // row words 0, 3, 1

@(private = "file", rodata)
FIGHTER_TABLE := [0x66]Fighter_Row{
	{0, 0, 0}, {0, 0, 1}, {1, 1, 0}, {1, 1, 1}, {2, 2, 0}, {2, 2, 1}, {3, 3, 0}, {3, 3, 1},
	{4, 4, 0}, {4, 4, 1}, {5, 5, 0}, {5, 5, 1}, {6, 6, 0}, {6, 6, 1}, {7, 7, 0}, {7, 7, 1},
	{8, 8, 0}, {8, 8, 1}, {33, 33, 0}, {33, 33, 1}, {9, 9, 0}, {9, 9, 1}, {10, 10, 0}, {10, 10, 1},
	{11, 11, 0}, {11, 32, 1}, {12, 12, 0}, {12, 12, 1}, {13, 13, 0}, {13, 13, 1}, {14, 14, 0}, {14, 14, 1},
	{15, 15, 0}, {15, 15, 1}, {16, 16, 0}, {16, 16, 1}, {17, 17, 0}, {17, 17, 1}, {18, 0, 0}, {18, 0, 1},
	{19, 18, 0}, {19, 18, 1}, {20, 19, 0}, {20, 19, 1}, {21, 20, 0}, {21, 20, 1}, {22, 21, 0}, {22, 21, 1},
	{23, 22, 0}, {23, 22, 1}, {24, 23, 0}, {24, 23, 1}, {25, 24, 0}, {25, 24, 1}, {26, 25, 0}, {26, 25, 1},
	{27, 26, 0}, {27, 26, 1}, {28, 27, 0}, {28, 27, 1}, {29, 28, 0}, {29, 28, 1}, {30, 29, 0}, {30, 29, 1},
	{31, 30, 0}, {31, 30, 1}, {32, 31, 0}, {32, 31, 1}, {38, 38, 0}, {38, 38, 1}, {34, 34, 0}, {34, 34, 1},
	{35, 35, 0}, {35, 35, 1}, {36, 36, 0}, {36, 36, 1}, {37, 37, 0}, {37, 37, 1}, {40, 40, 0}, {40, 40, 1},
	{41, 41, 0}, {41, 41, 1}, {39, 39, 0}, {0, 42, 0}, {0, 42, 0}, {0, 42, 0}, {9, 9, 2}, {14, 14, 2},
	{20, 19, 2}, {21, 20, 2}, {24, 23, 2}, {31, 30, 2}, {35, 35, 2}, {40, 40, 2}, {4, 4, 2}, {26, 25, 2},
	{30, 29, 2}, {3, 3, 2}, {12, 12, 2}, {17, 17, 2}, {7, 7, 2}, {39, 9, 1},
}

// A character's costumes are its rows in table order: costume n is the n-th row with its model and move set id.
write_costume_index :: proc(w: ^db.Writer, character: tk6.Character, costume: int, name: string) {
	seen := 0
	for row, game_index in FIGHTER_TABLE {
		if int(row.model) != character.model || int(row.chara) != character.chara do continue
		if seen == costume {
			db.insert(w, "costume_index", character.id, name, i64(game_index), i64(row.variant))
			return
		}
		seen += 1
	}
}
