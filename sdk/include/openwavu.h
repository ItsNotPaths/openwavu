// openwavu module SDK: the host imports (net, saves, content, input, audio, render, fx, rand, params,
// events) and the exports of the sim and app modules. Each module owns its memory.
// Strings are OwStr views (length + bytes, no NUL); they cross the import boundary as (pointer, length)
// into the calling module's memory.
#ifndef OPENWAVU_H
#define OPENWAVU_H

#include <stdint.h>

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
OW_IMPORT(content_read) int32_t ow_content_read_raw(const char *path, uint32_t path_len, uint32_t offset, void *buf, uint32_t cap);
OW_IMPORT(content_size) int32_t ow_content_size_raw(const char *path, uint32_t path_len);
OW_IMPORT(log) void ow_log_raw(const char *msg, uint32_t len);

// Final value after all param layers; the default if the name is unknown.
static inline double ow_param(OwStr name, double fallback) { return ow_param_raw(name.data, name.len, fallback); }
// Bytes of a pack file, from offset; returns the bytes copied, or -1 if there is no such file.
static inline int32_t ow_content_read(OwStr path, uint32_t offset, void *buf, uint32_t cap) {
	return ow_content_read_raw(path.data, path.len, offset, buf, cap);
}
static inline int32_t ow_content_size(OwStr path) { return ow_content_size_raw(path.data, path.len); }
static inline void ow_log(OwStr msg) { ow_log_raw(msg.data, msg.len); }

// Host imports, sim only. Each is the same on every peer.

// Seed of this match. The sim keeps its own RNG state in its memory.
OW_IMPORT(match_seed) uint64_t ow_match_seed(void);
// The loadout blob of one side, in the pack's own format; returns its length, or -1.
OW_IMPORT(loadout) int32_t ow_loadout(uint32_t side, void *buf, uint32_t cap);

enum {
	OW_EVENT_KO = 1,          // a = side that fell
	OW_EVENT_ROUND_END = 2,   // a = winner side, -1 for a draw
	OW_EVENT_MATCH_END = 3,   // a = winner side, -1 for a draw
};
// Both peers report; the server cross-checks. Ignored during resimulation.
OW_IMPORT(event) void ow_event(uint32_t kind, int32_t a, int32_t b);

// Host imports, app only.

// The sim view of the last frame; returns its length.
OW_IMPORT(view) int32_t ow_view(void *buf, uint32_t cap);

// Sim exports. Inside rollback: the host snapshots [ow_sim_state, + ow_sim_state_size) plus globals.

OW_EXPORT(ow_sim_init) int32_t ow_sim_init(void);  // 0 = ok; reads params, loadouts and content
// Pads are Tekken pad bits, the same in every Tekken.
OW_EXPORT(ow_sim_step) void ow_sim_step(uint32_t pad0, uint32_t pad1);
OW_EXPORT(ow_sim_state) void *ow_sim_state(void);
OW_EXPORT(ow_sim_state_size) uint32_t ow_sim_state_size(void);
OW_EXPORT(ow_sim_view) const void *ow_sim_view(void);
OW_EXPORT(ow_sim_view_size) uint32_t ow_sim_view_size(void);

// App exports. Outside rollback, once per rendered frame.

OW_EXPORT(ow_app_init) int32_t ow_app_init(void);
OW_EXPORT(ow_app_frame) void ow_app_frame(float dt);
// A host event: a lobby list, a join result, a match end. kind and its data are not fixed yet.
// (hole app-events :tags (sdk game) :needs app-host) host events to the app have no kinds or payload format.
OW_EXPORT(ow_app_event) void ow_app_event(uint32_t kind, int32_t a, int32_t b);

#endif
