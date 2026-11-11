// Stock TK5 presenter (gamerender.wasm): the stage nodes. A walled stage is one glb at the origin. An infinite stage
// (radius above 0) keeps a patch of floor tiles around the fighters and turns the floor against the rest of the world
// as the camera drifts (tk5decomp docs/stages.md 8).
#include <math.h>
#include <stdio.h>

#include "gamerender/presenter.h"
#include "sqlite3.h"

// (hole infinite-stage-focus :tags (tk5mod look) :sev polish) the game's floor focus is not found (stages.md 8.9): the stage follows the fighters' midpoint, a guess. tekken 6 as well modules/tk6/gamerender/stage.c
// (hole infinite-stage-layer-order :tags (tk5mod look) :sev polish) the game draws layers 2 and 3 swapped on infinite stages (stages.md 8.6); the host's depth test decides here. tekken 6 as well modules/tk6/gamerender/stage.c

enum { LAYER_COUNT = 6, TILE_LAYER = 2, TILES_MAX = 196 };  // glb nodes 0..5 are the layer roots

static const float AHEAD = 4.096f;         // metres: the point in front of the camera that the turn chases
static const float MOST_PUSH = 0.0174533f;  // radians a frame: 1 degree
static const float CUT_TURN = 0.174533f;   // a camera turn above this in one frame is a cut: 10 degrees
static const float PI = 3.14159265f;
static const OwQuat NO_TURN = {0, 0, 0, 1};

typedef struct {
    uint32_t part;
    float home_x, home_z;      // metres
    float placed_x, placed_z;  // floor frame, last frame: a jump of a period is not blended
} Tile;

static struct {
    uint32_t asset;
    float period, radius;  // metres; radius 0: a walled stage
    Tile tiles[TILES_MAX];
    int tile_count;
    bool started;
    uint32_t frame;
    float world_turn;           // radians the fighters' world has turned against the floor
    float heading;              // the camera's, last frame
    float ahead_x, ahead_z;     // the point AHEAD in front of the camera, last frame
    float floor_x, floor_z;     // the fighters' midpoint in the floor's own frame
    float midpoint_x, midpoint_z;
} stage;

static float wrapped(float angle) {
    if (angle > PI) return angle - 2 * PI;
    if (angle < -PI) return angle + 2 * PI;
    return angle;
}

// (x, z) turned by angle about +y, the way a glTF rotation turns it.
static void turned(float angle, float x, float z, float *out_x, float *out_z) {
    *out_x = x * cosf(angle) + z * sinf(angle);
    *out_z = z * cosf(angle) - x * sinf(angle);
}

void t5_stage_init(sqlite3 *db, const T5View *view) {
    stage = (typeof(stage)){0};
    sqlite3_stmt *rows;
    if (sqlite3_prepare_v2(db, "SELECT file, period, radius FROM stage WHERE id = ?1", -1, &rows, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(rows, 1, view->stage, -1, SQLITE_STATIC);
    if (sqlite3_step(rows) == SQLITE_ROW) {
        stage.asset = t5_asset_of(sqlite3_column_text(rows, 0));
        stage.period = (float)sqlite3_column_double(rows, 1);
        stage.radius = (float)sqlite3_column_double(rows, 2);
    }
    sqlite3_finalize(rows);
    if (stage.radius <= 0) return;
    if (sqlite3_prepare_v2(db, "SELECT part, home_x, home_z FROM stage_tile WHERE stage = ?1", -1, &rows, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(rows, 1, view->stage, -1, SQLITE_STATIC);
    while (stage.tile_count < TILES_MAX && sqlite3_step(rows) == SQLITE_ROW) {
        stage.tiles[stage.tile_count++] = (Tile){
            .part = (uint32_t)sqlite3_column_int(rows, 0),
            .home_x = (float)sqlite3_column_double(rows, 1),
            .home_z = (float)sqlite3_column_double(rows, 2),
        };
    }
    sqlite3_finalize(rows);
}

static float heading_of(OwCamera camera) {
    return atan2f(camera.target.x - camera.position.x, camera.target.z - camera.position.z);
}

static void restart(const T5View *view, OwCamera camera, float midpoint_x, float midpoint_z) {
    stage.started = true;
    stage.frame = view->frame;
    stage.world_turn = 0;
    stage.heading = heading_of(camera);
    stage.ahead_x = camera.position.x + AHEAD * sinf(stage.heading);
    stage.ahead_z = camera.position.z + AHEAD * cosf(stage.heading);
    stage.floor_x = stage.midpoint_x = midpoint_x;
    stage.floor_z = stage.midpoint_z = midpoint_z;
}

// One frame of the game's world turn (0x94374): it chases the camera's sideways drift, at most a degree a frame.
static void turn_step(OwCamera camera) {
    float heading = heading_of(camera);
    float old_ahead = atan2f(stage.ahead_x - camera.position.x, stage.ahead_z - camera.position.z);
    float last_heading = stage.heading;
    stage.heading = heading;
    stage.ahead_x = camera.position.x + AHEAD * sinf(heading);
    stage.ahead_z = camera.position.z + AHEAD * cosf(heading);
    if (fabsf(last_heading - heading) > CUT_TURN) return;
    float push = fminf(fmaxf(0.5f * wrapped(old_ahead - heading), -MOST_PUSH), MOST_PUSH);
    stage.world_turn = wrapped(stage.world_turn + push);
}

// The fighters' walk since last frame, carried into the floor's frame.
static void follow(float midpoint_x, float midpoint_z) {
    float step_x, step_z;
    turned(stage.world_turn, midpoint_x - stage.midpoint_x, midpoint_z - stage.midpoint_z, &step_x, &step_z);
    stage.floor_x += step_x;
    stage.floor_z += step_z;
    stage.midpoint_x = midpoint_x;
    stage.midpoint_z = midpoint_z;
}

static OwNode stage_node(const char *id, uint32_t part, OwVec3 position, OwQuat rotation, uint32_t flags) {
    OwNode node = {.asset = stage.asset, .part = part, .flags = flags, .class = OW_CLASS_SCENERY};
    node.transform = (OwTransform){.position = position, .rotation = rotation, .scale = {1, 1, 1}};
    snprintf(node.id, sizeof node.id, "%s", id);
    return node;
}

// The game's tile pool (0x831f8): each tile takes the copy of itself nearest the focus, whole periods away, and is
// hidden past the radius. Here the floor is drawn turned back by the world turn about the fighters' midpoint.
static uint32_t tile_nodes(OwNode *nodes, uint32_t max, bool snap) {
    uint32_t count = 0;
    OwQuat floor_turn = {0, sinf(-stage.world_turn / 2), 0, cosf(-stage.world_turn / 2)};
    for (int at = 0; at < stage.tile_count && count < max; at++) {
        Tile *tile = &stage.tiles[at];
        float placed_x = tile->home_x + stage.period * roundf((stage.floor_x - tile->home_x) / stage.period);
        float placed_z = tile->home_z + stage.period * roundf((stage.floor_z - tile->home_z) / stage.period);
        float away_x = stage.floor_x - placed_x, away_z = stage.floor_z - placed_z;
        bool jumped = placed_x != tile->placed_x || placed_z != tile->placed_z;
        tile->placed_x = placed_x;
        tile->placed_z = placed_z;
        if (away_x * away_x + away_z * away_z > stage.radius * stage.radius) continue;
        float offset_x, offset_z;
        turned(-stage.world_turn, placed_x - tile->home_x - stage.floor_x, placed_z - tile->home_z - stage.floor_z, &offset_x, &offset_z);
        OwVec3 position = {stage.midpoint_x + offset_x, 0, stage.midpoint_z + offset_z};
        char id[32];
        snprintf(id, sizeof id, "stage.tile.%u", tile->part);
        nodes[count++] = stage_node(id, tile->part, position, floor_turn, snap || jumped ? OW_NODE_NO_BLEND : 0);
    }
    return count;
}

uint32_t t5_stage_nodes(const T5View *view, OwCamera camera, float midpoint_x, float midpoint_z, OwNode *nodes, uint32_t max) {
    if (!stage.asset || max == 0) return 0;
    if (stage.radius <= 0) {
        nodes[0] = stage_node("stage", 0, (OwVec3){0, 0, 0}, NO_TURN, 0);
        return 1;
    }
    if (!stage.started || view->snap || view->frame < stage.frame) restart(view, camera, midpoint_x, midpoint_z);
    if (view->frame != stage.frame) turn_step(camera);
    stage.frame = view->frame;
    follow(midpoint_x, midpoint_z);

    uint32_t count = 0;
    OwVec3 midpoint = {midpoint_x, 0, midpoint_z};
    for (uint32_t layer = 0; layer < LAYER_COUNT && count < max; layer++) {
        if (layer == TILE_LAYER) continue;
        char id[32];
        snprintf(id, sizeof id, "stage.layer.%u", layer);
        nodes[count++] = stage_node(id, layer + 1, midpoint, NO_TURN, view->snap ? OW_NODE_NO_BLEND : 0);
    }
    return count + tile_nodes(nodes + count, max - count, view->snap);
}
