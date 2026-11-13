#include "view.h"

#include <string.h>

#include "sim/fighter.h"
#include "sim/state.h"

static T6ViewHands view_hands(const T6World *w, const T6Fighter *f) {
    const T6Move *move = t6_move_at(w, f->move);
    return (T6ViewHands){
        .right_pose = f->right_hand_pose,
        .left_pose = f->left_hand_pose,
        .posable = f->kind == T6_KIND_FIGHTER,
        .posed = f->hands_posed,
        .new_anim = f->anim_changed != 0,
        .damaging = f->damage != 0,
        .clean_streak = f->streak_clean != 0,
        .thrown = t6_thrown(f->throw.chain),
        .clean_hit = f->clean_hit != 0,
        .frames_to_active = move ? move->first_active - f->frame : 0,
        .hitbox_code = move ? move->hitbox[0] : 0,
    };
}

static T6ViewFace view_face(const T6World *w, const T6Fighter *f) {
    const T6Move *move = t6_move_at(w, f->move);
    return (T6ViewFace){
        .pose = f->face_pose,
        .posable = f->kind == T6_KIND_FIGHTER,
        .posed = f->face_posed,
        .move_started = f->move_start != 0,
        .state_4 = move && (move->flags & T6_MOVE_STATE_4) != 0,
        .hurt_unlooking = move && t6_state_has(move->vuln, STATE_HURT_4) && (move->flags & T6_MOVE_LOOKS) == 0,
        .frames_to_active = move ? move->first_active - f->frame : 0,
        .character_id = f->chara,
        .model_id = f->chara_40,
    };
}

static T6ViewLook view_look(const T6World *w, const T6Fighter *f) {
    return (T6ViewLook){
        .aim = t6_look_aim(w, f),
        .hips = f->look.hips,
        .chest_yaw_change = f->look.chest_yaw.change,
        .chest_pitch_change = f->look.chest_pitch.change,
        .weight = f->look.weight,
    };
}

static T6ViewCamera view_camera(const T6Fighter *f) {
    return (T6ViewCamera){
        .category = f->throw.camera_category,
        .throw_moves = f->throw.chain.moves,
        .hit_landed = f->hit_landed != 0,
        .hit_taken = f->hit_taken != 0,
        .guarded = f->guarded != 0,
        .counter_hit = f->counter_hit != 0,
        .at_wall = f->wall_count > 0,
    };
}

static void view_cues(T6View *view, const T6World *w) {
    const T6CueRing *ring = &w->cues;
    view->cue_count = 0;
    uint32_t first = ring->sent > T6_CUE_RING ? ring->sent - T6_CUE_RING : 0;
    for (uint32_t number = first; number < ring->sent; number++) {
        const T6CueEntry *entry = &ring->entries[number % T6_CUE_RING];
        if (entry->number != number || entry->frame > w->frame || w->frame - entry->frame >= T6_CUE_FRAMES) continue;
        view->cues[view->cue_count++] = *entry;
    }
}

void t6_view_poses(T6View *view, const T6World *w) {
    view->frame = w->frame;
    view_cues(view, w);
    for (int side = 0; side < T6_FIGHTER_COUNT; side++) {
        const T6Fighter *f = w->fighters[side];
        T6ViewFighter *out = &view->fighters[side];
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
        out->camera = view_camera(f);
    }
}
