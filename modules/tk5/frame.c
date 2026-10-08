// TK5 frame seam: the battle frame order (0x14fcc); calls the other seams through host imports.
#include "openwavu.h"

// (hole mod-frame :tags tk5mod :needs (seam-abi seam-wiring) :sev blocker) the battle frame order 0x14fcc is not ported (code-map §1, §9).
// (hole replay-oracle :tags tk5mod) no whole-frame check against the game: record pads in RPCS3, compare fighter state per frame (freeplay first).
OW_EXPORT(ow_frame_step) void ow_frame_step(OwWorld *w) {}
