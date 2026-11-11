// Stage viewer title pack (stageview.wasm): pick a stage, fly around it, click glb nodes to select them, and
// log the selection as TSV lines for bug reports.
#include <SDL3/SDL.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "model.h"
#include "openwavu.h"
#include "ow_db.h"
#include "sqlite3.h"

enum { STAGES_MAX = 64, NAME_BYTES = 64, LIST_ROWS = 40, SELECTED_ROWS = 30 };

static const char *const DB_PATHS[] = {"tk5.db", "tk6.db"};  // the base pack's, whichever it has
static const float TEXT_SCALE = 2;
static const float LINE = 10;  // debug text line height, before the scale
static const float FOV = 0.9f;
static const float TURN_PER_PIXEL = 0.004f;
static const float MOST_PITCH = 1.5f;
static const float FAST = 4;
static const OwColor SELECTED_TINT = {1.6f, 0.3f, 1.6f, 1};
static const OwColor HOVER_TINT = {1.6f, 1.6f, 0.4f, 1};

typedef struct { char id[NAME_BYTES], name[NAME_BYTES], file[128]; } Stage;

typedef struct {
    OwScene scene;
    OwLight light;
    OwNode nodes[];
} Block;

static Stage stages[STAGES_MAX];
static int stage_count, cursor;
static uint32_t held_pad;

static struct {
    bool open;
    Model model;
    uint32_t asset;
    bool *selected, *hidden;
    int32_t hover;
    Block *block;
    Point position;
    float yaw, pitch, speed;
    float mouse_x, mouse_y;
    bool looking;
    bool held[SDL_SCANCODE_COUNT];
    char notice[128];
} view;

OW_EXPORT(ow_init) int32_t init(void) {
    sqlite3 *db = NULL;
    for (size_t path = 0; !db && path < sizeof DB_PATHS / sizeof DB_PATHS[0]; path++) db = ow_db_open(DB_PATHS[path], (uint32_t)strlen(DB_PATHS[path]));
    if (!db) return 1;
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT id, name, file FROM stage ORDER BY id", -1, &rows, NULL) == SQLITE_OK) {
        while (stage_count < STAGES_MAX && sqlite3_step(rows) == SQLITE_ROW) {
            Stage *stage = &stages[stage_count++];
            snprintf(stage->id, sizeof stage->id, "%s", (const char *)sqlite3_column_text(rows, 0));
            snprintf(stage->name, sizeof stage->name, "%s", (const char *)sqlite3_column_text(rows, 1));
            snprintf(stage->file, sizeof stage->file, "%s", (const char *)sqlite3_column_text(rows, 2));
        }
        sqlite3_finalize(rows);
    }
    sqlite3_close(db);
    return stage_count > 0 ? 0 : 1;
}

static void log_text(const char *text) { ow_log((OwStr){(uint32_t)strlen(text), text}); }

static void close_stage(void) {
    model_free(&view.model);
    free(view.selected), free(view.hidden), free(view.block);
    view = (typeof(view)){0};
}

static void open_stage(const Stage *stage) {
    close_stage();
    const char *failed = model_load(&view.model, stage->file);
    if (failed) {
        log_text(failed);
        return;
    }
    int32_t count = view.model.node_count;
    view.selected = calloc((size_t)count + 1, sizeof *view.selected);
    view.hidden = calloc((size_t)count + 1, sizeof *view.hidden);
    view.block = calloc(1, sizeof(Block) + (size_t)(count * 2 + 2) * sizeof(OwNode));
    view.asset = ow_asset((OwStr){(uint32_t)strlen(stage->file), stage->file});
    view.hover = -1;
    view.position = (Point){0, 2, -8};
    view.pitch = -0.15f;
    view.speed = 4;
    view.open = true;
}

// --- camera

static Point forward_of(void) {
    return (Point){sinf(view.yaw) * cosf(view.pitch), sinf(view.pitch), cosf(view.yaw) * cosf(view.pitch)};
}
static Point right_of(Point forward) {
    float length = sqrtf(forward.x * forward.x + forward.z * forward.z);
    return (Point){-forward.z / length, 0, forward.x / length};
}
static Point moved(Point from, Point way, float distance) {
    return (Point){from.x + way.x * distance, from.y + way.y * distance, from.z + way.z * distance};
}

static void fly(float seconds) {
    Point forward = forward_of(), right = right_of(forward), up = {0, 1, 0};
    float step = view.speed * seconds * (view.held[SDL_SCANCODE_LSHIFT] ? FAST : 1);
    if (view.held[SDL_SCANCODE_W]) view.position = moved(view.position, forward, step);
    if (view.held[SDL_SCANCODE_S]) view.position = moved(view.position, forward, -step);
    if (view.held[SDL_SCANCODE_D]) view.position = moved(view.position, right, step);
    if (view.held[SDL_SCANCODE_A]) view.position = moved(view.position, right, -step);
    if (view.held[SDL_SCANCODE_E]) view.position = moved(view.position, up, step);
    if (view.held[SDL_SCANCODE_Q]) view.position = moved(view.position, up, -step);
}

// The node under the mouse.
static int32_t node_under_mouse(void) {
    int width, height;
    SDL_GetRenderOutputSize(ow_renderer(), &width, &height);
    if (width <= 0 || height <= 0) return -1;
    Point forward = forward_of(), right = right_of(forward);
    Point up = {right.y * forward.z - right.z * forward.y, right.z * forward.x - right.x * forward.z, right.x * forward.y - right.y * forward.x};
    float half_height = tanf(FOV / 2), half_width = half_height * (float)width / (float)height;
    float across = (2 * view.mouse_x / (float)width - 1) * half_width;
    float upward = (1 - 2 * view.mouse_y / (float)height) * half_height;
    Point direction = moved(moved(forward, right, across), up, upward);
    return model_pick(&view.model, view.position, direction, view.hidden);
}

// --- export

static void log_selection(void) {
    log_text("tsv\tstage\tnode\tname\tlayer\tmesh\tmaterials\ttextures\ttriangles\tcenter_x\tcenter_y\tcenter_z\tsize_x\tsize_y\tsize_z\tnote");
    int rows = 0;
    for (int32_t index = 0; index < view.model.node_count; index++) {
        if (!view.selected[index]) continue;
        const ModelNode *node = &view.model.nodes[index];
        char line[768];
        snprintf(line, sizeof line, "tsv\t%s\t%d\t%s\t%d\t%d\t%s\t%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t", stages[cursor].id, index,
            node->name, node->layer, node->mesh, node->materials, node->textures, node->triangle_count,
            (node->low.x + node->high.x) / 2, (node->low.y + node->high.y) / 2, (node->low.z + node->high.z) / 2,
            node->high.x - node->low.x, node->high.y - node->low.y, node->high.z - node->low.z);
        log_text(line);
        rows++;
    }
    snprintf(view.notice, sizeof view.notice, "logged %d rows", rows);
}

// --- input

static void on_key(SDL_Scancode key) {
    if (key == SDL_SCANCODE_ESCAPE) close_stage();
    if (key == SDL_SCANCODE_X) log_selection();
    if (key == SDL_SCANCODE_C) memset(view.selected, 0, (size_t)view.model.node_count * sizeof *view.selected);
    if (key == SDL_SCANCODE_U) memset(view.hidden, 0, (size_t)view.model.node_count * sizeof *view.hidden);
    if (key == SDL_SCANCODE_H) {
        for (int32_t index = 0; index < view.model.node_count; index++) {
            view.hidden[index] |= view.selected[index];
            view.selected[index] = false;
        }
    }
}

static void read_events(void) {
    SDL_Event event;
    while (view.open && SDL_PollEvent(&event)) {
        switch (event.type) {
        case SDL_EVENT_KEY_DOWN:
            if (event.key.scancode < SDL_SCANCODE_COUNT) view.held[event.key.scancode] = true;
            if (!event.key.repeat) on_key(event.key.scancode);
            break;
        case SDL_EVENT_KEY_UP:
            if (event.key.scancode < SDL_SCANCODE_COUNT) view.held[event.key.scancode] = false;
            break;
        case SDL_EVENT_MOUSE_MOTION:
            view.mouse_x = event.motion.x, view.mouse_y = event.motion.y;
            if (view.looking) {
                view.yaw -= event.motion.xrel * TURN_PER_PIXEL;
                view.pitch = fminf(fmaxf(view.pitch - event.motion.yrel * TURN_PER_PIXEL, -MOST_PITCH), MOST_PITCH);
            }
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            if (event.button.button == SDL_BUTTON_RIGHT) view.looking = true;
            if (event.button.button == SDL_BUTTON_LEFT && view.hover >= 0) view.selected[view.hover] = !view.selected[view.hover];
            break;
        case SDL_EVENT_MOUSE_BUTTON_UP:
            if (event.button.button == SDL_BUTTON_RIGHT) view.looking = false;
            break;
        case SDL_EVENT_MOUSE_WHEEL:
            view.speed = fminf(fmaxf(view.speed * powf(1.25f, event.wheel.y), 0.1f), 400);
            break;
        default:
            break;
        }
    }
}

// --- drawing

static OwNode stage_node(const char *id, uint32_t part, OwColor tint, uint32_t flags) {
    OwNode node = {.asset = view.asset, .part = part, .flags = flags, .class = OW_CLASS_SCENERY};
    node.transform = (OwTransform){.rotation = {0, 0, 0, 1}, .scale = {1, 1, 1}};
    node.material.tint = tint;
    snprintf(node.id, sizeof node.id, "%s", id);
    return node;
}

// The whole stage; a selected or hovered node leaves the whole draw (hidden) and comes back tinted.
static void send_scene(void) {
    Block *block = view.block;
    uint32_t count = 0;
    block->nodes[count++] = stage_node("stage", 0, (OwColor){0}, 0);
    for (int32_t index = 0; index < view.model.node_count; index++) {
        bool tinted = view.selected[index] || index == view.hover;
        if (!view.hidden[index] && !tinted) continue;
        char id[32];
        snprintf(id, sizeof id, "out.%d", index);
        block->nodes[count++] = stage_node(id, (uint32_t)index + 1, (OwColor){0}, OW_NODE_HIDDEN);
        if (view.hidden[index]) continue;
        snprintf(id, sizeof id, "tint.%d", index);
        block->nodes[count++] = stage_node(id, (uint32_t)index + 1, view.selected[index] ? SELECTED_TINT : HOVER_TINT, 0);
    }
    OwScene *scene = &block->scene;
    OW_SCENE_SIZES(scene);
    Point target = moved(view.position, forward_of(), 1);
    scene->camera = (OwCamera){{view.position.x, view.position.y, view.position.z}, {target.x, target.y, target.z}, FOV, 0};
    scene->ambient = (OwColor){0.45f, 0.45f, 0.5f, 1};
    block->light = (OwLight){.kind = OW_LIGHT_DIRECTIONAL, .color = {1, 0.97f, 0.9f, 0.8f}, .direction = {0.3f, -1, 0.4f}};
    scene->light_count = 1;
    scene->light_offset = offsetof(Block, light);
    scene->node_count = count;
    scene->node_offset = offsetof(Block, nodes);
    ow_scene_submit(scene, (uint32_t)(sizeof(Block) + count * sizeof(OwNode)));
}

static void text_line(float x, float *y, const char *text) {
    SDL_RenderDebugText(ow_renderer(), x, *y, text);
    *y += LINE;
}

static void draw_overlay(void) {
    SDL_Renderer *renderer = ow_renderer();
    SDL_SetRenderScale(renderer, TEXT_SCALE, TEXT_SCALE);
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 160);
    SDL_RenderFillRect(renderer, &(SDL_FRect){0, 0, 420, LINE * 7 + 8});
    SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    char line[256];
    float y = 4;
    snprintf(line, sizeof line, "%s (%s)  %d nodes", stages[cursor].name, stages[cursor].id, view.model.node_count);
    text_line(4, &y, line);
    snprintf(line, sizeof line, "at %.2f %.2f %.2f  speed %.1f", view.position.x, view.position.y, view.position.z, view.speed);
    text_line(4, &y, line);
    if (view.hover >= 0) {
        const ModelNode *node = &view.model.nodes[view.hover];
        snprintf(line, sizeof line, "#%d %s  layer %d", view.hover, node->name, node->layer);
        text_line(4, &y, line);
        snprintf(line, sizeof line, "  tex %s", node->textures);
    } else {
        text_line(4, &y, "-");
        line[0] = 0;
    }
    text_line(4, &y, line);
    text_line(4, &y, view.notice);
    text_line(4, &y, "WASDQE fly, shift fast, wheel speed, right drag look");
    text_line(4, &y, "click select, X log tsv, H hide sel, U unhide, C clear, Esc back");
    int listed = 0;
    for (int32_t index = 0; index < view.model.node_count && listed < SELECTED_ROWS; index++) {
        if (!view.selected[index]) continue;
        snprintf(line, sizeof line, "#%d %s", index, view.model.nodes[index].name);
        text_line(4, &y, line);
        listed++;
    }
}

static bool pressed(uint32_t pad, uint32_t bit) { return (pad & bit) && !(held_pad & bit); }

// Also clears the last stage's scene.
static void stage_list(void) {
    OwScene empty = {0};
    OW_SCENE_SIZES(&empty);
    ow_scene_submit(&empty, sizeof empty);
    uint32_t pad = ow_pad(0);
    if (pressed(pad, OW_PAD_UP)) cursor = (cursor + stage_count - 1) % stage_count;
    if (pressed(pad, OW_PAD_DOWN)) cursor = (cursor + 1) % stage_count;
    if (pressed(pad, OW_PAD_BACK)) ow_exit();
    if (pressed(pad, OW_PAD_START) || pressed(pad, OW_PAD_BUTTON_1)) open_stage(&stages[cursor]);
    held_pad = pad;
    SDL_SetRenderScale(ow_renderer(), TEXT_SCALE, TEXT_SCALE);
    SDL_SetRenderDrawColor(ow_renderer(), 255, 255, 255, 255);
    float y = 4;
    text_line(4, &y, "stageview: up/down, Enter opens, Backspace leaves");
    int first = cursor - LIST_ROWS / 2 < 0 ? 0 : cursor - LIST_ROWS / 2;
    for (int at = first; at < stage_count && at < first + LIST_ROWS; at++) {
        char line[160];
        snprintf(line, sizeof line, "%s %s (%s)", at == cursor ? ">" : " ", stages[at].name, stages[at].id);
        text_line(4, &y, line);
    }
}

OW_EXPORT(ow_frame) void frame(float seconds, uint32_t command_buffer) {
    (void)command_buffer;
    if (!view.open) {
        stage_list();
        return;
    }
    read_events();
    if (!view.open) return;
    fly(seconds);
    view.hover = node_under_mouse();
    send_scene();
    draw_overlay();
}
