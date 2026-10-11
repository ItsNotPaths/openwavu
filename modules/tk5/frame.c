// TK5 frame seam: the battle frame order (0x14fcc). Calls the other seams through the hook table,
// whose defaults are the ports; a pack's sim sets its own hooks at init.
#include "openwavu.h"

// (hole tk5-hooks :tags (tk5mod sdk)) no hook table: the seams are not reachable as overridable function pointers with exported defaults.
// (hole snapshot-range :tags (tk5mod sim)) mutable state and read-only data (anims, motbin tables) share one range; the module does not export the range to snapshot.
// (hole mod-frame :tags tk5mod :needs tk5-hooks :sev blocker) the battle frame order 0x14fcc is not ported (code-map §1, §9).
// (hole replay-oracle :tags tk5mod) no whole-frame check against the game: record pads in RPCS3, compare fighter state per frame (freeplay first).
OW_EXPORT(ow_frame_step) void ow_frame_step(OwWorld *w) {}
