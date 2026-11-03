// Stock TK5 presenter (gamerender.wasm): the fight camera. Per viewer, outside rollback. The camera and the timeline player are SDK libraries; TK5 gives params and data.
#include "openwavu.h"

// (hole sdk-camera :tags (sdk tk5mod) :needs (scene-api sim-view) :sev gap) no general fight camera in the SDK (frames both fighters, keeps the side line, zoom and lag by params), and no TK5 params for it.
// (hole sdk-timeline :tags (sdk tk5mod) :needs (sdk-camera intro-timelines camera-anims cue-ring)) no SDK player for intro, win and outro timelines keyed by the sim phase and phase frame (the fighter anim is a sim move).
OW_EXPORT(ow_camera_step) void ow_camera_step(void) {}
