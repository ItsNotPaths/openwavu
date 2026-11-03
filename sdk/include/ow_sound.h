// openwavu sound helper: plays a sound once per cue key, on channels the pack defines. Plays through SDL audio
// streams. Sounds are never unplayed: a cue undone by rollback plays out.
#ifndef OW_SOUND_H
#define OW_SOUND_H

#include "openwavu.h"

// (hole sdk-sound :tags (sdk audio) :needs sdl-audio-imports) no sound helper: no key list over the rollback window, no channels (one at a time cuts the old one, or overlap).
static inline void ow_sound_play(uint64_t key, uint32_t channel, OwStr path) {}

#endif
