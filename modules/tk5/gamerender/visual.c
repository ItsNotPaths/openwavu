// The visual state is stepped in place: it is large (a skeleton per fighter) and outside the sim snapshot.
#include "gamerender/visual.h"

#include "sim/fighter.h"
#include "sim/quat.h"

static const float TICK_SECONDS = 1.0f / 60.0f;
enum { MAX_CATCH_UP = 10 };  // a longer jump of the sim frame is a seek

static bool has_hands(const T5VisualFighter *visual, const T5Fighter *f) {  // fighters with hand pose data loaded
    return f->kind == T5_KIND_FIGHTER && visual->banks.poses.clips != NULL;
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
static void pose_rig(T5VisualFighter *visual, const T5World *w, const T5Fighter *f) {
    visual->rig = f->rig;
    if (!has_hands(visual, f)) return;  // no hand data: the sim's rig stays
    for (int bone = 0; bone < FINGER_BONES; bone++) {
        T5Mat4 rotation;
        t5_quat_to_mat(&rotation, &visual->shown.turn[bone]);
        for (int row = 0; row < 3; row++)
            for (int column = 0; column < 4; column++) visual->rig.bones_a[FIRST_FINGER_BONE + bone].local.m[row][column] = rotation.m[row][column];
    }
    const T5Skeleton *skeleton = &w->data[f->data]->skeleton;
    for (int bone = 0; bone < FINGER_BONES; bone++)  // rebuild each finger bone's world matrix
        t5_skel_bone_world(&visual->rig, skeleton, FIRST_FINGER_BONE + bone);
}

static void start(T5Visual *visual, const T5World *w) {
    for (int slot = 0; slot < T5_FIGHTER_COUNT; slot++) {
        T5VisualFighter *fighter = &visual->fighter[slot];
        const T5Fighter *f = w->fighters[slot];
        if (has_hands(fighter, f)) fighter->hands = t5_hands_idle(fighter->hands, fighter->banks, f);  // idle at once
        fighter->from = finger_bones(fighter->hands);  // no old pose to blend from: start at the hands
    }
    visual->started = true;
    visual->frame = w->frame;
    visual->since_tick = 0.0f;
}

static void tick(T5Visual *visual, const T5World *w) {
    for (int slot = 0; slot < T5_FIGHTER_COUNT; slot++) {
        T5VisualFighter *fighter = &visual->fighter[slot];
        const T5Fighter *f = w->fighters[slot];
        fighter->from = fighter->shown;  // the pose on screen is the next blend's start
        if (has_hands(fighter, f)) fighter->hands = t5_hands_tick(fighter->hands, fighter->banks, w, f);  // one sim tick of hands
    }
}

void t5_visual_reset(T5Visual *visual) { visual->started = false; }

void t5_visual_step(T5Visual *visual, const T5World *w, float seconds) {
    uint32_t ticks = w->frame - visual->frame;
    if (!visual->started || w->frame < visual->frame || ticks > MAX_CATCH_UP) {  // first step, a rewind, or a seek: start over
        start(visual, w);
    } else if (ticks > 0) {  // the sim moved on: one tick per new frame
        for (uint32_t done = 0; done < ticks; done++) tick(visual, w);
        visual->frame = w->frame;
        visual->since_tick = 0.0f;
    }
    visual->since_tick += seconds;
    for (int slot = 0; slot < T5_FIGHTER_COUNT; slot++) {
        T5VisualFighter *fighter = &visual->fighter[slot];
        fighter->shown = display_blend(fighter->from, finger_bones(fighter->hands), visual->since_tick);  // blend toward hands
        pose_rig(fighter, w, w->fighters[slot]);
    }
}
