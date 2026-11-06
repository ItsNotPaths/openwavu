// openwavu sound helper (libow_sound.a): plays the pack's FLAC files on SDL audio streams. Each cue number plays once, and
// sounds are never unplayed: a cue undone by rollback plays out (docs/app.md).
#ifndef OW_SOUND_H
#define OW_SOUND_H

#include <stdbool.h>
#include "openwavu.h"

typedef struct SDL_AudioStream SDL_AudioStream;

enum { OW_SOUND_VOICES = 8 };  // the most sounds one channel plays at once

// Sounds that share a mix. With 1 voice a new sound cuts the old one; with more they overlap, and when all are busy the
// new one cuts the oldest.
typedef struct {
	SDL_AudioStream *streams[OW_SOUND_VOICES];
	uint32_t voices, next;
} OwSoundChannel;

// volume: a gain, 1 = as recorded. pan: -1 left to 1 right. pitch: a rate, 1 = as recorded.
typedef struct {
	float volume, pan, pitch;
} OwSoundTone;
#define OW_SOUND_PLAIN ((OwSoundTone){1, 0, 1})

// voices: 1 to OW_SOUND_VOICES. False when there is no sound device; plays on the channel then do nothing.
bool ow_sound_channel_open(OwSoundChannel *channel, uint32_t voices);
void ow_sound_channel_close(OwSoundChannel *channel);
// Plays a FLAC file of the pack; false when it is missing or not FLAC.
bool ow_sound_play(OwSoundChannel *channel, OwStr path, OwSoundTone tone);
// Cuts every sound of the channel.
void ow_sound_stop(OwSoundChannel *channel);

// True once per cue number: false for a number at or below one taken before. Cue numbers count up.
bool ow_sound_take(uint32_t number);
// After a replay seek: the numbers below next count as taken.
void ow_sound_skip_to(uint32_t next);

enum { OW_MUSIC_PATH_BYTES = 256 };

// One track, decoded while it plays. Keep it in one place: the decoder reads through it.
typedef struct {
	SDL_AudioStream *stream;  // NULL: no track
	void *decoder;
	char path[OW_MUSIC_PATH_BYTES];
	uint32_t path_len, offset;
	uint64_t loop_start, loop_end;  // PCM frames; loop_end 0: plays once
	float gain, fade;               // fade: gain lost per second
} OwMusic;

// Starts a track in place of the current one. loop_length 0: plays once.
bool ow_music_start(OwMusic *music, OwStr path, uint64_t loop_start, uint64_t loop_length);
// Keeps the stream fed and the fade going; call every frame.
void ow_music_step(OwMusic *music, float seconds);
// Fades out over seconds, then stops.
void ow_music_fade(OwMusic *music, float seconds);
void ow_music_stop(OwMusic *music);

#endif
