// A presentation module that plays music at half gain through the host's SDL imports (tests/sdl_test.odin).
#include <SDL3/SDL.h>
#include "openwavu.h"

static const SDL_AudioSpec SPEC = {SDL_AUDIO_F32, 2, 48000};

OW_EXPORT(music) int music(void) {
    SDL_AudioStream *stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &SPEC, NULL, NULL);
    if (stream == NULL) return 0;
    ow_sound_kind(stream, OW_SOUND_MUSIC);
    return SDL_SetAudioStreamGain(stream, 0.5f);
}
