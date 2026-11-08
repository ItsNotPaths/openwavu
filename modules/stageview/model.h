// A stage glb as nodes in world space, for picking and listing.
#ifndef STAGEVIEW_MODEL_H
#define STAGEVIEW_MODEL_H

#include <stdbool.h>
#include <stdint.h>

typedef struct { float x, y, z; } Point;

typedef struct {
    char name[96];
    int32_t parent, mesh;  // -1: none
    int32_t layer;         // the root node above it
    bool drawn;            // the whole glb draws it: no _DRWOFF_
    char materials[64];    // material indices, comma separated
    char textures[256];    // texture file names, comma separated
    int32_t first_triangle, triangle_count;
    Point low, high;       // world bounds of its own mesh
} ModelNode;

typedef struct {
    ModelNode *nodes;
    int32_t node_count;
    Point *corners;  // 3 per triangle, world space
} Model;

// The glb at path; NULL or the failure.
const char *model_load(Model *model, const char *path);
void model_free(Model *model);
// The nearest node of mesh the ray hits, skipping nodes where skip[node] is true; -1 for none.
int32_t model_pick(const Model *model, Point origin, Point direction, const bool *skip);

#endif
