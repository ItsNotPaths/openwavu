// The scene a presentation module sends each frame with ow_scene_submit (docs/app.md): one block of plain data. Offsets
// are from the start of the block. A long-term contract: fields are only added at the end of a struct, and the
// *_size fields say how long each struct is, so the host reads old and new packs alike.
#ifndef OW_SCENE_H
#define OW_SCENE_H

#include <stdint.h>

#define OW_SCENE_VERSION 1

typedef struct { float x, y, z; } OwVec3;
typedef struct { float x, y, z, w; } OwQuat;
typedef struct { float r, g, b, a; } OwColor;

typedef struct {
	OwVec3 position;
	OwQuat rotation;
	OwVec3 scale;
} OwTransform;

typedef struct {
	OwVec3 position, target;
	float fov;   // vertical, radians
	float roll;  // radians, around the view direction
} OwCamera;

enum { OW_LIGHT_DIRECTIONAL = 0, OW_LIGHT_POINT = 1 };

typedef struct {
	uint32_t kind;     // OW_LIGHT_*
	OwColor color;     // a = intensity
	OwVec3 position;   // point lights
	OwVec3 direction;  // directional lights: the way the light travels
	float range;       // point lights: no light past this
} OwLight;

typedef struct {
	OwColor color;
	float start, end;  // distances from the camera; end 0 is no fog
} OwFog;

// Overrides of the asset's own material; 0 keeps the asset's.
typedef struct {
	OwColor tint;      // multiplies the base color; all 0 is no tint
	uint32_t texture;  // ow_asset id: replaces the base color texture
	uint32_t shader;   // ow_asset id of a pack SPIR-V fragment shader
	float params[8];   // the shader's inputs
} OwMaterial;

enum {
	OW_NODE_BILLBOARD = 1 << 0,  // faces the camera
	OW_NODE_NO_SHADOW = 1 << 1,
	OW_NODE_NO_BLEND = 1 << 2,   // this frame: a snap (teleport, side switch, round reset), not a move
	OW_NODE_HIDDEN = 1 << 3,     // not drawn; a hidden part also leaves the whole glb's draw
};

enum { OW_CLASS_GAMEPLAY = 0, OW_CLASS_SCENERY = 1 };

typedef struct {
	char id[32];             // the pack's name for it, NUL padded; matches the node across frames
	uint32_t asset;          // ow_asset id of a glb or an image (a quad); 0 with texture for a pack texture quad
	uint32_t part;           // glb node index + 1: that node and what is under it; 0 = the whole glb, which leaves
	                         // out _DRWOFF_ nodes (broken props: send one as its own part to show it)
	uint32_t texture;        // an SDL texture handle of the pack, for a quad; 0 = none
	OwTransform transform;
	uint32_t bone_count;     // the pose, one OwTransform per glb skin joint, in joint order; 0 = the glb's own pose
	uint32_t bone_offset;
	uint32_t clip;           // glb animation index + 1, played at clip_time; 0 = none
	float clip_time;         // seconds
	OwMaterial material;
	uint32_t flags;          // OW_NODE_*
	uint32_t class;          // OW_CLASS_*
} OwNode;

// One effect, played at an age; the host keeps no effect state.
typedef struct {
	uint32_t effect;         // ow_asset id of an effect def
	uint32_t node;           // index + 1 into this scene's nodes; 0 = at a world point
	uint32_t bone;           // the node's joint it follows
	OwTransform at;          // from the bone, or in the world
	float age;               // seconds since it started
	uint32_t seed;
} OwFx;

typedef struct {
	uint32_t version;        // OW_SCENE_VERSION
	uint32_t scene_size, light_size, node_size, fx_size;  // sizeof each struct, as the pack built it
	OwCamera camera;
	OwColor ambient;
	OwFog fog;
	uint32_t light_count, light_offset;
	uint32_t node_count, node_offset;
	uint32_t fx_count, fx_offset;
} OwScene;

#define OW_SCENE_SIZES(s) ((s)->version = OW_SCENE_VERSION, (s)->scene_size = sizeof(OwScene), \
	(s)->light_size = sizeof(OwLight), (s)->node_size = sizeof(OwNode), (s)->fx_size = sizeof(OwFx))

#endif
