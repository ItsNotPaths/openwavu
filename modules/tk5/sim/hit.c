#include "sim/bones.h"
#include "sim/hit.h"

#include <math.h>
#include <stddef.h>

#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/guard.h"
#include "sim/math.h"
#include "sim/projectile.h"
#include "sim/state.h"

static const T5Vec4 *bone_point(const T5Bone *bones, int32_t bone) { return (const T5Vec4 *)bones[bone].world.m[3]; }

// --- hitbox points

// Bones whose hitbox points take the limb offset that the aim of a hand or foot hitbox leaves (limb.c).
static const struct { uint8_t bone, limb; } LIMB_OF_BONE[] = {
    {BONE_R_FOOT, LIMB_R_FOOT}, {BONE_L_FOOT, LIMB_L_FOOT}, {BONE_R_HAND, LIMB_R_HAND},
    {BONE_L_HAND, LIMB_L_HAND}, {BONE_NECK, LIMB_NECK},     {BONE_HEAD, LIMB_HEAD},
};

// A bone point is pushed away from (or toward) the limb's aim in x and z, by the offset's sign in y
void t5_limb_offset(const T5LimbState *limbs, T5HitPoint point, T5Vec4 *position) {
    if (point.kind != HIT_POINT_BONE) return;  // only bone points take a limb offset
    for (size_t entry = 0; entry < sizeof LIMB_OF_BONE / sizeof *LIMB_OF_BONE; entry++) {  // find the limb that moves this bone
        if (LIMB_OF_BONE[entry].bone != point.index) continue;  // not this bone, try the next
        const float *offset = limbs->limb[LIMB_OF_BONE[entry].limb].offset.v;  // how far the limb aim moved it
        float sign = 1.0f;
        if (offset[1] > 0.0f) sign = -1.0f;  // offset up in y flips the direction
        position->x += sign * offset[0];  // shift the point sideways by the aim
        position->z += sign * offset[2];  // and the same in depth
        return;
    }
}

// The point itself; a point of no kind keeps the previous one
static const T5Vec4 *point_at(T5HitPoint point, const T5Vec4 *previous, const T5Bone *bones, const T5SpecialPoints *special) {
    const T5ProjectileState *projectile = &special->projectile;
    switch (point.kind) {
    case HIT_POINT_BONE: return bone_point(bones, point.index);  // point on a bone of the body
    case HIT_POINT_SPECIAL: return &special->point[point.index];  // one of the character's special points
    case HIT_POINT_FIXED: return &special->fixed[point.index];  // one of the fixed body points
    case HIT_POINT_HITSCAN:  // hitscan end: the tail or the tip
        return point.index == HITSCAN_TAIL ? &special->hitscan.tail : &special->hitscan.tip;
    case HIT_POINT_PROJECTILE:  // projectile corner: front or one of the back corners
        if (point.index == PROJECTILE_BACK_LEFT) return &projectile->back_left;
        if (point.index == PROJECTILE_BACK_RIGHT) return &projectile->back_right;
        return &projectile->front;
    default: return previous;  // no point of its own: reuse the previous one
    }
}

// point plus its limb offset; `*carried` carries the point over to the kinds without one
static T5Vec3 hitbox_point(T5HitPoint point, const T5Vec4 **carried, const T5Fighter *f) {
    *carried = point_at(point, *carried, f->rig.bones_b, &f->special);  // pick the point, remembering it for next time
    T5Vec4 position = **carried;
    t5_limb_offset(&f->limbs, point, &position);  // apply the limb aim offset
    return vec3_of(position);
}

// One-bone hitboxes start where the bone was before the motion step.
void t5_hitbox_starts(T5Fighter *f, const T5Move *move) {
    if (f->kind != 0) return;  // only fighters, not extras
    const T5Vec4 *carried = bone_point(f->rig.bones_b, BONE_HIPS);  // start from the hips if the first slot has no point
    for (int32_t slot = 0; slot < f->hitbox_slots; slot++) {  // loop through the hitbox slots of the move
        const T5HitPair *pair = &move->hit_pair[slot];
        if (pair->start.kind == HIT_POINT_NONE)  // no start point: start where the end bone was before the motion step
            f->hit.segment[slot].start = hitbox_point(pair->end, &carried, f);
    }
}

// Ends in the new pose; a two-bone hitbox also takes its start from the partner point.
static void hitbox_ends(T5Fighter *f, const T5Move *move) {
    const T5Vec4 *carried = bone_point(f->rig.bones_b, BONE_HIPS);  // a point of no kind starts from the hips
    for (int32_t slot = 0; slot < f->hitbox_slots; slot++) {  // loop through the hitbox slots of the move
        const T5HitPair *pair = &move->hit_pair[slot];
        f->hit.segment[slot].end = hitbox_point(pair->end, &carried, f);  // the end of each segment is the bone in the new pose
        if (pair->start.kind != HIT_POINT_NONE)  // two-point hitbox: the start comes from its own point
            f->hit.segment[slot].start = hitbox_point(pair->start, &carried, f);
    }
}

// --- special points

// identity, then RotY on the matrix stack, then times identity: the code's yaw matrix
static void yaw_matrix(T5Mat4 *matrix, int32_t angle) {  // turn the matrix by a yaw angle
    T5Mat4 identity;
    t5_mat_identity(&identity);
    t5_mat_identity(matrix);
    t5_mat_rotate_y(matrix, angle);
    t5_mat_multiply(matrix, &identity);
}

// offset * (yaw rotation, translated to `origin`)
static void yaw_point(T5Vec4 *out, int32_t angle, const T5Vec4 *origin, T5Vec4 offset) {
    T5Mat4 matrix;
    yaw_matrix(&matrix, angle);
    for (int lane = 0; lane < 4; lane++) matrix.m[3][lane] = origin->v[lane];  // put the origin in the translation row
    t5_vec_times_mat(out, &offset, &matrix);  // offset turned by the yaw, moved to the origin
}

// x, y, z scaled; w kept
static void scale_xyz(T5Vec4 *vector, float factor) {
    float w = vector->w;  // keep w, scale only x, y and z
    t5_vec_scale(vector, vector, factor);
    vector->w = w;
}

// `direction` turned about y by `angle`, scaled to `length` (w kept)
static T5Vec4 side_of(const T5Vec4 *direction, int32_t angle, float length) {
    T5Mat4 matrix;
    T5Vec4 side;
    yaw_matrix(&matrix, angle);
    t5_vec_times_mat(&side, direction, &matrix);
    scale_xyz(&side, length);
    return side;
}

// The tip of a hitscan that is not flying free sits on its line: `length` along x of its bone.
static void hitscan_tip(T5Hitscan row, T5HitscanState hitscan, const T5Bone *bones, T5SpecialPoints *special) {
    if (hitscan.free_frames == 0)  // not flying free: the tip is `length` along the bone
        t5_vec_times_mat(&special->hitscan.tip, &(T5Vec4){{hitscan.length, 0, 0, 1}}, &bones[row.bone].world);
}

// The back corners of a projectile's hit area: `back` behind its front along its direction, then `side` to each side.
static void projectile_corners(T5Projectile row, T5ProjectileState *projectile) {
    T5Vec4 left = side_of(&projectile->direction, QUARTER_TURN.bits, row.side);
    T5Vec4 right = side_of(&projectile->direction, -QUARTER_TURN.bits, row.side);
    T5Vec4 back = projectile->direction;
    scale_xyz(&back, -row.back);
    t5_vec_add_xyz(&projectile->back_left, &projectile->front, &back);
    t5_vec_add_xyz(&projectile->back_left, &projectile->back_left, &left);
    t5_vec_add_xyz(&projectile->back_right, &projectile->front, &back);
    t5_vec_add_xyz(&projectile->back_right, &projectile->back_right, &right);
}

// The fixed bone points of the character (BODY points of its file)
static void apply_body_points(const T5BodyPoints *points, const T5Bone *bones, T5SpecialPoints *special) {
    for (uint32_t index = 0; index < points->count; index++) {  // loop through the fixed body points of the character
        const T5BodyPoint *body_point = &points->point[index];
        T5Vec4 offset = vec4_of(body_point->offset, 1);
        t5_vec_times_mat(&special->fixed[index], &offset, &bones[body_point->bone].world);  // offset moved by bone pose
    }
}

typedef enum { YAW_FACING, YAW_LOOK } YawSource;

// Special points 0..2: an offset ahead of or behind a bone, turned by the facing or the look direction.
static const struct { uint8_t slot, bone; YawSource yaw; float offset_z; } YAWED_POINTS[] = {
    {SPECIAL_HEAD_AHEAD, BONE_HEAD_END, YAW_FACING, 200.0f},
    {SPECIAL_CHEST_AHEAD, BONE_CHEST, YAW_FACING, 300.0f},
    {SPECIAL_CHEST_BEHIND, BONE_CHEST, YAW_LOOK, -300.0f},
};

// Special points 3..5: a point this far below a foot.
static const struct { uint8_t slot, bone; float below; } FOOT_POINTS[] = {
    {SPECIAL_L_FOOT_LOW, BONE_L_FOOT, 350.0f},
    {SPECIAL_L_FOOT_HIGH, BONE_L_FOOT, 200.0f},
    {SPECIAL_R_FOOT_HIGH, BONE_R_FOOT, 200.0f},
};

static void special_points(T5Fighter *f) {
    const T5Bone *bones = f->rig.bones_b;
    T5SpecialPoints *special = &f->special;
    apply_body_points(&f->body_points, bones, special);
    const T5Hitscan *hitscan = t5_hitscan_of(f);  // hitscan attack data of this move, if any
    const T5Projectile *projectile = t5_projectile_of(f);  // projectile attack data of this move, if any
    if (hitscan != nullptr) hitscan_tip(*hitscan, special->hitscan, bones, special);  // hitscan move: place its tip
    if (projectile != nullptr) projectile_corners(*projectile, &special->projectile);  // projectile move: place its back corners
    int32_t yaw[] = {[YAW_FACING] = t5_rad_to_angle_round(t5_angle65535_to_rad(f->facing)),  // turn angles: facing, look
                     [YAW_LOOK] = t5_rad_to_angle_round(f->look_yaw)};
    for (size_t entry = 0; entry < sizeof YAWED_POINTS / sizeof *YAWED_POINTS; entry++) {  // loop through the bone-based points
        const T5Vec4 offset = {{0, 0, YAWED_POINTS[entry].offset_z, 1}};
        yaw_point(&special->point[YAWED_POINTS[entry].slot], yaw[YAWED_POINTS[entry].yaw],  // turn the offset, put it at the bone
                  bone_point(bones, YAWED_POINTS[entry].bone), offset);
    }
    for (size_t entry = 0; entry < sizeof FOOT_POINTS / sizeof *FOOT_POINTS; entry++) {  // loop through the foot points
        const T5Vec4 below = {{0, FOOT_POINTS[entry].below, 0, 1}};
        t5_vec_subtract(&special->point[FOOT_POINTS[entry].slot], bone_point(bones, FOOT_POINTS[entry].bone), &below);
    }
}

// --- hurtboxes and push points

static void hurtbox_centres(T5Hit *hit, const T5Body *body, const T5Bone *bones) {
    for (int32_t hurtbox_index = 0; hurtbox_index < T5_HURTBOXES; hurtbox_index++) {  // loop through the hurtboxes of the body
        const T5HurtRow *row = &body->hurt[hurtbox_index];
        const float *bone_at = bone_point(bones, row->bone)->v;
        T5Hurtbox *hurtbox = &hit->hurtbox[hurtbox_index];
        hurtbox->x = bone_at[0];
        hurtbox->y = bone_at[1];
        hurtbox->z = bone_at[2];
        if (row->lift != 0.0f) hurtbox->y = bone_at[1] + row->lift;  // unlifted boxes keep a -0
    }
    for (int32_t push_index = 0; push_index < T5_PUSH_POINTS; push_index++) {  // loop through the push points of the body
        const float *bone_at = bone_point(bones, body->push[push_index].bone)->v;
        for (int axis = 0; axis < 3; axis++) hit->push_point[push_index].v[axis] = bone_at[axis];  // copy bone x, y, z
    }
}

void t5_hit_points(T5Fighter *f, const T5Move *move) {  // hitbox and hurtbox positions for this frame
    if (f->kind != 0) return;  // extras do not set them
    special_points(f);  // special points first, the hitbox ends read them
    hitbox_ends(f, move);
    hurtbox_centres(&f->hit, &f->body, f->rig.bones_b);
}

// --- radii

static void set_radii(T5Hit *hit, const T5HurtRow rows[T5_HURTBOXES]) {
    for (int32_t hurtbox_index = 0; hurtbox_index < T5_HURTBOXES; hurtbox_index++) {  // loop through the hurtboxes
        hit->hurtbox[hurtbox_index].radius = (float)rows[hurtbox_index].radius;  // cylinder radius from the body table
        hit->hurtbox[hurtbox_index].radius_squared =  // hit detection compares against the squared radius
            (float)(rows[hurtbox_index].radius * rows[hurtbox_index].radius);
    }
}

void t5_hurtbox_radii(T5Fighter *f) {
    if (f->kind == 0) set_radii(&f->hit, f->body.hurt);  // extras keep their radii
}

T5Vec4 *t5_limb_offset_at(T5LimbState *table, int32_t slot, int32_t limb, int32_t skeleton) {
    return &table[2 * skeleton + slot].limb[limb].offset;  // limb offset of one limb in a skeleton's slot
}

void t5_attack_direction(T5Hit *hit) {
    hit->attack_direction =  // where the attack points: end of the first segment minus its start
        vec3_subtract(hit->segment[0].end, hit->segment[0].start);
}

void t5_incoming_direction(T5Hit *defender, const T5Hit *attacker) {
    defender->incoming_direction = attacker->attack_direction;  // the defender remembers which way the hit came from
}

// --- hit detection

void t5_hit_victims_clear(T5Fighter *f) {
    for (int target = 0; target < T5_HIT_TARGETS; target++) f->hit_targets[target] = -1;  // forget everyone this move has hit
}

void t5_hit_records_clear(const T5World *w, T5Fighter *f) {
    f->hit_taken = 0;  // clear the hit results of the frame
    f->hit_landed = 0;
    f->whiffed = 0;
    for (int record_index = 0; record_index < T5_HIT_RECORDS; record_index++) {  // loop through the hit records
        T5HitRecord *record = &f->records[record_index];
        record->base_damage = 0;
        record->final_damage = 0;
        record->attacker = (int16_t)t5_object_index(w, f);  // the record starts out owned by this fighter
        record->flags &= ~T5_HIT_FLAGS;  // clear the result bits, keep the rest
    }
}

const T5HitSegment *t5_effect_hitboxes(const T5EffectHitboxes *table, int32_t side, int32_t *count) {
    *count = table[side].count;  // hitboxes of the effect on this side
    return table[side].segment;
}

static const float FIXED_ONE = 4096.0f;
static const float FIXED_STEP = 0.000244140625f;  // 1 / 4096

// x, z of the segment from start, along direction, at height y
static void clip(T5Vec3 start, T5Vec3 direction, float y, float *x, float *z) {
    float fraction = ((y - start.y) * FIXED_ONE) / direction.y;  // how far down the segment the height is, in fixed units
    *z = fmaf(direction.z * fraction, FIXED_STEP, start.z);  // walk that far along z
    *x = fmaf(direction.x * fraction, FIXED_STEP, start.x);  // and along x
}

bool t5_hit_geometry(const T5World *w, const T5Fighter *attacker, const T5Fighter *defender, T5HitRecord *out) {
    const T5HitSegment *segment;  // hitbox segments to test
    int32_t count;
    if (t5_move_at(w, attacker->move)->hit_pair[0].end.kind == HIT_POINT_EFFECT) {  // an effect move uses the effect hitboxes
        segment = t5_effect_hitboxes(w->effect_hitboxes, attacker->side_index, &count);
    } else {
        count = attacker->active_hitboxes;  // a normal move uses its own active hitboxes, capped
        if (count > T5_HIT_SEGMENTS) count = T5_HIT_SEGMENTS;
        segment = attacker->hit.segment;
    }
    if (count == 0 || defender->hit_lockout != 0) return false;  // nothing active, or defender locked out: no hit
    for (int32_t segment_index = 0; segment_index < count; segment_index++) {  // loop through the segments of the attack
        T5Vec3 start = segment[segment_index].start, end = segment[segment_index].end;
        T5Vec3 direction = vec3_subtract(end, start);
        float centre_x = (end.x + start.x) * 0.5f;  // middle of the segment in x
        float half_width_x = fabsf(direction.x) * 0.5f;  // half the segment's reach in x
        for (int16_t hurtbox_index = 0; hurtbox_index < T5_HURTBOXES; hurtbox_index++) {  // loop through the defender's hurtboxes
            const T5Hurtbox *hurtbox = &defender->hit.hurtbox[hurtbox_index];
            float radius = hurtbox->radius;
            if (fabsf(hurtbox->x - centre_x) > half_width_x + radius) continue;  // quick reject: too far off in x
            if (fabsf(hurtbox->z - (end.z + start.z) * 0.5f) > fmaf(fabsf(direction.z), 0.5f, radius))  // too far off in z
                continue;
            if (fabsf(hurtbox->y - (end.y + start.y) * 0.5f) > fmaf(fabsf(direction.y), 0.5f, radius))  // too far off in y
                continue;
            // the part of the segment inside the hurtbox's height, in XZ
            float start_x = start.x, start_z = start.z, end_x = end.x, end_z = end.z;
            float top = radius + hurtbox->y;  // the hurtbox is a cylinder: top and bottom heights
            float bottom = hurtbox->y - radius;
            if (end.y < start.y) {  // segment goes down: cut off the parts above the top and below the bottom
                if (start.y > top) clip(start, direction, top, &start_x, &start_z);
                if (end.y < bottom) clip(start, direction, bottom, &end_x, &end_z);
            } else if (end.y != start.y) {  // segment goes up: cut off the parts above the top and below the bottom
                if (end.y > top) clip(start, direction, top, &end_x, &end_z);
                if (start.y < bottom) clip(start, direction, bottom, &start_x, &start_z);
            }
            float edge_x = end_x - start_x;  // now compare in the ground plane: the cut segment against the cylinder circle
            float edge_z = end_z - start_z;
            float offset_z = start_z - hurtbox->z;
            float offset_x = start_x - hurtbox->x;
            float length = fmaf(edge_x, edge_x, edge_z * edge_z);
            float projection = -fmaf(edge_x, offset_x, offset_z * edge_z);
            float distance;
            if (length == 0.0f || projection < 0.0f) {  // no length, or the closest point is the start
                distance = fmaf(offset_x, offset_x, offset_z * offset_z);
            } else if (!(projection >= 0.0f) || !(length >= projection)) {  // the closest point is the end
                float nearest_x = end_x - hurtbox->x;
                float nearest_z = end_z - hurtbox->z;
                distance = fmaf(nearest_x, nearest_x, nearest_z * nearest_z);
            } else {  // the closest point is inside the segment
                float nearest_z = offset_z + (projection * edge_z) / length;
                float nearest_x = offset_x + (edge_x * projection) / length;
                distance = fmaf(nearest_x, nearest_x, nearest_z * nearest_z);
            }
            if (distance <= hurtbox->radius_squared) {  // segment touches the circle: it hits this hurtbox
                out->hurtbox = hurtbox_index;  // remember which hurtbox was hit
                out->point = end;  // hit point is the end of the segment
                out->direction = vec3_subtract(end, start);  // and the direction the segment travels
                return true;
            }
        }
    }
    return false;
}

// Lows miss a jumping fighter: in classes 23 and 25 while the window of their move runs (up to a few frames short of its end), in
// classes 24 and 26 while they are airborne.
static bool jumps_over_low(const T5Fighter *defender, const T5Move *defender_move) {
    bool window_class = defender->state_class == CLASS_JUMP_A || defender->state_class == CLASS_AIR_GUARD_FIRST;
    bool air_class = defender->state_class == CLASS_JUMP_B || defender->state_class == CLASS_AIR_GUARD_LAST;
    bool in_window = defender_move->window_start <= defender->frame && defender->frame <= (int32_t)defender_move->window_end - JUMP_WINDOW_END_CUT.ticks;
    return (window_class && in_window) || (air_class && defender->in_air_window != 0);
}

static bool low_attack(uint32_t level) { return level == HIT_LEVEL_LOW_A || level == HIT_LEVEL_LOW_B || level == HIT_LEVEL_LOW_C; }

// The heights at which the attacker's attack can hit the defender; none when they evade it.
static uint32_t reach(const T5Fighter *attacker, const T5Fighter *defender, const T5Move *defender_move) {
    uint32_t level = attacker->hit_level;  // the attack height
    if (low_attack(level) && jumps_over_low(defender, defender_move)) return 0;  // low attacks go over a jumping defender
    bool move_off_ground =  // the state of the move, not of the fighter
        defender->in_air_window != 0 || t5_state_has(defender_move->vuln, STATE_LAUNCHED);
    if (level == HIT_LEVEL_AIR_ONLY && !move_off_ground) return 0;  // an air-only attack needs a defender who is off the ground
    if (defender->stance_rule == STANCE_HELD_LOW) level |= STATE_HURT_1;  // a held low stance makes every attack hit low too
    return defender->state & level & STATE_HURT_BITS;  // the heights that both the attack and the defender's body allow
}

static T5HitRecord *free_record(T5Fighter *defender) {
    for (int record_index = 0; record_index < T5_HIT_RECORDS; record_index++)  // loop through the records of the defender
        if ((defender->records[record_index].flags & T5_HIT_LIVE) == 0)  // first record that is not live is free
            return &defender->records[record_index];
    return NULL;  // no free record
}

// A fighter that does not update (slow motion) stops the hits of every fighter.
static bool fighters_update(const T5World *w) {
    for (int side = 0; side < T5_FIGHTER_COUNT; side++)
        if (!w->fighters[side]->force_update && w->fighters[side]->update_divider == T5_UPDATE_INACTIVE)  // does not update
            return false;
    return true;
}

// A move hits each target once.
static bool already_hit(const T5World *w, const T5Fighter *attacker, const T5Fighter *defender) {
    for (int target = 0; target < T5_HIT_TARGETS; target++)
        if (t5_object(w, attacker->hit_targets[target]) == defender) return true;  // defender is already a target of this move
    return false;
}

static void land_hit(const T5World *w, T5Fighter *attacker, T5Fighter *defender, T5HitRecord *record) {
    for (int target = 0; target < T5_HIT_TARGETS; target++) {  // loop through the targets of the attack
        if (attacker->hit_targets[target] < 0) {  // first empty slot
            attacker->hit_targets[target] = (int16_t)t5_object_index(w, defender);  // the move cannot hit them again
            break;
        }
    }
    defender->hit_taken = 1;  // defender took a hit
    defender->hit_this_move = 1;  // and remembers it for this move
    attacker->hit_landed = 1;  // attacker landed a hit
    attacker->landed_this_move = 1;  // landed in this move, kept until the move changes
    attacker->landed_since_move_start = 1;
    record->attacker = (int16_t)t5_object_index(w, attacker);  // the record belongs to the attacker
    record->flags |= T5_HIT_LIVE;  // mark the record as a real hit
    if (attacker->damage != 0 || defender->in_air_window != 0)  // damaging or juggle hit: lock out more hits for a few frames
        defender->hit_lockout = (int16_t)HIT_LOCKOUT.ticks;
}

// The attack whiffs when its last active frame passes with no hit.
void t5_hit_register(T5World *w, T5Fighter *attacker, T5Fighter *defender) {
    const T5Move *attacker_move = t5_move_at(w, attacker->move);  // moves of both sides
    const T5Move *defender_move = t5_move_at(w, defender->move);
    T5HitRecord *record = free_record(defender);  // a free record for the hit
    bool open = record != NULL  // the hit can open: free record, fighters updating, target not yet hit
        && (attacker->kind != T5_KIND_FIGHTER || fighters_update(w)) && !already_hit(w, attacker, defender);
    if (open && reach(attacker, defender, defender_move) != 0  // height and shape both fit: the hit lands
        && t5_hit_geometry(w, attacker, defender, record))
        land_hit(w, attacker, defender, record);
    if (attacker_move->last_active == attacker->frame && attacker->landed_this_move == 0)  // last active frame, nothing landed
        attacker->whiffed = 1;
}

void t5_hit_detection_pass(T5World *w) {
    T5Fighter *first = w->fighters[0], *second = w->fighters[1];  // the two fighters
    t5_hit_register(w, first, second);  // first attacks second
    t5_hit_register(w, second, first);  // second attacks first
    for (int32_t extra = 0; extra < t5_extra_count(w); extra++) {  // loop through the extra objects
        t5_hit_register(w, first, t5_extra_entry(w, extra));  // both fighters can hit each extra
        t5_hit_register(w, second, t5_extra_entry(w, extra));
    }
}

static void records_clear_of(T5World *w, T5Fighter *f) { t5_hit_records_clear(w, f); }
static void attack_direction_of(T5World *w, T5Fighter *f) { (void)w; t5_attack_direction(&f->hit); }
static void hitbox_starts_of(T5World *w, T5Fighter *f) { t5_hitbox_starts(f, t5_move_at(w, f->move)); }
static void hit_points_of(T5World *w, T5Fighter *f) { t5_hit_points(f, t5_move_at(w, f->move)); }

void t5_hit_records_pass(T5World *w) { t5_each_object(w, records_clear_of); }  // clear the hit records of all objects

static void results_clear_of(T5World *w, T5Fighter *f) {
    (void)w;
    f->ko = 0;  // clear the results of the frame for this object
    f->damage_absolute = 0;
    f->guarded = 0;
    f->clean_hit = 0;
    f->counter_hit = 0;
}

void t5_clear_results_pass(T5World *w) { t5_each_object(w, results_clear_of); }  // clear the results of all objects

void t5_attack_direction_pass(T5World *w) { t5_each_object(w, attack_direction_of); }  // attack direction of all objects

void t5_hitbox_starts_pass(T5World *w) { t5_each_object(w, hitbox_starts_of); }  // hitbox starts of all objects

void t5_hurtboxes_pass(T5World *w) { t5_each_object(w, hit_points_of); }  // hurtbox and hitbox points of all objects
