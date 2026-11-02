// Stock TK5 presenter (gamerender.wasm): the HUD. Outside rollback; reads the sim view.
#include "openwavu.h"

// (hole mod-ui :tags tk5mod :needs (sdl-imports sim-view) :sev gap) no stock HUD: health, timer, round marks.
OW_EXPORT(ow_hud_step) void ow_hud_step(void) {}
