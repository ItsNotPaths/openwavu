// Stock TK5 presenter (gamerender.wasm): turns the fx cues in the view's cue ring into scene fx entries. Outside rollback.
#include "openwavu.h"

// (hole mod-effects :tags (tk5mod effects) :needs (fx-draw efp-import cue-ring) :sev gap) no fx entries from cues: effect def per property, anchor, age, seed from the cue counter.
OW_EXPORT(ow_effects_step) void ow_effects_step(void) {}
