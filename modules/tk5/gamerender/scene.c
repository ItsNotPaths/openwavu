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
    NODES_MAX = T5_FIGHTER_COUNT * PARTS_MAX + 1,
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
static uint32_t stage_asset;
static T5Visual visual;

static struct {
    OwScene scene;
    OwLight light;
    OwNode nodes[NODES_MAX];
    OwTransform bones[T5_FIGHTER_COUNT][POSED_BONES];
} block;

static uint32_t asset_of(const unsigned char *path) {
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
        part->asset = asset_of(sqlite3_column_text(rows, 1));
        if (part->asset) part_count[side]++;
    }
    sqlite3_finalize(rows);
}

// No banks: the fighter keeps the sim's fingers.
static void load_hands(sqlite3 *db, int side, const T5Loadout *loadout) {
    size_t bytes;
    T5Arena arena;
    T5HandBanks banks = {0};
    const char *failed = t5_load_hands_storage(db, loadout->character, &bytes);
    if (!failed) failed = t5_new_arena(&arena, bytes);
    if (!failed) failed = t5_load_hands(&banks, db, loadout->character, t5_read_pack_file, NULL, &arena);
    if (!failed) visual.fighter[side].banks = banks;
}

static uint32_t load_stage(sqlite3 *db, const char *stage) {
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT file FROM stage WHERE id = ?1", -1, &rows, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_text(rows, 1, stage, -1, SQLITE_STATIC);
    uint32_t asset = sqlite3_step(rows) == SQLITE_ROW ? asset_of(sqlite3_column_text(rows, 0)) : 0;
    sqlite3_finalize(rows);
    return asset;
}

bool t5_scene_init(const T5View *view) {
    sqlite3 *db = ow_db_open(DB_PATH, sizeof DB_PATH - 1);
    if (!db) return false;
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        load_parts(db, side, &view->fighters[side].loadout);
        load_hands(db, side, &view->fighters[side].loadout);
    }
    stage_asset = load_stage(db, view->stage);
    t5_camera_init(db, view);
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
    t5_visual_step(&visual, view, seconds);
    uint32_t count = 0;
    if (stage_asset) {
        block.nodes[count++] = (OwNode){.id = "stage", .asset = stage_asset, .transform = PLACE_AT_ORIGIN, .class = OW_CLASS_SCENERY};
    }
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
    OwScene *scene = &block.scene;
    OW_SCENE_SIZES(scene);
    scene->camera = t5_camera(view, seconds);
    scene->ambient = (OwColor){0.45f, 0.45f, 0.5f, 1};
    block.light = (OwLight){.kind = OW_LIGHT_DIRECTIONAL, .color = {1, 0.97f, 0.9f, 0.8f}, .direction = {0.3f, -1, 0.4f}};
    scene->light_count = 1;
    scene->light_offset = offsetof(typeof(block), light);
    scene->node_count = count;
    scene->node_offset = offsetof(typeof(block), nodes);
    ow_scene_submit(scene, sizeof block);
}
