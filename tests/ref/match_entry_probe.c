// An entry module that asks for matches and reads the host view (tests/match_test.odin).
#include <string.h>
#include "openwavu.h"

typedef struct { char character[32]; uint32_t costume; } Loadout;  // modules/tk5/loadout.h

static int32_t ask(OwStr mode, OwStr params) {
    Loadout sides[2] = {{"paul", 1}, {"kazuya", 1}};
    return ow_match_local(mode.data, mode.len, 0b11, &sides[0], sizeof sides[0], &sides[1], sizeof sides[1], params.data, params.len);
}

OW_EXPORT(ow_init) int32_t init(void) { return 0; }
OW_EXPORT(ow_frame) void frame(float dt, uint32_t cmdbuf) {}
OW_EXPORT(ask_versus) int32_t ask_versus(void) { return ask(OW_STR("versus"), OW_STR("stage=dragons_nest rounds=2")); }
OW_EXPORT(ask_locked) int32_t ask_locked(void) { return ask(OW_STR("versus"), OW_STR("time=30")); }
OW_EXPORT(ask_not_a_number) int32_t ask_not_a_number(void) { return ask(OW_STR("versus"), OW_STR("rounds=nan")); }
OW_EXPORT(ask_out_of_range) int32_t ask_out_of_range(void) { return ask(OW_STR("versus"), OW_STR("rounds=9")); }
OW_EXPORT(ask_unknown_mode) int32_t ask_unknown_mode(void) { return ask(OW_STR("story"), OW_STR("")); }
// The host view's match phase * 10 + its winner + 1, or -1 when the version or size is wrong.
OW_EXPORT(read_view) int32_t read_view(void) {
    OwHostView v;
    if (ow_host_view(&v, sizeof v) != sizeof v || v.version != OW_HOST_VIEW_VERSION || v.size != sizeof v) return -1;
    return v.match * 10 + v.winner + 1;
}
OW_EXPORT(ask_bad_params) int32_t ask_bad_params(void) { return ask(OW_STR("versus"), OW_STR("stage=far rounds")); }

// The exposed params as pack.toml declares them, by name: count * 100, 10 for rounds' kind and limits, 1 for stage's
// default.
OW_EXPORT(read_exposed) int32_t read_exposed(void) {
    OwParamInfo params[4];
    int32_t count = ow_exposed_params(params, 4);
    if (count != 2) return count * 100;
    bool rounds = strcmp(params[0].name, "rounds") == 0 && params[0].kind == OW_PARAM_NUMBER && params[0].min == 1 && params[0].max == 5;
    bool stage = strcmp(params[1].name, "stage") == 0 && params[1].kind == OW_PARAM_TEXT && strcmp(params[1].fallback, "acid_rain") == 0;
    return count * 100 + rounds * 10 + stage;
}
