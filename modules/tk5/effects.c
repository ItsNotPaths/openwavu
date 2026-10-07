// TK5 effects seam: sparks, trails, hit flashes. Presentation: outside rollback.
#include "openwavu.h"

// (hole mod-effects :tags tk5mod :needs (render-api event-stream) :sev gap) no default effects module; TK5 effect data (EFP, character slot +2) is not decoded.
OW_EXPORT(ow_effects_step) void ow_effects_step(OwWorld *w) {}
