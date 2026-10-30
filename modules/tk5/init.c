// TK5 sim init: reads params and loadouts, and loads each side's fighter from the pack database.
#include "openwavu.h"
#include "ow_db.h"

// (hole snapshot-range :tags (tk5mod sim)) mutable state and read-only data (anims, motbin tables) share one range; the module does not export the range to snapshot.
// (hole mod-rounds :tags tk5mod :needs (param-section event-stream)) round flow is not from params: rounds to win, round time, round reset.
// (hole fighter-data-load :tags (tk5mod content) :needs (sdk-sqlite pack-open side-bands-import move-db-edits hit-point-rows tracking-rows body-rows) :sev blocker) moveset rows and .anim files are not read from the pack database into the clean structs.
OW_EXPORT(ow_sim_init) int32_t ow_sim_init(void) {
	return -1;
}
