// openwavu module SDK: the world layout every sim module shares, the seam exports, the host imports.
// Modules are WASM, built from any language that can read these structs. Plain data only.
#ifndef OPENWAVU_H
#define OPENWAVU_H

#include <stdint.h>

#define OW_EXPORT(name) __attribute__((export_name(#name)))
#define OW_IMPORT(name) __attribute__((import_module("openwavu"), import_name(#name)))

// (hole seam-abi :tags sdk :sev blocker) draft v0 is tk5decomp sim/include/t5/world_abi.h, not copied here; open: the rules layout, where module private data lives, and T5Player still stores pointers.
typedef struct OwWorld OwWorld;

// (hole world-extensions :tags sdk :needs seam-abi) a pack can not declare named fields (heat.value, ...) in the world's extension area for other modules and the UI.

#endif
