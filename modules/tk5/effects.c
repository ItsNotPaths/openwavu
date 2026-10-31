// TK5 fx helper (SDK): maps move effect data to keyed ow_fx_spawn calls from the sim.
#include "openwavu.h"

// (hole mod-effects :tags tk5mod :needs (fx-api efp-import) :sev gap) moves do not spawn the imported TK5 effects through cues.
OW_EXPORT(ow_effects_step) void ow_effects_step(void) {}
