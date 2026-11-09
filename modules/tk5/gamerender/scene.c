// Stock TK5 presenter (gamerender.wasm): the 3D scene sent each frame (fighters, stage, camera, effects). Outside rollback; reads the view.
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "gamerender/presenter.h"
#include "gamerender/visual.h"
#include "ow_db.h"
#include "pack_file.h"
#include "sim/quat.h"
#include "sqlite3.h"

// (hole hand-pose :tags (tk5mod fighter-detail) :needs face-anims) fighter nodes get the fingers of the visual skeleton, not yet its face, eyes and head tilt.

enum {
    PARTS_MAX = 8,      // per fighter
    BODY_JOINTS = 23,   // glb joints 0..22: the root, then the body bones the sim's skeleton B moves
    FIRST_FINGER_JOINT = FIRST_FINGER_BONE + 4,  // glb joints 55..84 are A bones 51..80
    POSED_BONES = FIRST_FINGER_JOINT + FINGER_BONES,  // joints 23..54 are left zero: they keep their rest pose
    STAGE_NODES_MAX = 256,  // layers and floor tiles
    NODES_MAX = T5_FIGHTER_COUNT * PARTS_MAX + STAGE_NODES_MAX,
    FX_MAX = 128,
};

// glb joint -> skeleton B slot, joints 1..22; helpers keep their rest pose under their parent.
static const int BODY_SLOT[BODY_JOINTS] = {-1, 0, 1, 2, 13, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 18, 19, 20, 17, 21};
static const char DB_PATH[] = "tk5.db";

typedef struct {
    char id[32];
    uint32_t asset;
} Part;

static Part parts[T5_FIGHTER_COUNT][PARTS_MAX];
static int part_count[T5_FIGHTER_COUNT];
static T5Visual visual;

static struct {
    OwScene scene;
    OwLight light;
    OwNode nodes[NODES_MAX];
    OwTransform bones[T5_FIGHTER_COUNT][POSED_BONES];
    OwFx fx[FX_MAX];
} block;

uint32_t t5_asset_of(const unsigned char *path) {
    return path ? ow_asset((OwStr){(uint32_t)strlen((const char *)path), (const char *)path}) : 0;
}

// The costume's part glbs, without the low detail ones.
static void load_parts(sqlite3 *db, int side, const T5Loadout *loadout) {
    sqlite3_stmt *rows;
    const char *query = "SELECT part.id, part.file FROM costume_part JOIN part ON part.id = costume_part.part "
                        "WHERE costume_part.character = ?1 AND costume_part.costume = ?2 AND part.slot != 'lod' ORDER BY part.id";
    if (sqlite3_prepare_v2(db, query, -1, &rows, NULL) != SQLITE_OK) return;
    char costume[16];
    snprintf(costume, sizeof costume, "%u", loadout->costume);
    sqlite3_bind_text(rows, 1, loadout->character, -1, SQLITE_STATIC);
    sqlite3_bind_text(rows, 2, costume, -1, SQLITE_STATIC);
    while (part_count[side] < PARTS_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        Part *part = &parts[side][part_count[side]];
        snprintf(part->id, sizeof part->id, "%d:%s", side + 1, (const char *)sqlite3_column_text(rows, 0));
        part->asset = t5_asset_of(sqlite3_column_text(rows, 1));
        if (part->asset) part_count[side]++;
    }
    sqlite3_finalize(rows);
}

// No banks: the fighter keeps the sim's fingers.
static void load_hands(sqlite3 *db, int side, const char *moveset) {
    size_t bytes;
    T5Arena arena;
    T5HandBanks banks = {0};
    const char *failed = t5_load_hands_storage(db, moveset, &bytes);
    if (!failed) failed = t5_new_arena(&arena, bytes);
    if (!failed) failed = t5_load_hands(&banks, db, moveset, t5_read_pack_file, NULL, &arena);
    visual.fighter[side].banks = failed ? (T5HandBanks){0} : banks;
}

static char loaded_movesets[T5_FIGHTER_COUNT][T5_NAME_BYTES];

// The hands and camera shots of each side's move set; again when a round brings another (Mokujin).
// (hole moveset-reload-leak :tags (tk5mod round-show) :sev polish) each reload takes a new hand arena and never frees the last.
static void load_movesets(sqlite3 *db, const T5View *view) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        const char *moveset = view->fighters[side].moveset;
        if (strncmp(loaded_movesets[side], moveset, T5_NAME_BYTES) == 0) continue;
        memcpy(loaded_movesets[side], moveset, T5_NAME_BYTES);
        load_hands(db, side, moveset);
        t5_camera_load(db, side, moveset);
    }
}

static bool movesets_changed(const T5View *view) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++)
        if (strncmp(loaded_movesets[side], view->fighters[side].moveset, T5_NAME_BYTES) != 0) return true;
    return false;
}

bool t5_scene_init(const T5View *view) {
    sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
    if (!db) return false;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) load_parts(db, side, &view->fighters[side].loadout);
    load_movesets(db, view);
    t5_stage_init(db, view);
    t5_effects_init(db, view);
    t5_sound_init(db, view);
    sqlite3_close(db);
    return true;
}

// A view matrix (row vectors, translation in row 3, mm) as a scene transform (column vectors, metres).
static OwTransform transform_of(const T5Mat4 *matrix) {
    T5Mat4 turn = {0};
    float scale[3];
    for (int row = 0; row < 3; row++) {
        const float *axis = matrix->m[row];
        scale[row] = sqrtf(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
        for (int column = 0; column < 3; column++) turn.m[column][row] = scale[row] > 0 ? axis[column] / scale[row] : 0;
    }
    T5Vec4 rotation;
    t5_mat_to_quat(&rotation, &turn);
    return (OwTransform){
        .position = {matrix->m[3][0] * MM, matrix->m[3][1] * MM, matrix->m[3][2] * MM},
        .rotation = {rotation.x, rotation.y, rotation.z, rotation.w},
        .scale = {scale[0], scale[1], scale[2]},
    };
}

static void pose_fighter(OwTransform bones[POSED_BONES], const T5Rig *rig) {
    bones[0] = transform_of(&rig->root.world);
    for (int joint = 1; joint < BODY_JOINTS; joint++) bones[joint] = transform_of(&rig->bones_b[BODY_SLOT[joint]].world);
    for (int bone = 0; bone < FINGER_BONES; bone++)
        bones[FIRST_FINGER_JOINT + bone] = transform_of(&rig->bones_a[FIRST_FINGER_BONE + bone].world);
}

static const OwTransform PLACE_AT_ORIGIN = {.rotation = {0, 0, 0, 1}, .scale = {1, 1, 1}};

void t5_scene_send(const T5View *view, float seconds) {
    if (movesets_changed(view)) {
        sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
        if (db) {
            load_movesets(db, view);
            sqlite3_close(db);
        }
    }
    t5_visual_step(&visual, view, seconds);
    OwScene *scene = &block.scene;
    scene->camera = t5_camera(view, seconds);
    float midpoint_x = 0, midpoint_z = 0;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        const T5Mat4 *root = &visual.fighter[side].rig.root.world;
        midpoint_x += root->m[3][0] * MM / T5_FIGHTER_COUNT;
        midpoint_z += root->m[3][2] * MM / T5_FIGHTER_COUNT;
    }
    uint32_t count = t5_stage_nodes(view, scene->camera, midpoint_x, midpoint_z, block.nodes, STAGE_NODES_MAX);
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        pose_fighter(block.bones[side], &visual.fighter[side].rig);
        for (int at = 0; at < part_count[side]; at++) {
            OwNode *node = &block.nodes[count++];
            *node = (OwNode){
                .asset = parts[side][at].asset,
                .transform = PLACE_AT_ORIGIN,
                .bone_count = POSED_BONES,
                .bone_offset = (uint32_t)(offsetof(typeof(block), bones) + side * sizeof block.bones[side]),
                .flags = (view->snap ? OW_NODE_NO_BLEND : 0) | (view->focus >= 0 && view->focus != side ? OW_NODE_HIDDEN : 0),
                .class = OW_CLASS_GAMEPLAY,
            };
            memcpy(node->id, parts[side][at].id, sizeof node->id);
        }
    }
    OW_SCENE_SIZES(scene);
    scene->ambient = (OwColor){0.45f, 0.45f, 0.5f, 1};
    block.light = (OwLight){.kind = OW_LIGHT_DIRECTIONAL, .color = {1, 0.97f, 0.9f, 0.8f}, .direction = {0.3f, -1, 0.4f}};
    scene->light_count = 1;
    scene->light_offset = offsetof(typeof(block), light);
    scene->node_count = count;
    scene->node_offset = offsetof(typeof(block), nodes);
    scene->fx_count = t5_effects(view, block.fx, FX_MAX);
    scene->fx_offset = offsetof(typeof(block), fx);
    ow_scene_submit(scene, sizeof block);
}
