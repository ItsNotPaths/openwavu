// openwavu module SDK: the host imports (net, saves, content, input, audio, render, fx, rand, params,
// events) and the exports of the sim and app modules. Each module owns its memory.
#ifndef OPENWAVU_H
#define OPENWAVU_H

#include <stdint.h>

#define OW_EXPORT(name) __attribute__((export_name(#name)))
#define OW_IMPORT(name) __attribute__((import_module("openwavu"), import_name(#name)))

// (hole seam-abi :tags sdk :sev blocker) no host imports or module exports yet; open: the sim exports (init with params and loadouts, step, ow_view) and the app exports (frame, host events).
typedef struct OwWorld OwWorld;


#endif
