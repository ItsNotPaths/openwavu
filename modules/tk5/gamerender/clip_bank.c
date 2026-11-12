#include "gamerender/clip_bank.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CGLTF_IMPLEMENTATION
#include "cgltf.h"
#include "sqlite3.h"

static const float MM_PER_METRE = 1000.0f;

static const char *fail(const char *owner, const char *what) {
    static char message[256];
    snprintf(message, sizeof message, "clips %s: %s", owner, what);
    return message;
}

// The bank file's path; false without a row.
static bool bank_file(sqlite3 *db, const char *owner, char *file, size_t file_bytes) {
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT file FROM clip_bank WHERE owner = ?1", -1, &rows, NULL) != SQLITE_OK) return false;
    sqlite3_bind_text(rows, 1, owner, -1, SQLITE_STATIC);
    bool found = sqlite3_step(rows) == SQLITE_ROW;
    if (found) snprintf(file, file_bytes, "%s", (const char *)sqlite3_column_text(rows, 0));
    sqlite3_finalize(rows);
    return found;
}

static bool track_of(const cgltf_animation_channel *channel, T5ClipTrack *track) {
    static const struct { cgltf_animation_path_type type; T5ClipPath path; } PATHS[] = {
        {cgltf_animation_path_type_rotation, CLIP_ROTATION},
        {cgltf_animation_path_type_translation, CLIP_TRANSLATION},
        {cgltf_animation_path_type_scale, CLIP_SCALE},
    };
    unsigned joint;
    if (!channel->target_node || !channel->target_node->name || sscanf(channel->target_node->name, "bone%u", &joint) != 1) return false;
    for (size_t at = 0; at < sizeof PATHS / sizeof *PATHS; at++)
        if (PATHS[at].type == channel->target_path) {
            *track = (T5ClipTrack){(uint16_t)joint, PATHS[at].path};
            return true;
        }
    return false;
}

// Tightly packed floats, one key a frame.
static const float *keys_of(const cgltf_animation_channel *channel, T5ClipPath path, cgltf_size frames) {
    const cgltf_accessor *output = channel->sampler->output;
    cgltf_type type = path == CLIP_ROTATION ? cgltf_type_vec4 : cgltf_type_vec3;
    if (output->component_type != cgltf_component_type_r_32f || output->type != type || output->count != frames) return NULL;
    if (output->stride != cgltf_num_components(type) * sizeof(float) || !output->buffer_view || !output->buffer_view->buffer->data) return NULL;
    const cgltf_buffer_view *view = output->buffer_view;
    return (const float *)((const uint8_t *)view->buffer->data + view->offset + output->offset);
}

// Every clip must have the first clip's tracks, in order.
static const char *read_bank(T5ClipBank *bank, const cgltf_data *data) {
    if (data->animations_count == 0) return "no clips";
    uint32_t track_count = (uint32_t)data->animations[0].channels_count, clip_count = (uint32_t)data->animations_count;
    size_t bytes = track_count * sizeof(T5ClipTrack) + clip_count * sizeof(uint16_t) + clip_count * track_count * sizeof(float *);
    uint8_t *block = malloc(bytes);
    if (!block) return "out of memory";
    *bank = (T5ClipBank){track_count, clip_count, (T5ClipTrack *)block};
    bank->keys = (const float **)(block + track_count * sizeof(T5ClipTrack));
    bank->frame_counts = (uint16_t *)(bank->keys + clip_count * track_count);
    for (uint32_t clip = 0; clip < clip_count; clip++) {
        const cgltf_animation *animation = &data->animations[clip];
        if (animation->channels_count != track_count) return "clips with other tracks";
        cgltf_size frames = track_count ? animation->channels[0].sampler->input->count : 0;
        if (frames == 0 || frames > UINT16_MAX) return "a clip without keys";
        bank->frame_counts[clip] = (uint16_t)frames;
        for (uint32_t track = 0; track < track_count; track++) {
            T5ClipTrack seen;
            if (!track_of(&animation->channels[track], &seen)) return "a track on no bone";
            if (clip == 0) bank->tracks[track] = seen;
            else if (seen.joint != bank->tracks[track].joint || seen.path != bank->tracks[track].path) return "clips with other tracks";
            const float *keys = keys_of(&animation->channels[track], seen.path, frames);
            if (!keys) return "keys not packed floats";
            bank->keys[clip * track_count + track] = keys;
        }
    }
    return NULL;
}

const char *t5_load_clip_bank(T5ClipBank *bank, sqlite3 *db, const char *owner, T5ReadFile read, void *context) {
    *bank = (T5ClipBank){0};
    char file[256];
    if (!bank_file(db, owner, file, sizeof file)) return NULL;
    T5Bytes bytes = read(context, file);
    cgltf_options options = {0};
    cgltf_data *data = NULL;
    if (cgltf_parse(&options, bytes.data, bytes.size, &data) != cgltf_result_success) return fail(owner, "not a glTF file");
    const char *failed = "no keys";
    if (data->buffers_count == 1 && !data->buffers[0].uri && data->bin && data->bin_size >= data->buffers[0].size) {
        data->buffers[0].data = (void *)data->bin;  // the glb's own chunk; cgltf_load_buffers would link file reads
        failed = read_bank(bank, data);
    }
    cgltf_free(data);
    if (!failed) return NULL;
    t5_free_clip_bank(bank);
    return fail(owner, failed);
}

void t5_free_clip_bank(T5ClipBank *bank) {
    free(bank->tracks);
    *bank = (T5ClipBank){0};
}

int32_t t5_clip_track(const T5ClipBank *bank, uint16_t joint, T5ClipPath path) {
    for (uint32_t track = 0; track < bank->track_count; track++)
        if (bank->tracks[track].joint == joint && bank->tracks[track].path == path) return (int32_t)track;
    return -1;
}

uint16_t t5_clip_frames(const T5ClipBank *bank, uint16_t clip) {
    if (bank->clip_count == 0) return 0;
    return bank->frame_counts[clip < bank->clip_count ? clip : 0];
}

// glTF keeps the rotation's matrix the other way round from the sim: the sim's turn is the conjugate.
T5Vec4 t5_clip_key(const T5ClipBank *bank, uint16_t clip, uint32_t track, int32_t frame) {
    if (clip >= bank->clip_count) clip = 0;
    uint16_t frames = t5_clip_frames(bank, clip);
    if (frames == 0 || track >= bank->track_count) return (T5Vec4){{0, 0, 0, 1}};
    if (frame < 0) frame = 0;
    if (frame >= frames) frame = frames - 1;
    const float *keys = bank->keys[clip * bank->track_count + track];
    switch (bank->tracks[track].path) {
    case CLIP_ROTATION: keys += 4 * frame; return (T5Vec4){{-keys[0], -keys[1], -keys[2], keys[3]}};
    case CLIP_TRANSLATION: keys += 3 * frame; return (T5Vec4){{keys[0] * MM_PER_METRE, keys[1] * MM_PER_METRE, keys[2] * MM_PER_METRE, 1}};
    case CLIP_SCALE: keys += 3 * frame; return (T5Vec4){{keys[0], keys[1], keys[2], 1}};
    }
    return (T5Vec4){{0, 0, 0, 1}};
}
