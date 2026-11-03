// Stock TK5 presenter (gamerender.wasm): the 3D scene sent each frame (fighters, stage, camera, effects). Outside rollback; reads the view.
#include "openwavu.h"

// (hole mod-scene :tags tk5mod :needs sim-view :sev gap) no scene from the view: fighter nodes with their bones, the stage node, the camera, no-blend flags on snaps, gameplay class on fighters.
// (hole hand-pose :tags tk5mod :needs (mod-scene visual-in-presenter face-anims)) fighter nodes get the sim pose, not the visual skeleton (fingers, face, eyes, head tilt).
OW_EXPORT(ow_scene_step) void ow_scene_step(void) {}
