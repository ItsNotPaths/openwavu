// A module that sends a scene (tests/scene_test.odin): every struct of ow_scene.h with its last field set.
#include <stddef.h>
#include <string.h>
#include "openwavu.h"

static struct {
    OwScene head;
    OwLight light;
    OwNode nodes[2];
    OwFx fx;
    OwTransform bones[3];
    uint32_t flips[2];
} block;

// 1 when the same path gives the same id and a missing file gives 0.
OW_EXPORT(send) int32_t send(void) {
    uint32_t notes = ow_asset(OW_STR("notes.txt"));
    OW_SCENE_SIZES(&block.head);
    block.head.camera.roll = 0.5f;
    block.head.fog.end = 30;
    block.head.light_count = 1, block.head.light_offset = offsetof(typeof(block), light);
    block.head.node_count = 2, block.head.node_offset = offsetof(typeof(block), nodes);
    block.head.fx_count = 1, block.head.fx_offset = offsetof(typeof(block), fx);
    block.light.range = 7;
    strcpy(block.nodes[0].id, "fighter");
    block.nodes[0].asset = notes;
    block.nodes[0].bone_count = 3, block.nodes[0].bone_offset = offsetof(typeof(block), bones);
    block.bones[2].scale.z = 2;
    block.nodes[0].flags = OW_NODE_NO_BLEND;
    block.nodes[0].class = OW_CLASS_SCENERY;
    strcpy(block.nodes[1].id, "stage");
    block.nodes[1].flip_count = 2, block.nodes[1].flip_offset = offsetof(typeof(block), flips);
    block.flips[0] = 4, block.flips[1] = 9;
    block.fx.node = 1, block.fx.age = 1.5f, block.fx.seed = 77;
    ow_scene_submit(&block.head, sizeof block);
    return notes != 0 && ow_asset(OW_STR("notes.txt")) == notes && ow_asset(OW_STR("missing.glb")) == 0;
}

// A node list that runs past the block.
OW_EXPORT(send_broken) void send_broken(void) {
    block.head.node_count = 1000;
    ow_scene_submit(&block.head, sizeof block);
}
