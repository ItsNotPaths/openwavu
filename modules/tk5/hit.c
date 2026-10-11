// TK5 hit seam: hit detection and resolution, reactions, juggles, throws (code-map §9, §10).
#include "openwavu.h"

// (hole mod-hit :tags tk5mod :needs (mod-pose mod-state throw-resolution) :sev blocker) detection is ported in tk5decomp (0x17700, 0x17a4c, 0x413a8) but not wired; strike resolution 0x17bd4 (reactions, damage, pushback, juggles, hit stop) is not ported.
// (hole throw-resolution :tags tk5mod :needs embedded-anims :sev blocker) throws are not ported: break window (input history), paired moves on thrower and receiver, position lock, damage.





OW_EXPORT(ow_hit_step) void ow_hit_step(OwWorld *w) {}
