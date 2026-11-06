// A presenter (tests/match_test.odin): counts the frames whose sim view starts with the TK5 view version.
#include "openwavu.h"
#include "view.h"

static int32_t views;

OW_EXPORT(ow_init) int32_t init(void) { return 0; }
OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {
    uint32_t version;  // the view's first field
    if (ow_view(&version, sizeof version) >= 4 && version == T5_VIEW_VERSION) views++;
}
OW_EXPORT(views) int32_t views_seen(void) { return views; }
