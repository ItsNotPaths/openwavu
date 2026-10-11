// TK5 match seam: round timer, KO, round end, hit stop, per frame (code-map §10).
#include "openwavu.h"

// (hole mod-match :tags tk5mod :needs mod-hit :sev blocker) timer, KO, round end and hit stop are not ported.
// (hole mod-rounds :tags tk5mod :needs (mod-match param-section event-stream)) round flow is not ported: rounds to win, round reset, next round setup, all from params.
OW_EXPORT(ow_match_step) void ow_match_step(OwWorld *w) {}
