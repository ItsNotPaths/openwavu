// Stock TK5 presenter (gamerender.wasm): the match's look. Each frame reads the sim view, sends the scene and draws the
// HUD over it.
#include "gamerender/presenter.h"

static T5View view;

static bool read_view(void) {
    return ow_view(&view, sizeof view) == (int32_t)sizeof view && view.version == T5_VIEW_VERSION;
}

OW_EXPORT(ow_init) int32_t init(void) {
    return read_view() && t5_scene_init(&view) ? 0 : 1;
}

OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {
    if (!read_view()) return;
    t5_scene_send(&view, dt);
    t5_hud_draw(&view);
}
