// TK5 camera seam: the fight camera. Presentation.
#include "openwavu.h"

// (hole mod-camera :tags tk5mod :needs (render-api seam-abi) :sev gap) no default camera module.
// (hole intro-playback :tags tk5mod :needs (mod-camera intro-timelines camera-anims)) intro, win and outro timelines are not played before and after rounds (presentation, no rollback).
OW_EXPORT(ow_camera_step) void ow_camera_step(OwWorld *w) {}
