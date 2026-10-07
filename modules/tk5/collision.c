// TK5 collision seam: player push, stage walls, floor (code-map §8).
#include "openwavu.h"

// (hole mod-collision :tags tk5mod :needs (seam-abi mod-motion) :sev blocker) player push, walls and floor are not ported.
OW_EXPORT(ow_collision_step) void ow_collision_step(OwWorld *w) {}
