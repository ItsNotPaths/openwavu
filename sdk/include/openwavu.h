// openwavu module SDK: the world layout every sim module shares, the seam exports, the host imports.
// Modules are WASM, built from any language that can read these structs. Plain data only.
#ifndef OPENWAVU_H
#define OPENWAVU_H

#include <stdint.h>

#define OW_EXPORT(name) __attribute__((export_name(#name)))
#define OW_IMPORT(name) __attribute__((import_module("openwavu"), import_name(#name)))

// (hole seam-abi :tags sdk :sev blocker) the world layout, the seam exports and the host imports are not defined; they wait on tk5decomp's semantic structs.
typedef struct OwWorld OwWorld;

// (hole sdk-math :tags (sdk net) :needs seam-abi :sev blocker) no deterministic sin/atan2 (port the game's own) or exact fma import; tk5decomp quat.c uses host libm sin() and atan2(), which differ across OS/CPU.
OW_IMPORT(fma) float ow_fma(float a, float b, float c);

// (hole world-extensions :tags sdk :needs seam-abi) a pack can not declare named fields (heat.value, ...) in the world's extension area for other modules and the UI.

#endif
