// Stock TK5 presenter (gamerender.wasm): plays the sound and voice cues of the view's cue ring. Outside rollback.
#include "ow_sound.h"

// (hole mod-sound :tags (tk5mod audio effects) :needs (sdk-sound voice-tables) :sev gap) sound, voice, hit, announcer and music cues are not played (id rules: v>>12 selector, tk5decomp data.md 8.4; EFP sound_row goes through effect generators, not dumped); no TK5 channels (one voice per fighter).
OW_EXPORT(ow_sound_step) void ow_sound_step(void) {}
