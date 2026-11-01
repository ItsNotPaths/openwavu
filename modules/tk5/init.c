// TK5 sim init: reads params and loadouts, and loads each side's fighter from the pack database.
#include "openwavu.h"
#include "ow_db.h"

// (hole snapshot-range :tags (tk5mod sim)) mutable state and read-only data (anims, motbin tables) share one range; the module does not export the range to snapshot.
// (hole mod-rounds :tags tk5mod :needs (param-section event-stream)) round flow is not from params: rounds to win, round time, round reset.
// (hole fighter-data-load :tags (tk5mod content) :needs (sdk-sqlite pack-open) :sev blocker) init does not load fighters: load.c reads the move tables, but nothing calls it, and the skeleton rows and .anim files are not read; the sim still parses tk5decomp's .t5m/.t5a/.t5b (drop those parsers and the Python installers once the db path holds the gates).
OW_EXPORT(ow_sim_init) int32_t ow_sim_init(void) {
	return -1;
}
