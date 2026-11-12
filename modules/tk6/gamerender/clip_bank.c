#include "gamerender/clip_bank.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CGLTF_IMPLEMENTATION
#include "cgltf.h"
#include "sim/quat.h"
#include "sqlite3.h"

static const float MM_PER_METRE = 1000.0f;

// glTF keeps the rotation's matrix the other way round from the sim: the sim's turn is the conjugate.
static T6Vec4 sim_turn(const float rotation[4]) { return (T6Vec4){{-rotation[0], -rotation[1], -rotation[2], rotation[3]}}; }

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

static int32_t joint_of(const cgltf_node *node) {
    unsigned joint;
    return node && node->name && sscanf(node->name, "bone%u", &joint) == 1 ? (int32_t)joint : -1;
}

// Joints the file does not name keep an identity bind under no parent.
static const char *read_joints(T6ClipBank *bank, const cgltf_data *data) {
    uint32_t joint_count = 0;
    for (cgltf_size node = 0; node < data->nodes_count; node++)
        if (joint_of(&data->nodes[node]) >= (int32_t)joint_count) joint_count = (uint32_t)joint_of(&data->nodes[node]) + 1;
    bank->joints = malloc(joint_count * sizeof *bank->joints);
    if (!bank->joints) return "out of memory";
    bank->joint_count = joint_count;
    for (uint32_t joint = 0; joint < joint_count; joint++) {
        bank->joints[joint].parent = -1;
        t6_mat_identity(&bank->joints[joint].bind);
    }
    for (cgltf_size node = 0; node < data->nodes_count; node++) {
        const cgltf_node *bone = &data->nodes[node];
        int32_t joint = joint_of(bone);
        if (joint < 0) continue;
        T6ClipJoint *out = &bank->joints[joint];
        out->parent = (int16_t)joint_of(bone->parent);
        if (bone->has_rotation) {
            T6Vec4 turn = sim_turn(bone->rotation);
            t6_quat_to_mat(&out->bind, &turn);
        }
        if (bone->has_translation)
            for (int axis = 0; axis < 3; axis++) out->bind.m[3][axis] = bone->translation[axis] * MM_PER_METRE;
        out->bind.m[3][3] = 1.0f;
    }
    return NULL;
}

static bool track_of(const cgltf_animation_channel *channel, T6ClipTrack *track) {
    static const struct { cgltf_animation_path_type type; T6ClipPath path; } PATHS[] = {
        {cgltf_animation_path_type_rotation, CLIP_ROTATION},
        {cgltf_animation_path_type_translation, CLIP_TRANSLATION},
        {cgltf_animation_path_type_scale, CLIP_SCALE},
    };
    int32_t joint = joint_of(channel->target_node);
    if (joint < 0) return false;
    for (size_t at = 0; at < sizeof PATHS / sizeof *PATHS; at++)
        if (PATHS[at].type == channel->target_path) {
            *track = (T6ClipTrack){(uint16_t)joint, PATHS[at].path};
            return true;
        }
    return false;
}

// Tightly packed floats, one key a frame.
static const float *keys_of(const cgltf_animation_channel *channel, T6ClipPath path, cgltf_size frames) {
    const cgltf_accessor *output = channel->sampler->output;
    cgltf_type type = path == CLIP_ROTATION ? cgltf_type_vec4 : cgltf_type_vec3;
    if (output->component_type != cgltf_component_type_r_32f || output->type != type || output->count != frames) return NULL;
    if (output->stride != cgltf_num_components(type) * sizeof(float) || !output->buffer_view || !output->buffer_view->buffer->data) return NULL;
    const cgltf_buffer_view *view = output->buffer_view;
    return (const float *)((const uint8_t *)view->buffer->data + view->offset + output->offset);
}

// Every clip must have the first clip's tracks, in order.
static const char *read_bank(T6ClipBank *bank, const cgltf_data *data) {
    if (data->animations_count == 0) return "no clips";
    uint32_t track_count = (uint32_t)data->animations[0].channels_count, clip_count = (uint32_t)data->animations_count;
    size_t bytes = track_count * sizeof(T6ClipTrack) + clip_count * sizeof(uint16_t) + clip_count * track_count * sizeof(float *);
    uint8_t *block = malloc(bytes);
    if (!block) return "out of memory";
    *bank = (T6ClipBank){track_count, clip_count, (T6ClipTrack *)block};
    bank->keys = (const float **)(block + track_count * sizeof(T6ClipTrack));
    bank->frame_counts = (uint16_t *)(bank->keys + clip_count * track_count);
    for (uint32_t clip = 0; clip < clip_count; clip++) {
        const cgltf_animation *animation = &data->animations[clip];
        if (animation->channels_count != track_count) return "clips with other tracks";
        cgltf_size frames = track_count ? animation->channels[0].sampler->input->count : 0;
        if (frames == 0 || frames > UINT16_MAX) return "a clip without keys";
        bank->frame_counts[clip] = (uint16_t)frames;
        for (uint32_t track = 0; track < track_count; track++) {
            T6ClipTrack seen;
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

const char *t6_load_clip_bank(T6ClipBank *bank, sqlite3 *db, const char *owner, T6ReadFile read, void *context) {
    *bank = (T6ClipBank){0};
    char file[256];
    if (!bank_file(db, owner, file, sizeof file)) return NULL;
    T6Bytes bytes = read(context, file);
    cgltf_options options = {0};
    cgltf_data *data = NULL;
    if (cgltf_parse(&options, bytes.data, bytes.size, &data) != cgltf_result_success) return fail(owner, "not a glTF file");
    const char *failed = "no keys";
    if (data->buffers_count == 1 && !data->buffers[0].uri && data->bin && data->bin_size >= data->buffers[0].size) {
        data->buffers[0].data = (void *)data->bin;  // the glb's own chunk; cgltf_load_buffers would link file reads
        failed = read_bank(bank, data);
        if (!failed) failed = read_joints(bank, data);
    }
    cgltf_free(data);
    if (!failed) return NULL;
    t6_free_clip_bank(bank);
    return fail(owner, failed);
}

void t6_free_clip_bank(T6ClipBank *bank) {
    free(bank->tracks);
    free(bank->joints);
    *bank = (T6ClipBank){0};
}

int32_t t6_clip_track(const T6ClipBank *bank, uint16_t joint, T6ClipPath path) {
    for (uint32_t track = 0; track < bank->track_count; track++)
        if (bank->tracks[track].joint == joint && bank->tracks[track].path == path) return (int32_t)track;
    return -1;
}

uint16_t t6_clip_frames(const T6ClipBank *bank, uint16_t clip) {
    if (bank->clip_count == 0) return 0;
    return bank->frame_counts[clip < bank->clip_count ? clip : 0];
}

T6Vec4 t6_clip_key(const T6ClipBank *bank, uint16_t clip, uint32_t track, int32_t frame) {
    if (clip >= bank->clip_count) clip = 0;
    uint16_t frames = t6_clip_frames(bank, clip);
    if (frames == 0 || track >= bank->track_count) return (T6Vec4){{0, 0, 0, 1}};
    if (frame < 0) frame = 0;
    if (frame >= frames) frame = frames - 1;
    const float *keys = bank->keys[clip * bank->track_count + track];
    switch (bank->tracks[track].path) {
    case CLIP_ROTATION: return sim_turn(keys + 4 * frame);
    case CLIP_TRANSLATION: keys += 3 * frame; return (T6Vec4){{keys[0] * MM_PER_METRE, keys[1] * MM_PER_METRE, keys[2] * MM_PER_METRE, 1}};
    case CLIP_SCALE: keys += 3 * frame; return (T6Vec4){{keys[0], keys[1], keys[2], 1}};
    }
    return (T6Vec4){{0, 0, 0, 1}};
}
