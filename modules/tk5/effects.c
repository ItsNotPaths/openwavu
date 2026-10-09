// TK5 fx helper (SDK): maps move effect data to keyed ow_fx_spawn calls from the sim.
#include "openwavu.h"

// (hole mod-effects :tags tk5mod :needs fx-api :sev gap) TK5 effect data (EFP, character slot +2) is not decoded to effect defs, and moves do not spawn them.
OW_EXPORT(ow_effects_step) void ow_effects_step(OwWorld *w) {}
