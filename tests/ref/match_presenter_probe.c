// A presenter (tests/match_test.odin): counts the frames whose sim view starts with the TK5 view version.
#include "openwavu.h"

static int32_t views;

OW_EXPORT(ow_init) int32_t init(void) { return 0; }
OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {
    static uint32_t view[1024];
    if (ow_view(view, sizeof view) >= 4 && view[0] == 1) views++;
}
OW_EXPORT(views) int32_t views_seen(void) { return views; }
