// openwavu module SDK: the host imports (net, saves, content, input, scene, rand, params, events) and the
// exports of sim and presentation modules. Presentation modules also call allowlisted SDL3 functions directly.
// The pack's entry module (pack.toml main) runs the others and starts matches (docs/app.md). Each module owns its memory.
// Strings are OwStr views (length + bytes, no NUL); they cross the import boundary as (pointer, length)
// into the calling module's memory.
#ifndef OPENWAVU_H
#define OPENWAVU_H

#include <stdint.h>
#include "ow_scene.h"

#define OW_EXPORT(name) __attribute__((export_name(#name)))
#define OW_IMPORT(name) __attribute__((import_module("openwavu"), import_name(#name)))

#define OW_SIDES 2

// A string view: length and bytes, no NUL terminator, not owned.
typedef struct {
	uint32_t len;
	const char *data;
} OwStr;
#define OW_STR(literal) ((OwStr){sizeof(literal) - 1, (literal)})

// Host imports, both modules. The raw imports take (pointer, length); call the OwStr versions.

OW_IMPORT(param) double ow_param_raw(const char *name, uint32_t name_len, double fallback);
OW_IMPORT(param_text) int32_t ow_param_text_raw(const char *name, uint32_t name_len, char *buf, uint32_t cap);
OW_IMPORT(content_read) int32_t ow_content_read_raw(const char *path, uint32_t path_len, uint32_t offset, void *buf, uint32_t cap);
OW_IMPORT(content_size) int32_t ow_content_size_raw(const char *path, uint32_t path_len);
OW_IMPORT(log) void ow_log_raw(const char *msg, uint32_t len);

// Final value after all param layers, as a number; the fallback if the name is unknown or its value is not a number.
static inline double ow_param(OwStr name, double fallback) { return ow_param_raw(name.data, name.len, fallback); }
// Final value as text (a row id, like stage=dragons_nest), no NUL; returns its length, or -1 if the name is unknown.
static inline int32_t ow_param_text(OwStr name, char *buf, uint32_t cap) { return ow_param_text_raw(name.data, name.len, buf, cap); }
// Bytes of a pack file, from offset; returns the bytes copied, or -1 if there is no such file.
static inline int32_t ow_content_read(OwStr path, uint32_t offset, void *buf, uint32_t cap) {
	return ow_content_read_raw(path.data, path.len, offset, buf, cap);
}
static inline int32_t ow_content_size(OwStr path) { return ow_content_size_raw(path.data, path.len); }
static inline void ow_log(OwStr msg) { ow_log_raw(msg.data, msg.len); }

// Host imports, sim only. Each is the same on every client.

// Seed of this match. The sim keeps its own RNG state in its memory.
OW_IMPORT(match_seed) uint64_t ow_match_seed(void);
// The loadout blob of one side, in the pack's own format; returns its length, or -1.
OW_IMPORT(loadout) int32_t ow_loadout(uint32_t side, void *buf, uint32_t cap);

enum {
	OW_EVENT_KO = 1,          // a = side that fell
	OW_EVENT_ROUND_END = 2,   // a = winner side, -1 for a draw
	OW_EVENT_MATCH_END = 3,   // a = winner side, -1 for a draw
};
// Both clients report; the server cross-checks. Ignored during resimulation.
OW_IMPORT(event) void ow_event(uint32_t kind, int32_t a, int32_t b);

// Host imports, presentation modules.

// The host's renderer, for the SDL calls in src/imports/sdl_allow.txt. SDL objects are handles: read sizes with
// SDL_GetTextureSize, not texture->w. The host resets draw state (color, blend, clip, scale) after each module draws.
OW_IMPORT(renderer) struct SDL_Renderer *ow_renderer(void);

// Which of the player's volumes an audio stream plays at; a stream starts as effects. The SDK sound helper names its own.
struct SDL_AudioStream;
enum { OW_SOUND_EFFECTS, OW_SOUND_MUSIC };
OW_IMPORT(sound_kind) void ow_sound_kind(struct SDL_AudioStream *stream, uint32_t kind);

// What local player 0 or 1 holds this frame, an OW_PAD_* word; 0 for any other player. Menus read it too.
OW_IMPORT(pad) uint32_t ow_pad(uint32_t player);
// The sim view of the last frame (in ow_init: the match start's); returns its length.
OW_IMPORT(view) int32_t ow_view(void *buf, uint32_t cap);
// The whole 3D scene of this frame, an OwScene block (ow_scene.h); the host keeps it until the next one. A block that
// does not read stops the module.
OW_IMPORT(scene_submit) void ow_scene_submit(const OwScene *scene, uint32_t size);
OW_IMPORT(asset) uint32_t ow_asset_raw(const char *path, uint32_t path_len);
// The id a scene names a pack file by (a glb, an image, an effect def); the same for the same path, 0 if there is no such file.
static inline uint32_t ow_asset(OwStr path) { return ow_asset_raw(path.data, path.len); }

// A pad word: what one player holds this frame, the same in every Tekken. The client maps physical buttons to the four
// game buttons and cancels opposite directions per axis before the sim sees it. Directions are screen directions.
enum {
	OW_PAD_UP = 1 << 0, OW_PAD_DOWN = 1 << 1, OW_PAD_LEFT = 1 << 2, OW_PAD_RIGHT = 1 << 3,
	OW_PAD_BUTTON_SHIFT = 4,  // game button n is bit OW_PAD_BUTTON_SHIFT + n - 1
	OW_PAD_BUTTON_1 = 1 << 4, OW_PAD_BUTTON_2 = 1 << 5, OW_PAD_BUTTON_3 = 1 << 6, OW_PAD_BUTTON_4 = 1 << 7,
	OW_PAD_START = 1 << 8,
};

// Sim exports. Inside rollback: the host snapshots [ow_sim_state, + ow_sim_state_size). Outside it, ow_sim_step may
// only write what no later step reads (the stack), and mutable globals end each step as they began (C: the stack
// pointer). The bot (ow_bot_pad) keeps its state outside the range.

OW_EXPORT(ow_sim_init) int32_t ow_sim_init(void);  // 0 = ok; reads params, loadouts and content
OW_EXPORT(ow_sim_step) void ow_sim_step(uint32_t pad0, uint32_t pad1);  // OW_PAD_* words
OW_EXPORT(ow_sim_state) void *ow_sim_state(void);
OW_EXPORT(ow_sim_state_size) uint32_t ow_sim_state_size(void);
OW_EXPORT(ow_sim_view) const void *ow_sim_view(void);
OW_EXPORT(ow_sim_view_size) uint32_t ow_sim_view_size(void);

// A bot for one side: its pad bits for the next tick, like a player pressing buttons. Called once per real tick,
// never in a resimulation; its state is outside the snapshot.
OW_EXPORT(ow_bot_pad) uint32_t ow_bot_pad(uint32_t side);

// Host imports, entry module only. The host sends state, the entry module sends intents.

// The host's state, read any time; returns its length and copies as much as fits. Fields are only added at the end:
// size says how many bytes this host fills.
// (hole host-view-online :tags (sdk net) :needs server-lobby) no connection states past offline, and no lobby list (every region, with ping) or current lobby sections.
#define OW_HOST_VIEW_VERSION 1
enum { OW_CONNECTION_OFFLINE = 0 };
enum { OW_MATCH_NONE = 0, OW_MATCH_RUNNING = 1, OW_MATCH_ENDED = 2 };
typedef struct {
	uint32_t version;     // OW_HOST_VIEW_VERSION
	uint32_t size;        // sizeof(OwHostView) as the host builds it
	uint32_t connection;  // OW_CONNECTION_*
	uint32_t overlay;     // 1 while openwavu's own menu is open on top
	uint32_t match;       // OW_MATCH_*: ended stays until the next match runs
	int32_t winner;       // an ended match: the side that won, -1 for a draw
} OwHostView;
OW_IMPORT(host_view) int32_t ow_host_view(OwHostView *view, uint32_t cap);
// An offline match of a pack.toml mode, started at the next frame; 0, or -1 when refused (an unknown mode, params that
// do not read, a match asked for or running). bot_sides: bit per side played by ow_bot_pad. params: values for params
// the modules declare, as a lobby host sets them: `name=value` pairs split by spaces ("stage=dragons_nest rounds=5").
OW_IMPORT(match_local) int32_t ow_match_local(const char *mode, uint32_t mode_len, uint32_t bot_sides,
	const void *loadout0, uint32_t loadout0_len, const void *loadout1, uint32_t loadout1_len, const char *params, uint32_t params_len);
// (hole app-modules :tags (sdk game wasm)) no ow_module_start, ow_module_stop, ow_module_send, ow_scene_owner or 2D order for the entry module's own modules.
// (hole lobby-intents :tags (sdk net) :needs server-lobby) no lobby list refresh, lobby join, create, leave, or ready with a loadout.
// (hole save-imports :tags (sdk game saves)) no ow_save_read or ow_save_write on the pack save, and no save header stamped with the pack id and version (docs/packs.md).

// Presentation exports. Outside rollback, once per rendered frame.

OW_EXPORT(ow_init) int32_t ow_init(void);
// cmdbuf: the frame's GPU command buffer id; the host draws the scene and the 2D renderer after this returns.
OW_EXPORT(ow_frame) void ow_frame(float dt, uint32_t cmdbuf);
// (hole app-events :tags (sdk game)) events to presentation modules have no kinds or payload format: filtered SDL key, mouse and text events, messages from ow_module_send.
OW_EXPORT(ow_on_event) void ow_on_event(uint32_t kind, const void *data, uint32_t size);

#endif
