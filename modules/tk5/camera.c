// Stock TK5 app: the fight camera. Per viewer, outside rollback.
#include "openwavu.h"

// (hole mod-camera :tags tk5mod :needs (render-api sim-view) :sev gap) no stock fight camera.
// (hole intro-playback :tags tk5mod :needs (mod-camera intro-timelines camera-anims)) intro, win and outro timelines are not played before and after rounds (presentation, no rollback).
OW_EXPORT(ow_camera_step) void ow_camera_step(OwWorld *w) {}
