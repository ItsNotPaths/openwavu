// Stock TK5 presenter (gamerender.wasm): the fight camera. Per viewer, outside rollback. The camera and the timeline player are SDK libraries; TK5 gives params and data.
#include "gamerender/presenter.h"

// (hole sdk-camera :tags (sdk tk5mod) :sev gap) no general fight camera in the SDK (frames both fighters, keeps the side line, zoom and lag by params), and no TK5 params for it.
// (hole sdk-timeline :tags (sdk tk5mod) :needs (sdk-camera intro-timelines camera-anims cue-ring)) no SDK player for intro, win and outro timelines keyed by the sim phase and phase frame (the fighter anim is a sim move).

static const float DISTANCE = 3.6f;      // metres from the midpoint, along the view normal
static const float FOCUS_HEIGHT = 0.9f;  // metres
static const float RAISE = 0.5f;         // the camera sits this much above the focus
static const float FOV = 0.698132f;      // 40 degrees, vertical

// The tk5decomp demo's follow camera: fixed distance, no zoom or lag.
OwCamera t5_fight_camera(const T5View *view) {
    const T5Mat4 *first = &view->fighters[0].root, *second = &view->fighters[1].root;
    OwVec3 focus = {
        (first->m[3][0] + second->m[3][0]) * 0.5f * MM,
        FOCUS_HEIGHT,
        (first->m[3][2] + second->m[3][2]) * 0.5f * MM,
    };
    OwVec3 position = {focus.x + view->view_normal[0] * DISTANCE, focus.y + RAISE, focus.z + view->view_normal[1] * DISTANCE};
    return (OwCamera){.position = position, .target = focus, .fov = FOV};
}
