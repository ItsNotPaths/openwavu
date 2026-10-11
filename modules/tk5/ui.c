// Stock TK5 app: menus and HUD. Outside rollback; reads the sim view.
#include "openwavu.h"

// (hole mod-ui :tags tk5mod :needs (render-api sim-view) :sev gap) no stock HUD: health, timer, round marks.
// (hole mod-menus :tags tk5mod :needs (sdk-ui app-host) :sev gap) no stock menus: main menu, server and lobby lists, character select, customization.
OW_EXPORT(ow_ui_step) void ow_ui_step(void) {}
