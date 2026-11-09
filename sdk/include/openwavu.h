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

// Final value (the pack.toml default or the lobby host's pick), as a number; the fallback if the name is unknown or its value is not a number.
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
	OW_PAD_BACK = 1 << 9,  // a gamepad's Back or Select; menus only, sims ignore it
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
#define OW_HOST_VIEW_VERSION 4
enum { OW_CONNECTION_OFFLINE = 0, OW_CONNECTION_CONNECTING = 1, OW_CONNECTION_ONLINE = 2, OW_CONNECTION_FAILED = 3 };
enum { OW_MATCH_NONE = 0, OW_MATCH_RUNNING = 1, OW_MATCH_ENDED = 2 };
enum { OW_LOBBIES_MAX = 16, OW_NAME_MAX = 32, OW_PARAMS_MAX = 128, OW_REFUSED_MAX = 64, OW_WATCHERS_MAX = 6 };
// Text fields are NUL terminated, cut to fit.
typedef struct {
	uint32_t id;                  // for ow_lobby_join
	uint32_t players;             // members: the two seats and the watchers
	char host[OW_NAME_MAX];       // the host's name
	char mode[OW_NAME_MAX];
	char params[OW_PARAMS_MAX];   // the host's picks, like ow_match_local's params
} OwLobby;
typedef struct {
	char name[OW_NAME_MAX];       // empty: the seat is free
	uint32_t ready;
} OwSeat;
typedef struct {
	char name[OW_NAME_MAX];
	uint32_t queued;              // in line for a seat
} OwWatcher;
typedef struct {
	uint32_t version;     // OW_HOST_VIEW_VERSION
	uint32_t size;        // sizeof(OwHostView) as the host builds it
	uint32_t connection;  // OW_CONNECTION_*
	uint32_t overlay;     // 1 while openwavu's own menu is open on top
	uint32_t match;       // OW_MATCH_*: ended stays until the next match runs
	int32_t winner;       // an ended match: the side that won, -1 for a draw
	// Online. The lobbies this player can join: this pack's, same lobby hash, a free seat, no match running.
	uint32_t lobby_count;
	OwLobby lobbies[OW_LOBBIES_MAX];
	uint32_t joined;      // 1 while in a lobby: the fields below
	OwLobby lobby;
	OwSeat seats[2];      // by side
	uint32_t seat;        // this player's, unless watching
	char refused[OW_REFUSED_MAX];  // the server's last refusal, or why the connection failed
	// Version 3.
	uint32_t hosting;     // 1 when this player hosts its lobby: ow_lobby_params
	uint32_t watching;    // 1 when this player has no seat
	uint32_t queued;      // 1 when this player is in line for a seat
	uint32_t watcher_count;
	OwWatcher watchers[OW_WATCHERS_MAX];  // the members without a seat: the line first, in its order, then the others
	// Version 4.
	uint32_t locked_lobbies;  // bit k: lobbies[k] takes a password
	uint32_t password;        // hosting: the password as this player set it, 0 for none
} OwHostView;
// (hole lobby-regions-view :tags (sdk net) :needs lobby-regions) the lobby list has no region or ping.
OW_IMPORT(host_view) int32_t ow_host_view(OwHostView *view, uint32_t cap);
// Back to the launcher after this frame, at once: a running match ends, and any confirm is the pack's own.
OW_IMPORT(exit) void ow_exit(void);
// An offline match of a pack.toml mode, started at the next frame; 0, or -1 when refused (an unknown mode, params that
// do not read, a match asked for or running). bot_sides: bit per side played by ow_bot_pad. params: values for params
// the modules declare, as a lobby host sets them: `name=value` pairs split by spaces ("stage=dragons_nest rounds=5").
OW_IMPORT(match_local) int32_t ow_match_local(const char *mode, uint32_t mode_len, uint32_t bot_sides,
	const void *loadout0, uint32_t loadout0_len, const void *loadout1, uint32_t loadout1_len, const char *params, uint32_t params_len);
// (hole app-modules :tags (sdk game wasm)) no ow_module_start, ow_module_stop, ow_module_send, ow_scene_owner or 2D order for the entry module's own modules.
// Online intents; the host view shows what came of them. ow_online(1) connects to the network's lobby server,
// ow_online(0) leaves it. A lobby has two seats and up to six watchers; a joiner gets in line for a seat, a free seat goes
// to the first in line. A lobby match starts by itself once both seats are ready, like an asked match; watchers see the
// next match that starts after they join.
OW_IMPORT(online) void ow_online(uint32_t on);
// Hosts a lobby of a pack.toml mode with these picks (as ow_match_local's params); -1 when refused (offline, already in
// a lobby, an unknown mode, picks the pack does not allow).
OW_IMPORT(lobby_create) int32_t ow_lobby_create(const char *mode, uint32_t mode_len, const char *params, uint32_t params_len);
// password: four digits, 0..9999; 0 for an open lobby.
OW_IMPORT(lobby_join) void ow_lobby_join(uint32_t id, uint32_t password);
OW_IMPORT(lobby_leave) void ow_lobby_leave(void);
// 1: into line for a seat. 0: back to watching, from a seat (outside a match) or the line.
OW_IMPORT(lobby_queue) void ow_lobby_queue(uint32_t on);
// The host's new picks (as ow_lobby_create's) for the next match; both seats are unready again. -1 when not hosting, a
// match is running, or picks the pack does not allow.
OW_IMPORT(lobby_params) int32_t ow_lobby_params(const char *params, uint32_t params_len);
// The host's password for joining, 0..9999; 0 for none. -1 when not hosting or over four digits.
OW_IMPORT(lobby_lock) int32_t ow_lobby_lock(uint32_t password);
// The host puts a member out of the lobby; ban 1 keeps them out. member: 0 and 1 are the seats by side, 2 + k is
// watchers[k]. -1 when not hosting.
OW_IMPORT(lobby_kick) int32_t ow_lobby_kick(uint32_t member, uint32_t ban);
// The pack.toml params a lobby host may change (expose = true), in pack.toml's order (sorted by name). Text fields are
// NUL terminated, cut to fit.
enum { OW_PARAM_NUMBER = 0, OW_PARAM_TEXT = 1 };
typedef struct {
	char name[OW_NAME_MAX];
	uint32_t kind;          // OW_PARAM_*
	uint32_t value_count;   // the only values allowed (ow_exposed_param_value); 0 allows any
	double min, max;        // numbers
	char fallback[OW_NAME_MAX];  // the default, as text
} OwParamInfo;
// Returns how many there are; copies as many as fit in cap.
OW_IMPORT(exposed_params) int32_t ow_exposed_params(OwParamInfo *params, uint32_t cap);
// An allowed value of exposed param `param`; returns its length, or -1. No NUL; copies as much as fits.
OW_IMPORT(exposed_param_value) int32_t ow_exposed_param_value(uint32_t param, uint32_t value, char *buf, uint32_t buf_len);
// A seated player's loadout for the next match of its lobby; -1 when too big.
OW_IMPORT(ready) int32_t ow_ready(const void *loadout, uint32_t loadout_len);
// (hole save-imports :tags (sdk game saves)) no ow_save_read or ow_save_write on the pack save, and no save header stamped with the pack id and version (docs/packs.md).

// Presentation exports. Outside rollback, once per rendered frame.

OW_EXPORT(ow_init) int32_t ow_init(void);
// cmdbuf: the frame's GPU command buffer id; the host draws the scene and the 2D renderer after this returns.
OW_EXPORT(ow_frame) void ow_frame(float dt, uint32_t cmdbuf);
// (hole app-events :tags (sdk game)) events to presentation modules have no kinds or payload format: filtered SDL key, mouse and text events, messages from ow_module_send.
OW_EXPORT(ow_on_event) void ow_on_event(uint32_t kind, const void *data, uint32_t size);

#endif
