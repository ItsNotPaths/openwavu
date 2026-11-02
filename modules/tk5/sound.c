// Stock TK5 presenter (gamerender.wasm): plays the sound and voice cues of the view's cue ring. Outside rollback.
#include "ow_sound.h"

// (hole mod-sound :tags (tk5mod audio) :needs (sdk-sound cue-ring) :sev gap) sound and voice cues are not played; no TK5 channels (one voice per fighter).
OW_EXPORT(ow_sound_step) void ow_sound_step(void) {}
