// TK5 input seam: pad words -> history -> command match (input.md).
#include "openwavu.h"

// (hole mod-input :tags tk5mod :needs seam-abi :sev blocker) split out in tk5decomp (seam_input.c), not built as a module; it still reads T5Player through pointers.
OW_EXPORT(ow_input_step) void ow_input_step(OwWorld *w) {}
