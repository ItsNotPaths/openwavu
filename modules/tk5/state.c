// TK5 state seam: move tick, cancel scan, requirements and properties (code-map §5, §6).
#include "openwavu.h"

// (hole mod-state :tags tk5mod :needs (seam-abi mod-input) :sev blocker) requirements/properties are ported; move tick e509c, main scan e3c08, decide 18f98 and pending resolver 171f8 are not.
OW_EXPORT(ow_state_step) void ow_state_step(OwWorld *w) {}
