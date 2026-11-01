// Stage walls (code-map section 8): the six joint spheres of a fighter move against the wall quads of the stage. A wall
// pushes the sphere out; the push moves the fighter (t5_wall_apply).
#include <math.h>
#include <string.h>

#include "sim/bones.h"
#include "sim/collision.h"
#include "sim/stage.h"
#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/guard.h"
#include "sim/math.h"
#include "sim/units.h"

// The spheres sit on these bones of skeleton A.
enum WallSphere { WALL_HIPS, WALL_L_FOOT, WALL_R_FOOT, WALL_L_HAND, WALL_R_HAND, WALL_NECK, WALL_SPHERES };
static const int8_t WALL_BONE[WALL_SPHERES] = {BONE_HIPS, BONE_L_FOOT, BONE_R_FOOT, BONE_L_HAND, BONE_R_HAND, BONE_NECK};

enum { ANY_SPHERE = -1 };      // T5Fighter.stage_hit_sphere: no sphere has hit a stage object yet
enum { WALL_SLIDE_AUTO = -1 }; // T5Fighter.wall_slide_mode: slide unless the fighter is in a hit reaction
enum { STAGE_HIT_SLOTS = 8 };  // the stage objects remembered in stage_hit_ids; the count stops at one less
static constexpr float STAGE_HIT_DAMAGE_SCALE = 1.5f;

// The side of the wall at which a sphere touched, as bits of wall_bits (requirements 128..141). The windows are
// ranges of the angle between the body and the wall, 65536 steps a turn; a window that starts above its end wraps.
enum : uint8_t { WALL_SIDE_45 = 1 << 0, WALL_SIDE_135 = 1 << 1, WALL_SIDE_225 = 1 << 2, WALL_SIDE_315 = 1 << 3, WALL_FACING = 1 << 5 };
typedef struct { uint8_t bit; int32_t first, last; } WallSide;
static const WallSide WALL_SIDES[] = {
    {WALL_SIDE_45, 64624, 17295}, {WALL_SIDE_135, 15473, 33679}, {WALL_SIDE_225, 31857, 50063}, {WALL_SIDE_315, 48241, 911},
};

[[nodiscard]] static bool in_window(int32_t angle, int32_t first, int32_t last) {
    if (first <= last) return first <= angle && angle <= last;
    return angle >= first || angle <= last;
}

static float sphere_radius(int32_t sphere) {  // the neck sphere is bigger than the rest
    if (sphere == WALL_NECK) return WALL_RADIUS_NECK;
    return WALL_RADIUS;
}

T5Vec4 t5_plane_project(T5Vec4 plane_normal, T5Vec4 on_plane, T5Vec4 point) {
    T5Vec3 normal = vec3_of(plane_normal);
    float normal_dot_plane = vec3_dot(normal, vec3_of(on_plane));  // distance values of the plane and the point along the normal
    float normal_dot_point = vec3_dot(normal, vec3_of(point));
    float normal_squared = vec3_dot(normal, normal);
    float scale = (normal_dot_plane - normal_dot_point) / normal_squared;  // how far along the normal to reach the plane
    T5Vec4 toward = {{scale * plane_normal.x, scale * plane_normal.y, scale * plane_normal.z, 1.0f}};
    T5Vec4 out = vec4_add(toward, point);  // the point moved straight onto the plane
    out.w = 1.0f;
    return out;
}

T5PlaneHit t5_plane_intersect(T5Vec4 plane_normal, T5Vec4 on_plane, T5Vec4 now, T5Vec4 before) {
    T5Vec4 direction = vec4_normalized(vec4_subtract(now, before));  // the way the point travelled this move
    plane_normal = vec4_normalized(plane_normal);
    float plane_offset = -vec3_dot(vec3_of(plane_normal), vec3_of(on_plane));
    float normal_dot_now = vec3_dot(vec3_of(plane_normal), vec3_of(now));
    float normal_dot_direction = vec3_dot(vec3_of(plane_normal), vec3_of(direction));
    if (normal_dot_direction == 0.0f)  // travel runs along the plane: project the point onto it
        return (T5PlaneHit){t5_plane_project(plane_normal, on_plane, now), plane_normal};
    float scale = -(plane_offset + normal_dot_now) / normal_dot_direction;  // how far to go along the travel to reach the plane
    T5Vec4 point = {{fmaf(scale, direction.x, now.x), fmaf(scale, direction.y, now.y),
                     fmaf(scale, direction.z, now.z), 1.0f}};
    return (T5PlaneHit){point, plane_normal};
}

// The quad and the point turned into the frame of the wall (its normal along an axis).
bool t5_wall_span(const T5Mat4 *quad, T5Vec4 normal, T5Vec4 point, float stage_depth) {
    float angle = t5_wrap_pi(t5_fast_atan2(normal.z, normal.x) - T5_HALF_PI);  // turn that puts the wall normal on an axis
    T5Mat4 rotation, corners;
    t5_mat_identity(&rotation);
    t5_mat_rotate_y(&rotation, t5_rad_to_angle_round(angle));
    corners = rotation;  // corners start as the turn, then take the quad
    t5_mat_multiply(&corners, quad);
    T5Vec4 turned;
    t5_vec_times_mat(&turned, &point, &rotation);  // turn the point the same way
    float min_x = stage_depth, min_y = stage_depth;
    float max_x = -stage_depth, max_y = -stage_depth;
    for (int corner = 0; corner < 4; corner++) {  // loop through the four corners: find the lowest and highest x and y
        float x = corners.m[corner][0], y = corners.m[corner][1];
        if (x < min_x) min_x = x;
        if (!(x < max_x)) max_x = x;  // not below: a NaN counts as above
        if (y < min_y) min_y = y;
        if (!(y < max_y)) max_y = y;
    }
    return max_y - min_y >= WALL_MIN_HEIGHT &&  // the wall is tall enough and
           min_x <= turned.x && turned.x <= max_x;  // the point lies within its width
}

// The sphere's crossing of the quad's plane, moved out by the radius: shared start of the quad and the edge tests.
typedef struct {
    bool touches;
    T5Vec4 now, normal, offset, shifted_first, hit;
    T5Mat4 expanded;  // the quad grown by the radius
} WallContact;

static T5Vec4 corner_of(const T5WallQuad *quad, int corner) {
    return (T5Vec4){{quad->corners.m[corner][0], quad->corners.m[corner][1],  // one corner of the quad as a vector
                     quad->corners.m[corner][2], quad->corners.m[corner][3]}};
}

static void set_row(T5Mat4 *matrix, int index, T5Vec4 row) { memcpy(matrix->m[index], row.v, sizeof row.v); }

static WallContact wall_contact(const T5Fighter *f, const T5WallQuad *quad, T5Vec4 point, int32_t sphere, float stage_depth) {
    WallContact contact = {};
    float radius = sphere_radius(sphere);
    float height = f->previous_sphere[WALL_HIPS].y;  // both ends of the move are taken at the height of the hips
    T5Vec4 before = f->previous_sphere[sphere];
    before.y = height;
    contact.now = point;
    contact.now.y = height;
    contact.normal = vec4_normalized((T5Vec4){{-quad->normal.x,  // wall normal flat, pointing the other way
                                               0.0f, -quad->normal.z, 1.0f}});
    contact.offset = vec4_scale(contact.normal, -radius);  // the wall plane is moved out by the sphere radius
    contact.offset.w = 0.0f;
    T5Vec4 shifted[4];
    shifted[0] = vec4_add(corner_of(quad, 0), contact.offset);
    T5Vec4 delta = vec4_subtract(shifted[0], contact.now);  // distance now from the moved plane (negative: behind)
    delta.y = 0.0f;
    float now_depth = vec3_dot(vec3_of(contact.normal), vec3_of(delta));
    delta = vec4_subtract(shifted[0], before);  // same for where the sphere was before the move
    delta.y = 0.0f;
    float before_depth = vec3_dot(vec3_of(contact.normal), vec3_of(delta));
    if (!(now_depth * before_depth <= 0.0f) ||  // no contact unless the sphere crossed the plane
        !(now_depth <= 0.0f))  // and now stands behind it
        return contact;
    for (int corner = 1; corner < 4; corner++)  // move the other three corners out the same way
        shifted[corner] = vec4_add(corner_of(quad, corner), contact.offset);
    T5Vec4 travel = vec4_normalized(vec4_subtract(before, contact.now));  // the way the sphere travelled
    if (vec3_dot(vec3_of(contact.normal), vec3_of(travel)) == 0.0f) {  // travel along the wall: press sphere onto plane
        contact.hit = t5_plane_project(contact.normal, shifted[0], contact.now);
    } else {  // travel crosses the wall: hit point is where the path meets the plane
        T5PlaneHit crossing = t5_plane_intersect(contact.normal, shifted[0], before, contact.now);
        contact.hit = crossing.point;
        contact.normal = crossing.normal;
    }
    float min_x = stage_depth, max_x = -stage_depth,  // flat bounds of the quad, start empty
          min_z = stage_depth, max_z = -stage_depth;
    for (int corner = 0; corner < 4; corner++) {  // loop through the corners: find the flat bounds of the quad
        float x = quad->corners.m[corner][0], z = quad->corners.m[corner][2];
        if (max_x < x) max_x = x;
        if (min_x > x) min_x = x;
        if (max_z < z) max_z = z;
        if (min_z > z) min_z = z;
    }
    float centre_x = (min_x + max_x) * 0.5f;  // middle of the quad, used to grow it outward
    float centre_z = (max_z + min_z) * 0.5f;
    for (int corner = 0; corner < 4; corner++) {  // loop through the corners: push each one outward from the middle by the radius
        T5Vec4 outward = {{quad->corners.m[corner][0] - centre_x, 0.0f, quad->corners.m[corner][2] - centre_z, 1.0f}};
        outward = vec4_scale(vec4_normalized(outward), radius);
        set_row(&contact.expanded, corner, vec4_add(shifted[corner], outward));
    }
    contact.shifted_first = shifted[0];
    contact.touches = t5_wall_span(&contact.expanded,  // touching if the hit point is within the grown quad
                                   contact.normal, contact.hit, stage_depth);
    return contact;
}

bool t5_wall_test(const T5Fighter *f, const T5WallQuad *quad, T5Vec4 point, int32_t sphere, float stage_depth) {
    return wall_contact(f, quad, point, sphere, stage_depth).touches;
}

// An angle as it was in the binary game: 65536 steps a turn, from 0 (a heading), as a signed 16 bit value.
static int16_t heading(float radians) {  // wrap into 0 to a full turn first
    radians = t5_wrap_pi(radians);
    if (radians < 0.0f) radians += T5_TWO_PI;
    return t5_rad_to_angle65535(radians);
}

// The size of a signed angle (ones' complement for the negative).
static uint16_t angle_size(int16_t angle) {
    if (angle < 0) return (uint16_t)~angle;
    return (uint16_t)angle;
}

static uint8_t side_bits(int32_t side_angle) {  // collect the side bits whose angle window holds the angle
    uint8_t bits = 0;
    for (size_t index = 0; index < sizeof WALL_SIDES / sizeof *WALL_SIDES; index++)
        if (in_window(side_angle, WALL_SIDES[index].first, WALL_SIDES[index].last)) bits |= WALL_SIDES[index].bit;
    return bits;
}

// The fighter keeps up to one wall angle: the first, and a later different one replaces the second slot.
static void note_wall_angle(T5Fighter *f, int16_t wall_angle) {
    bool unique = true;
    for (int slot_index = 0; slot_index < f->wall_count; slot_index++)  // check whether this wall angle is already noted
        if (f->wall_angles[slot_index] == wall_angle) unique = false;
    if (f->wall_count > 0 && !unique) return;  // same angle again: nothing new
    int16_t slot = f->wall_count;
    f->wall_count = (int16_t)(slot + 1);
    f->wall_angles[slot] = wall_angle;  // store the angle
    if (f->wall_count > 1) f->wall_count = 1;  // count never goes above one, so the next new angle overwrites the second slot
}

T5WallHit t5_wall_push(T5Fighter *f, const T5WallQuad *quad, T5Vec4 point, int32_t sphere, float stage_depth) {
    WallContact contact = wall_contact(f, quad, point, sphere, stage_depth);
    if (!contact.touches) return (T5WallHit){false, point};  // no wall touched: the sphere stays where it is
    T5Vec4 normal = contact.normal, hit = contact.hit;
    bool slide = f->wall_slide_mode != 0;  // slide along the wall instead of stopping dead
    if (f->wall_slide_mode == WALL_SLIDE_AUTO) slide = f->hit_this_move == 0;  // auto: slide unless hit this move
    if (slide) hit = t5_plane_project(normal, contact.shifted_first, contact.now);  // slide: press onto the moved plane
    normal = (T5Vec4){{-normal.x, -normal.y, -normal.z, normal.w}};  // flip the normal to face out of the wall
    hit = vec4_add(hit, normal);  // nudge the result out by one unit so it stands clear
    int32_t body_heading = heading(f->body_yaw);  // the way the fighter faces
    int32_t normal_heading = heading(t5_fast_atan2(normal.z, normal.x));  // the way the wall faces
    int32_t side_angle = (-body_heading - normal_heading - EIGHTH_TURN.bits) % 65536;  // body to wall angle, for side bits
    if (side_angle < 0) side_angle += STOCK_STEPS_PER_TURN;
    int16_t wall_angle =  // the heading along the wall
        (int16_t)(heading(t5_fast_atan2(-normal.z, normal.x)) + QUARTER_TURN.bits);
    int32_t facing = body_heading;  // which way the fighter counts as facing
    if (f->damage == 0 || t5_in_throw(f->throw.chain) ||  // no damage, in a throw, or a wall slide: pushback heading
        f->attack_kind == ATTACK_KIND_KEEPS_HEADING)
        facing = f->pushback_angle_start;
    uint16_t away_from_wall =  // how far from facing the wall (0 = straight at it)
        angle_size((int16_t)(facing - wall_angle - HALF_TURN.bits));
    T5Vec4 moved = vec4_subtract(hit, contact.now);  // the push this wall gives the sphere
    T5Vec4 base = vec4_of(f->base_position, f->base_position_w);  // where the fighter stands now
    base = vec4_add(base, moved);  // where the fighter would stand after the push
    base.w = 1.0f;
    normal = (T5Vec4){{-normal.x, normal.y, -normal.z, 1.0f}};
    if (!t5_wall_span(&contact.expanded, normal, base, stage_depth))  // pushed spot off the wall's width: not facing
        away_from_wall = UINT16_MAX;
    note_wall_angle(f, wall_angle);  // remember this wall's angle
    bool facing_wall = away_from_wall < WALL_FACING_LIMIT;  // facing the wall within about 50 degrees
    if (facing_wall) {  // facing the wall: update the strength of facing
        float factor =  // closer to facing straight gives a larger factor, at most 1
            WALL_FACING_FULL - (float)away_from_wall / WALL_FACING_SCALE;
        if (factor > 1.0f) factor = 1.0f;
        if (factor > f->wall_factor) f->wall_factor = factor;  // keep the strongest facing factor
        if (factor == f->wall_factor) f->wall_angle = wall_angle;  // the wall giving the strongest facing sets the wall angle
    }
    uint8_t bits = side_bits(side_angle);
    if (bits != 0 && facing_wall) bits |= WALL_FACING;  // mark the contact as facing the wall
    int16_t slot = f->wall_history_count;
    f->wall_history_count = (int16_t)(slot + 1);
    f->wall_bits[sphere] |= (int8_t)bits;  // record the touched side for this sphere
    f->wall_history[slot % WALL_HISTORY] = vec4_subtract(hit, contact.offset);  // ring of the last few contact points
    return (T5WallHit){true, hit};
}

void t5_wall_clear(T5Fighter *f) {
    f->wall_factor = 0.0f;
    f->wall_history_count = 0;
    f->wall_count = 0;
    for (int sphere = 0; sphere < WALL_SPHERES; sphere++) f->wall_bits[sphere] = 0;  // no sides touched
    f->stage_hit_new = 0;
}

// Stage object hits: only the fighter side is kept. The effect slot, the pending hit table,
// the sound and the practice stats are outside the sim.
static void stage_hit(T5Fighter *f, uint32_t event, int sphere) {
    int32_t power = (int32_t)((float)f->damage * STAGE_HIT_DAMAGE_SCALE);  // damage taken, or the stage minimum if higher
    if (power < f->stage_hit_power) power = f->stage_hit_power;
    if (power == 0) return;  // no power: the object is not hit
    int16_t used = f->stage_hit_count;
    bool fresh = true;  // fresh means this object is not in the list yet
    for (int slot = 0; slot < used; slot++) fresh &= f->stage_hit_ids[slot] != event;
    if ((f->stage_hit_sphere == ANY_SPHERE || f->stage_hit_sphere == sphere) &&  // first hitting sphere only,
        fresh) {  // and only a new object
        if (used >= 0 && used < STAGE_HIT_SLOTS) f->stage_hit_ids[used] = event;  // remember the object if there is room
        f->stage_hit_count = (int16_t)(used + 1);
        f->stage_hit_sphere = (int16_t)sphere;
        if (f->stage_hit_count > STAGE_HIT_SLOTS - 1)  // count stops one below the slots
            f->stage_hit_count = STAGE_HIT_SLOTS - 1;
    }
    if (!f->stage_hit_this_move) f->stage_hit_new = 1;  // first stage hit of this move: flag it as new
    f->stage_hit_this_move = 1;
}

static void average_wall_angle(T5Fighter *f) {
    int16_t first_angle = f->wall_angles[0], second_angle = f->wall_angles[1];
    if (f->wall_count <= 1) {  // one wall angle only: use it as is
        f->wall_angle = first_angle;
        return;
    }
    uint16_t first_minus_second = (uint16_t)(first_angle - second_angle);  // turn from each angle to the other
    uint16_t second_minus_first = (uint16_t)(second_angle - first_angle);
    if (first_minus_second < second_minus_first)  // take the angle halfway, by the shorter turn
        f->wall_angle = (int16_t)(first_angle - (first_minus_second >> 1));
    else f->wall_angle = (int16_t)(second_angle - (second_minus_first >> 1));
}

// The positions of the six joint spheres.
typedef struct { T5Vec4 positions[WALL_SPHERES]; } WallSpheres;

static WallSpheres move_spheres(WallSpheres spheres, T5Vec4 offset) {
    for (int sphere = 0; sphere < WALL_SPHERES; sphere++) spheres.positions[sphere] = vec4_add(spheres.positions[sphere], offset);
    return spheres;
}

// The walls a sphere meets: every wall quad, none while the floor is off.
static int32_t wall_count(const T5World *w) { return t5_floor_disabled(w) ? 0 : w->stage->wall_count; }

// One pass over every wall quad: the sphere moves out of each quad it crosses, in order.
typedef struct { T5Vec4 position; bool pushed; } SpherePass;

static SpherePass push_out_once(const T5World *w, T5Fighter *f, T5Vec4 position, int sphere) {
    bool pushed = false;
    for (int32_t wall = 0; wall < wall_count(w); wall++) {
        T5WallHit hit = t5_wall_push(f, &w->stage->walls[wall], position, sphere, w->stage_depth);  // push out if it crosses
        if (!hit.hit) continue;  // not touching this quad
        position = hit.position;
        pushed = true;
    }
    return (SpherePass){position, pushed};
}

// Passes over the walls until the sphere stands clear (WALL_SOLVE_CAP passes at most).
static SpherePass push_out_of_walls(const T5World *w, T5Fighter *f, T5Vec4 position, int sphere) {
    bool pushed = false;
    for (int pass = 0; pass < WALL_SOLVE_CAP; pass++) {
        SpherePass once = push_out_once(w, f, position, sphere);  // one pass over all walls
        if (!once.pushed) break;  // clear of every wall: done
        position = once.position;
        pushed = true;
    }
    return (SpherePass){position, pushed};
}

// The walls with a hit event that the sphere (before the push) touches count as stage hits.
static void note_stage_hits(const T5World *w, T5Fighter *f, T5Vec4 position, int sphere) {
    for (int32_t wall = 0; wall < wall_count(w); wall++) {
        const T5WallQuad *quad = &w->stage->walls[wall];
        int32_t event = w->stage->surfaces[quad->surface].hit_event;
        if (event && t5_wall_test(f, quad, position, sphere, w->stage_depth)) stage_hit(f, (uint32_t)event, sphere);
    }
}

// One joint sphere pushed out of the walls; all six spheres then move by its push in the ground plane.
typedef struct { WallSpheres spheres; bool pushed; } SphereSolve;

static SphereSolve solve_sphere(const T5World *w, T5Fighter *f, WallSpheres spheres, int sphere) {
    T5Vec4 now = spheres.positions[sphere];
    SpherePass out = push_out_of_walls(w, f, now, sphere);  // push the sphere out of the walls
    if (out.pushed) note_stage_hits(w, f, now, sphere);  // count the walls it touched as stage hits
    average_wall_angle(f);  // settle the wall angle from the noted ones
    T5Vec4 push = vec4_subtract(out.position, now);  // the push, on the ground plane only
    push.y = 0.0f;
    push.w = 0.0f;
    return (SphereSolve){move_spheres(spheres, push), out.pushed};  // every sphere shifts by this push
}

// One round: every sphere in turn, each seeing the pushes of those before it.
static SphereSolve solve_round(const T5World *w, T5Fighter *f, WallSpheres spheres) {
    bool pushed = false;
    for (int sphere = 0; sphere < WALL_SPHERES; sphere++) {
        SphereSolve one = solve_sphere(w, f, spheres, sphere);  // solve this sphere, seeing earlier pushes
        spheres = one.spheres;
        pushed |= one.pushed;
    }
    return (SphereSolve){spheres, pushed};
}

// The spheres go on from the joints of the pose; the push of the fighter is the travel of the hips.
// The oracle recordings need two rounds at most and two passes at most.
void t5_wall_solve(T5World *w, T5Fighter *f) {
    t5_wall_clear(f);  // start with no wall contact
    WallSpheres spheres;
    for (int sphere = 0; sphere < WALL_SPHERES; sphere++)  // each sphere starts at its joint
        spheres.positions[sphere] = f->joints[WALL_BONE[sphere]];
    T5Vec4 origin = spheres.positions[WALL_HIPS], total = {{0.0f, 0.0f, 0.0f, 0.0f}};  // hips start, to measure the push
    bool pushed = false;
    for (int round = 0; round < WALL_SOLVE_CAP; round++) {  // repeat rounds until no sphere is pushed
        SphereSolve done = solve_round(w, f, spheres);
        spheres = done.spheres;
        if (!done.pushed) break;  // a quiet round: the fighter stands clear
        pushed = true;
    }
    if (pushed) {  // a wall moved the fighter
        if (t5_in_throw(f->throw.chain) && f->frame2 != 1) f->throw.wall_hit = 1;  // throw hits wall after first frame
        total = vec4_subtract(spheres.positions[WALL_HIPS], origin);  // the fighter's push is how far the hips moved
        total.y = 0.0f;
        total.w = 0.0f;
    }
    for (int sphere = 0; sphere < WALL_SPHERES; sphere++)  // keep spheres for the next frame's swept test
        f->previous_sphere[sphere] = spheres.positions[sphere];
    memcpy(f->wall_push, total.v, sizeof total.v);  // store the push to apply later
}

// A throw pair, or a fighter with the flag: the pair moves as one.
static bool linked(const T5World *w, const T5Fighter *first, const T5Fighter *second) {
    return (t5_throw_pair(w, first, second) && first->throw_linked && second->throw_linked) ||  // a throw pair, or either
           first->moves_with_opponent || second->moves_with_opponent;  // fighter moves with the opponent
}

// A linked pair takes the longer push of the two, with y zero. The pairs go in index order.
void t5_wall_apply(T5World *w) {
    T5Vec4 push[T5_FIGHTER_COUNT];
    bool in_link[T5_FIGHTER_COUNT] = {};
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {  // loop through the fighters: take their wall push
        memcpy(push[side].v, w->fighters[side]->wall_push, sizeof push[side].v);
        push[side].w = 0.0f;
    }
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {  // loop through every pair of fighters
        for (int other_side = side + 1; other_side < T5_FIGHTER_COUNT; other_side++) {
            if (!linked(w, w->fighters[side], w->fighters[other_side])) continue;  // only linked pairs share a push
            in_link[side] = true;  // mark both as linked
            in_link[other_side] = true;
            push[side].y = 0.0f;  // linked pushes are flat
            push[other_side].y = 0.0f;
            bool side_longer =  // compare the ground length of the two pushes
                t5_length_xz(push[side].z, push[side].x) > t5_length_xz(push[other_side].z, push[other_side].x);
            if (side_longer) push[other_side] = push[side];  // both take the longer push
            else push[side] = push[other_side];
        }
    }
    for (int side = 0; side < T5_FIGHTER_COUNT; side++) {  // loop through the fighters: apply the push to where they stand
        T5Fighter *f = w->fighters[side];
        T5Vec4 base = vec4_of(f->base_position, f->base_position_w);
        T5Vec4 position = vec4_of(f->position, 0.0f);
        base = vec4_add(base, push[side]);  // move base and position by the push
        position = vec4_add(position, push[side]);
        f->base_position.x = base.x;
        f->base_position.z = base.z;
        f->base_position_w = base.w;
        if (in_link[side]) f->base_position.y = base.y;  // linked fighters also take the base height
        f->position.x = position.x;
        f->position.z = position.z;
    }
}
