package ui

import clay "../../vendor/clay"

// Colours are 0xRRGGBBAA, as in docs/launcher-spec.md.

BACKGROUND :: 0x000000ff
LED        :: 0xc4a2ffff
TEXT       :: 0xecebe6ff
TEXT_DIM   :: 0x94969cff
TEXT_OFF   :: 0x5c6372ff
TITLE      :: 0x8790a1ff
FIELD_TEXT :: 0xe8eaeeff
HINT       :: 0x6d7380ff
WARN       :: 0xffb15aff

STEEL_TOP    :: 0x4d5056ff
STEEL_MID    :: 0x393b40ff
STEEL_BOTTOM :: 0x2b2d31ff
BEVEL_HI     :: 0xffffff2c
BEVEL_LO     :: 0x000000b0
RIM          :: 0x050506ff
INSET_TOP    :: 0x08090aff
INSET_BOTTOM :: 0x111215ff
SCREW_HEAD   :: 0x8a8d92ff
SCREW_RING   :: 0x2a2c30ff
LED_OFF      :: 0x1a1a1aff
PLUS         :: 0x3a3f4bff

GRAIN_TILE  :: 160
GRAIN_ALPHA :: 0.10

WHEEL_SPEED :: 40

TEXT_SIZE   :: 15
TITLE_SIZE  :: 28
HEAD_SIZE   :: 18
COLUMN_SIZE :: 12
PLATE_SIZE  :: 13
PLUS_SIZE   :: 54

BAR_HEIGHT  :: 40
BAR_REVEAL  :: 60
BAR_RATE    :: 17

COLUMN_WIDTH :: 212
SEARCH_HEIGHT :: 38
ROW_HEIGHT    :: 30
FIELD_PAD     :: 12
SLOT_GAP     :: 18

SLOT       :: 180
SLOT_FRAME :: 16
SLOT_LIFT  :: 3
LIFT_RATE  :: 21
UNDERSIDE  :: 5
WINDOW_H   :: SLOT - SLOT_FRAME - 38
PLATE_H    :: 20

Face :: enum u8 {
	None,
	Raised,
	Recessed,
}

Button_Style :: struct {
	face, hover:        Face,
	text:               u32,
	padding:            clay.Padding,
	height:             f32,
	text_size:          u16,
}

BUTTON :: Button_Style {
	face      = .Raised,
	hover     = .Raised,
	text      = TEXT,
	padding   = {18, 18, 0, 0},
	height    = 38,
	text_size = TEXT_SIZE,
}

BAR_BUTTON :: Button_Style {
	face      = .None,
	hover     = .Recessed,
	text      = TEXT,
	padding   = {12, 12, 0, 0},
	height    = 30,
	text_size = TEXT_SIZE,
}

// The off look, for buttons that do nothing right now.
OFF_BUTTON :: Button_Style {
	face      = .Recessed,
	hover     = .Recessed,
	text      = TEXT_OFF,
	padding   = {18, 18, 0, 0},
	height    = 38,
	text_size = TEXT_SIZE,
}

color :: proc(c: u32) -> [4]f32 {
	return {f32(c >> 24), f32(c >> 16 & 0xff), f32(c >> 8 & 0xff), f32(c & 0xff)} / 255
}

clay_color :: proc(c: u32) -> clay.Color {
	return color(c) * 255
}
