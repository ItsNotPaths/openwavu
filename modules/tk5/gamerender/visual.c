// The visual state is stepped in place: it is large (a skeleton per fighter) and outside the sim snapshot.
#include "gamerender/visual.h"

#include "sim/quat.h"

static const float TICK_SECONDS = 1.0f / 60.0f;
enum { MAX_CATCH_UP = 10 };  // a longer jump of the sim frame is a seek

static bool has_hands(const T5VisualFighter *visual, const T5ViewFighter *fighter) {  // fighters with hand pose data loaded
    return fighter->hands.posable && visual->banks.poses.clips != NULL;
}

static bool has_face(const T5VisualFighter *visual, const T5ViewFighter *fighter) {  // fighters with face data loaded
    return fighter->face.posable && visual->faces.poses.clips != NULL;
}

static T5FingerBones finger_bones(T5Hands hands) {
    T5FingerBones bones;
    for (int joint = 0; joint < FINGER_JOINTS; joint++) {  // per joint: right turn, then left turn mirrored
        bones.turn[joint] = hands.right.pose.joint[joint];
        bones.turn[FINGER_JOINTS + joint] = t5_left_finger_turn(hands.left.pose.joint[joint], joint);
    }
    return bones;
}

// Linear over one tick from the pose shown when the tick came; exact on the tick's pose once a tick has passed.
static T5FingerBones display_blend(T5FingerBones from, T5FingerBones to, float since_tick) {
    if (since_tick >= TICK_SECONDS) return to;
    T5FingerBones shown;
    for (int bone = 0; bone < FINGER_BONES; bone++) t5_quat_blend(&shown.turn[bone], since_tick / TICK_SECONDS, &from.turn[bone], &to.turn[bone]);
    return shown;
}

// The finger turns replace the local rotation rows; the bind translations stay.
static void pose_fingers(T5VisualFighter *visual, const T5ViewFighter *fighter) {
    for (int bone = 0; bone < FINGER_BONES; bone++) {
        T5Mat4 rotation;
        t5_quat_to_mat(&rotation, &visual->shown.turn[bone]);
        for (int row = 0; row < 3; row++)
            for (int column = 0; column < 4; column++) visual->rig.bones_a[FIRST_FINGER_BONE + bone].local.m[row][column] = rotation.m[row][column];
    }
    for (int bone = 0; bone < FINGER_BONES; bone++)  // rebuild each finger bone's world matrix
        t5_skel_bone_world(&visual->rig, fighter->parent_a, FIRST_FINGER_BONE + bone);
}

static void pose_rig(T5VisualFighter *visual, const T5ViewFighter *fighter) {
    visual->rig = fighter->rig;  // no hand or face data: the sim's bones stay
    if (has_hands(visual, fighter)) pose_fingers(visual, fighter);
    if (has_face(visual, fighter)) t5_face_pose_rig(&visual->rig, &visual->face, fighter);
}

static void start(T5Visual *visual, const T5View *view) {
    for (int slot = 0; slot < T5_FIGHTER_COUNT; slot++) {
        T5VisualFighter *fighter = &visual->fighter[slot];
        const T5ViewFighter *shown = &view->fighters[slot];
        if (has_hands(fighter, shown)) fighter->hands = t5_hands_idle(fighter->hands, fighter->banks, &shown->hands);  // idle at once
        fighter->from = finger_bones(fighter->hands);  // no old pose to blend from: start at the hands
        if (has_face(fighter, shown)) fighter->face = t5_face_start(fighter->faces);
    }
    visual->started = true;
    visual->frame = view->frame;
    visual->since_tick = 0.0f;
}

static void tick(T5Visual *visual, const T5View *view) {
    for (int slot = 0; slot < T5_FIGHTER_COUNT; slot++) {
        T5VisualFighter *fighter = &visual->fighter[slot];
        const T5ViewFighter *shown = &view->fighters[slot];
        fighter->from = fighter->shown;  // the pose on screen is the next blend's start
        if (has_hands(fighter, shown)) fighter->hands = t5_hands_tick(fighter->hands, fighter->banks, &shown->hands);  // one sim tick of hands
        if (has_face(fighter, shown)) fighter->face = t5_face_tick(fighter->face, fighter->faces, shown, view->phase);
    }
}

void t5_visual_reset(T5Visual *visual) { visual->started = false; }

void t5_visual_step(T5Visual *visual, const T5View *view, float seconds) {
    uint32_t ticks = view->frame - visual->frame;
    if (!visual->started || view->frame < visual->frame || ticks > MAX_CATCH_UP) {  // first step, a rewind, or a seek: start over
        start(visual, view);
    } else if (ticks > 0) {  // the sim moved on: one tick per new frame
        for (uint32_t done = 0; done < ticks; done++) tick(visual, view);
        visual->frame = view->frame;
        visual->since_tick = 0.0f;
    }
    visual->since_tick += seconds;
    for (int slot = 0; slot < T5_FIGHTER_COUNT; slot++) {
        T5VisualFighter *fighter = &visual->fighter[slot];
        fighter->shown = display_blend(fighter->from, finger_bones(fighter->hands), visual->since_tick);  // blend toward hands
        pose_rig(fighter, &view->fighters[slot]);
    }
}

void t5_visual_voice_face(T5Visual *visual, const T5View *view, int side, uint16_t voice_face) {
    T5VisualFighter *fighter = &visual->fighter[side];
    const T5ViewFighter *shown = &view->fighters[side];
    if (visual->started && has_face(fighter, shown)) fighter->face = t5_face_voice(fighter->face, shown, view->phase, voice_face);
}
