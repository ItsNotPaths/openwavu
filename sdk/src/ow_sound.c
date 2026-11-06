// The SDK sound helper: FLAC through dr_flac, played on SDL audio streams (the pack's SDL imports).
#include <stdlib.h>
#include <string.h>
#include <SDL3/SDL_audio.h>

#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_OGG
#include "../../vendor/dr_flac/dr_flac.h"

#include "ow_sound.h"

enum { MIX_RATE = 48000 };  // sounds play stereo float at this rate; other rates go through the frequency ratio
static const SDL_AudioSpec MIX_SPEC = {SDL_AUDIO_F32, 2, MIX_RATE};

static uint32_t next_number;

static SDL_AudioStream *open_stream(const SDL_AudioSpec *spec) {
	SDL_AudioStream *stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, spec, NULL, NULL);
	if (stream != NULL) SDL_ResumeAudioStreamDevice(stream);
	return stream;
}

bool ow_sound_channel_open(OwSoundChannel *channel, uint32_t voices) {
	*channel = (OwSoundChannel){.voices = voices};
	for (uint32_t voice = 0; voice < voices; voice++) {
		channel->streams[voice] = open_stream(&MIX_SPEC);
		if (channel->streams[voice] == NULL) {
			ow_sound_channel_close(channel);
			return false;
		}
	}
	return true;
}

void ow_sound_channel_close(OwSoundChannel *channel) {
	for (uint32_t voice = 0; voice < channel->voices; voice++) {
		if (channel->streams[voice] != NULL) SDL_DestroyAudioStream(channel->streams[voice]);
	}
	*channel = (OwSoundChannel){0};
}

// An idle voice, else the next in turn: the oldest.
static SDL_AudioStream *free_voice(OwSoundChannel *channel) {
	for (uint32_t voice = 0; voice < channel->voices; voice++) {
		if (SDL_GetAudioStreamQueued(channel->streams[voice]) == 0) return channel->streams[voice];
	}
	SDL_AudioStream *oldest = channel->streams[channel->next];
	channel->next = (channel->next + 1) % channel->voices;
	return oldest;
}

// The whole file in memory, owned by the caller; NULL when it is missing.
static void *read_file(OwStr path, int32_t *size) {
	*size = ow_content_size(path);
	if (*size <= 0) return NULL;
	void *bytes = malloc((size_t)*size);
	if (bytes != NULL && ow_content_read(path, 0, bytes, (uint32_t)*size) != *size) {
		free(bytes);
		return NULL;
	}
	return bytes;
}

// Mono or stereo samples to the mix's stereo, with the tone's volume and pan.
static float *to_mix(const float *samples, uint32_t channels, uint64_t frames, OwSoundTone tone) {
	float *mixed = malloc(frames * 2 * sizeof(float));
	if (mixed == NULL) return NULL;
	float left = tone.volume * (tone.pan > 0 ? 1 - tone.pan : 1);
	float right = tone.volume * (tone.pan < 0 ? 1 + tone.pan : 1);
	for (uint64_t frame = 0; frame < frames; frame++) {
		const float *in = &samples[frame * channels];
		mixed[frame * 2] = in[0] * left;
		mixed[frame * 2 + 1] = in[channels - 1] * right;
	}
	return mixed;
}

bool ow_sound_play(OwSoundChannel *channel, OwStr path, OwSoundTone tone) {
	if (channel->voices == 0) return true;
	int32_t size;
	void *file = read_file(path, &size);
	if (file == NULL) return false;
	unsigned channels, rate;
	drflac_uint64 frames;
	float *samples = drflac_open_memory_and_read_pcm_frames_f32(file, (size_t)size, &channels, &rate, &frames, NULL);
	free(file);
	if (samples == NULL) return false;
	float *mixed = to_mix(samples, channels, frames, tone);
	drflac_free(samples, NULL);
	if (mixed == NULL) return false;
	SDL_AudioStream *stream = free_voice(channel);
	SDL_ClearAudioStream(stream);
	SDL_SetAudioStreamFrequencyRatio(stream, (float)rate / MIX_RATE * tone.pitch);
	SDL_PutAudioStreamData(stream, mixed, (int)(frames * 2 * sizeof(float)));
	free(mixed);
	return true;
}

void ow_sound_stop(OwSoundChannel *channel) {
	for (uint32_t voice = 0; voice < channel->voices; voice++) SDL_ClearAudioStream(channel->streams[voice]);
}

bool ow_sound_take(uint32_t number) {
	if (number < next_number) return false;
	next_number = number + 1;
	return true;
}

void ow_sound_skip_to(uint32_t next) { next_number = next; }

static OwStr music_path(const OwMusic *music) { return (OwStr){music->path_len, music->path}; }

static size_t music_read(void *user, void *buffer, size_t bytes) {
	OwMusic *music = user;
	int32_t got = ow_content_read(music_path(music), music->offset, buffer, (uint32_t)bytes);
	if (got <= 0) return 0;
	music->offset += (uint32_t)got;
	return (size_t)got;
}

static drflac_bool32 music_seek(void *user, int offset, drflac_seek_origin origin) {
	OwMusic *music = user;
	int64_t base = origin == DRFLAC_SEEK_SET ? 0 : origin == DRFLAC_SEEK_CUR ? music->offset : ow_content_size(music_path(music));
	if (base + offset < 0) return DRFLAC_FALSE;
	music->offset = (uint32_t)(base + offset);
	return DRFLAC_TRUE;
}

static drflac_bool32 music_tell(void *user, drflac_int64 *cursor) {
	*cursor = ((OwMusic *)user)->offset;
	return DRFLAC_TRUE;
}

bool ow_music_start(OwMusic *music, OwStr path, uint64_t loop_start, uint64_t loop_length) {
	ow_music_stop(music);
	if (path.len > OW_MUSIC_PATH_BYTES) return false;
	memcpy(music->path, path.data, path.len);
	music->path_len = path.len;
	drflac *decoder = drflac_open(music_read, music_seek, music_tell, music, NULL);
	if (decoder == NULL) return false;
	SDL_AudioSpec spec = {SDL_AUDIO_F32, decoder->channels, (int)decoder->sampleRate};
	music->stream = open_stream(&spec);
	if (music->stream == NULL) {
		drflac_close(decoder);
		return false;
	}
	music->decoder = decoder;
	music->loop_start = loop_start;
	music->loop_end = loop_length > 0 ? loop_start + loop_length : 0;
	music->gain = 1;
	return true;
}

enum { MUSIC_CHUNK = 4096 };  // PCM frames decoded at a time

// Half a second ahead, so a slow frame never runs it dry.
static void feed(OwMusic *music) {
	drflac *decoder = music->decoder;
	int frame_bytes = (int)(decoder->channels * sizeof(float));
	int ahead = (int)decoder->sampleRate / 2 * frame_bytes;
	static float chunk[MUSIC_CHUNK * 2];
	while (SDL_GetAudioStreamQueued(music->stream) < ahead) {
		uint64_t want = MUSIC_CHUNK;
		if (music->loop_end > 0 && decoder->currentPCMFrame + want > music->loop_end) want = music->loop_end - decoder->currentPCMFrame;
		uint64_t got = drflac_read_pcm_frames_f32(decoder, want, chunk);
		if (got > 0) SDL_PutAudioStreamData(music->stream, chunk, (int)got * frame_bytes);
		bool at_loop_end = music->loop_end > 0 && decoder->currentPCMFrame >= music->loop_end;
		if (at_loop_end ? !drflac_seek_to_pcm_frame(decoder, music->loop_start) : got == 0) return;  // played to the end
	}
}

void ow_music_step(OwMusic *music, float seconds) {
	if (music->stream == NULL) return;
	if (music->fade > 0) {
		music->gain -= music->fade * seconds;
		if (music->gain <= 0) {
			ow_music_stop(music);
			return;
		}
		SDL_SetAudioStreamGain(music->stream, music->gain);
	}
	feed(music);
}

void ow_music_fade(OwMusic *music, float seconds) {
	if (seconds <= 0) ow_music_stop(music);
	else if (music->stream != NULL) music->fade = music->gain / seconds;
}

void ow_music_stop(OwMusic *music) {
	if (music->stream != NULL) SDL_DestroyAudioStream(music->stream);
	if (music->decoder != NULL) drflac_close(music->decoder);
	*music = (OwMusic){0};
}
