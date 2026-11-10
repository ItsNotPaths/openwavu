#include "view.h"

#include <string.h>

#include "sim/fighter.h"
#include "sim/state.h"

static T5ViewHands view_hands(const T5World *w, const T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    return (T5ViewHands){
        .right_pose = f->right_hand_pose,
        .left_pose = f->left_hand_pose,
        .posable = f->kind == T5_KIND_FIGHTER,
        .posed = f->hands_posed,
        .new_anim = f->anim_changed != 0,
        .damaging = f->damage != 0,
        .clean_streak = f->streak_clean != 0,
        .thrown = t5_thrown(f->throw.chain),
        .clean_hit = f->clean_hit != 0,
        .frames_to_active = move ? move->first_active - f->frame : 0,
        .hitbox_code = move ? move->hitbox[0] : 0,
    };
}

static T5ViewFace view_face(const T5World *w, const T5Fighter *f) {
    const T5Move *move = t5_move_at(w, f->move);
    return (T5ViewFace){
        .pose = f->face_pose,
        .posable = f->kind == T5_KIND_FIGHTER,
        .posed = f->face_posed,
        .move_started = f->move_start != 0,
        .state_4 = move && (move->flags & T5_MOVE_STATE_4) != 0,
        .hurt_unlooking = move && t5_state_has(move->vuln, STATE_HURT_4) && (move->flags & T5_MOVE_LOOKS) == 0,
        .frames_to_active = move ? move->first_active - f->frame : 0,
        .character_id = f->chara,
        .model_id = f->chara_40,
    };
}

static T5ViewLook view_look(const T5World *w, const T5Fighter *f) {
    return (T5ViewLook){
        .aim = t5_look_aim(w, f),
        .hips = f->look.hips,
        .chest_yaw_change = f->look.chest_yaw.change,
        .chest_pitch_change = f->look.chest_pitch.change,
        .weight = f->look.weight,
    };
}

static void view_cues(T5View *view, const T5World *w) {
    const T5CueRing *ring = &w->cues;
    view->cue_count = 0;
    uint32_t first = ring->sent > T5_CUE_RING ? ring->sent - T5_CUE_RING : 0;
    for (uint32_t number = first; number < ring->sent; number++) {
        const T5CueEntry *entry = &ring->entries[number % T5_CUE_RING];
        if (entry->number != number || entry->frame > w->frame || w->frame - entry->frame >= T5_CUE_FRAMES) continue;
        view->cues[view->cue_count++] = *entry;
    }
}

void t5_view_poses(T5View *view, const T5World *w) {
    view->frame = w->frame;
    view_cues(view, w);
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {
        const T5Fighter *f = w->fighters[side];
        T5ViewFighter *out = &view->fighters[side];
        out->rig = f->rig;
        memcpy(out->parent_a, w->data[f->data]->skeleton.parent_a, sizeof out->parent_a);
        memcpy(out->parent_b, w->data[f->data]->skeleton.parent_b, sizeof out->parent_b);
        out->hands = view_hands(w, f);
        out->face = view_face(w, f);
        out->look = view_look(w, f);
        out->move = f->move;
        out->move_frame = f->frame;
        out->move_yaw = f->move_yaw;
        out->position = f->position;
        out->throw_role = f->throw.chain.role;
    }
}
