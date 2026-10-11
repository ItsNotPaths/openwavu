// TK5 sim init: reads params and loadouts, and loads each side's fighter from the pack database.
#include "openwavu.h"
#include "ow_db.h"

// (hole fighter-data-load :tags (tk5mod content) :needs (sdk-sqlite pack-open) :sev blocker) moveset rows and .anim files are not read from the pack database into the clean structs.
OW_EXPORT(ow_sim_init) int32_t ow_sim_init(void) {
	return -1;
}
