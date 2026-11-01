package ui

import clay "../../vendor/clay"

WHEEL_SPEED :: 40

BACKGROUND :: [4]f32{0.07, 0.08, 0.10, 1}
SURFACE    :: clay.Color{28, 31, 38, 255}
RAISED     :: clay.Color{40, 44, 54, 255}
ACCENT     :: clay.Color{230, 70, 60, 255}
TEXT       :: clay.Color{230, 232, 236, 255}
TEXT_DIM   :: clay.Color{140, 146, 158, 255}
BAR_FILL   :: clay.Color{0, 0, 0, 200}

TEXT_SIZE  :: 16
TITLE_SIZE :: 24

BAR_HEIGHT :: 40
TILE_SIZE  :: 180
TILE_GAP   :: 16
PAGE_PAD   :: 32

Button_Style :: struct {
	fill, hover, text: clay.Color,
	padding:           clay.Padding,
	radius:            f32,
	text_size:         u16,
}

BUTTON :: Button_Style {
	fill      = RAISED,
	hover     = {60, 66, 80, 255},
	text      = TEXT,
	padding   = {12, 12, 8, 8},
	radius    = 6,
	text_size = TEXT_SIZE,
}

BAR_BUTTON :: Button_Style {
	fill      = {0, 0, 0, 0},
	hover     = {255, 255, 255, 40},
	text      = TEXT,
	padding   = {12, 12, 8, 8},
	radius    = 4,
	text_size = TEXT_SIZE,
}
