// TK5 state seam: move tick, cancel scan, requirements and properties (code-map §5, §6).
#include "openwavu.h"

// (hole property-fallback :tags (tk5mod mech) :needs tk5-hooks) property and requirement ids the game does not know do not go to a pack hook.

// (hole mod-state :tags tk5mod :needs mod-input :sev blocker) tk5decomp seam_state.c holds requirements/properties and the freeplay no-contact lifecycle; move tick e509c, main scan e3c08, decide 18f98 and pending resolver 171f8 are not.













OW_EXPORT(ow_state_step) void ow_state_step(OwWorld *w) {}
