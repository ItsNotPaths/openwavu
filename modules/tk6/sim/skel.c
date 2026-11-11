#include "sim/skel.h"

#include <string.h>

#include "sim/bones.h"
#include "sim/math.h"
#include "sim/quat.h"

// --- bon file: u16 version, u16 count, f32 scale, u32 offsets of parent, trans, euler, list, ends

enum { BON_BODY = 50, BON_HEADER_BYTES = 28, BON_PARENT = 8, BON_TRANS = 12, BON_EULER = 16, BON_ENDS = 24 };

static uint32_t read32(const uint8_t *bytes) {  // four bytes, lowest first, as one number
    return (uint32_t)(bytes[0] | bytes[1] << 8 | bytes[2] << 16 | (uint32_t)bytes[3] << 24);
}
static float read_float(const uint8_t *bytes) {  // the same four bytes read as a decimal number
    uint32_t word = read32(bytes);
    float value;
    memcpy(&value, &word, 4);
    return value;
}
static const uint8_t *table(const uint8_t *bon, int32_t field) { return bon + read32(bon + field); }
static int32_t bon_parent(const uint8_t *bon, int32_t record) { return (int32_t)read32(table(bon, BON_PARENT) + 4 * record); }
static float bon_translation(const uint8_t *bon, int32_t record, int axis) {  // a bone's offset from its parent, one axis
    return read_float(table(bon, BON_TRANS) + 12 * record + 4 * axis);
}
static float bon_euler(const uint8_t *bon, int32_t record, int axis) {  // a bone's bind turn, one axis
    return read_float(table(bon, BON_EULER) + 12 * record + 4 * axis);
}

// bon bone -> body slot (for B the first 23 of its table); bon 29, 30 land on 15, 19 again
enum { BON_BONES_A = 111, BON_BONES_B = 23, END_POINTS = 5 };  // bon records of each table; the end points after the slots
static const int8_t SLOT_A[BON_BONES_A] = {
    -1, 0, 1, 2, 13, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 18, 19, 20, 17, 21, -1, -1, -1, -1, -1, -1, 15, 19,
    27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 46, 45, 47, 48, 50, 49, 51, 52, 53, 54,
    55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82,
    83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106,
};
static const int8_t SLOT_B[BON_BONES_B] = {-1, 0, 1, 2, 13, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 18, 19, 20, 17, 21};

// End points 22..26: parent slot, axis and ends[] entry of their offset (scaled by the bon scale)
static const struct { int8_t parent, axis, end; } END_POINT[END_POINTS] = {{BONE_HEAD, 2, 0}, {BONE_R_FOOT, 0, 1}, {BONE_R_TOE, 1, 3}, {BONE_L_FOOT, 0, 2}, {BONE_L_TOE, 1, 4}};

void t6_skeleton_load_a(T6Skeleton *skeleton, const uint8_t *bon) {
    skeleton->scale = read_float(bon + 4);  // body scale of this character
    memset(skeleton->translation, 0, sizeof skeleton->translation);
    memset(skeleton->euler, 0, sizeof skeleton->euler);
    for (int32_t end_point = 0; end_point < END_POINTS; end_point++) {
        int32_t slot = BONE_HEAD_END + end_point;  // end points sit after the body slots
        int32_t axis = END_POINT[end_point].axis;
        float offset = skeleton->scale * read_float(table(bon, BON_ENDS) + 4 * END_POINT[end_point].end);
        skeleton->parent_a[slot] = END_POINT[end_point].parent;
        skeleton->translation[slot][axis] = offset;
    }
    for (int32_t record = 1; record < BON_BONES_A; record++) {  // loop through file records, skip the root record
        int32_t slot = SLOT_A[record];
        if (slot < 0) continue;  // this record has no body slot, ignore it
        skeleton->parent_a[slot] = SLOT_A[bon_parent(bon, record)];  // -1: the root record
        for (int component = 0; component < 3; component++) {  // copy the bind position and bind turn of the bone
            skeleton->translation[slot][component] = bon_translation(bon, record, component);
            skeleton->euler[slot][component] = bon_euler(bon, record, component);
        }
    }
    skeleton->parent_a[0] = -1;  // the hips have no parent bone, only the root
}

void t6_skeleton_load_b(T6Skeleton *skeleton, const uint8_t *bon) {
    memset(skeleton->translation_b, 0, sizeof skeleton->translation_b);
    for (int32_t record = 1; record < BON_BONES_B; record++) {  // loop through the first records, skip the root record
        int32_t slot = SLOT_B[record];
        skeleton->parent_b[slot] = SLOT_B[bon_parent(bon, record)];  // parent bone found through the same slot table
        for (int axis = 0; axis < 3; axis++) skeleton->translation_b[slot][axis] = bon_translation(bon, record, axis);
    }
    skeleton->parent_b[BONE_SPINE] = BONE_HIPS;  // B hangs the spine and the pelvis on the hips
    skeleton->parent_b[BONE_PELVIS] = BONE_HIPS;
    for (int32_t end_point = 0; end_point < END_POINTS; end_point++) {
        skeleton->parent_b[BONE_HEAD_END + end_point] = END_POINT[end_point].parent;
        skeleton->translation_b[BONE_HEAD_END + end_point][END_POINT[end_point].axis] =  // sits this far out, scaled
            skeleton->scale * read_float(table(bon, BON_ENDS) + 4 * END_POINT[end_point].end);
    }
}

int t6_skeleton_parse(T6Skeleton *skeleton, T6Bytes file) {
    if (file.size <= BON_HEADER_BYTES || (file.data[0] | file.data[1] << 8) != BON_BODY) return -1;
    t6_skeleton_load_a(skeleton, file.data);
    t6_skeleton_load_b(skeleton, file.data);
    return 0;
}

static void load_locals(T6Bone *bones, const float (*translation)[3], int32_t count) {  // identity turns, bind positions
    for (int32_t bone = 0; bone < count; bone++) {
        t6_mat_identity(&bones[bone].local);
        for (int axis = 0; axis < 3; axis++) bones[bone].local.m[3][axis] = translation[bone][axis];
    }
}

void t6_rig_load(T6Rig *rig, const T6Skeleton *skeleton) {
    load_locals(rig->bones_a, skeleton->translation, T6_BONES_A);
    load_locals(rig->bones_b, skeleton->translation_b, T6_BONES_B);
    t6_mat_identity(&rig->root.local);
}

// --- world matrices: world = local * parent world (VMX)

static void bone_world(T6Bone *bones, const int8_t *parent, const T6Mat4 *root, int32_t bone) {  // world matrix of one bone
    T6Mat4 world_matrix = *root;  // start from the root
    if (parent[bone] >= 0) world_matrix = bones[parent[bone]].world;  // bone has a parent, use its world matrix instead
    t6_mat_multiply(&world_matrix, &bones[bone].local);  // add this bone's own local move and turn
    bones[bone].world = world_matrix;
}

void t6_skel_bone_world(T6Rig *rig, const int8_t *parent_a, int32_t bone) {
    bone_world(rig->bones_a, parent_a, &rig->root.world, bone);
}

void t6_skel_bone_world_b(T6Rig *rig, const int8_t *parent_b, int32_t bone) {
    bone_world(rig->bones_b, parent_b, &rig->root.world, bone);
}

void t6_skel_world(T6Bone *bones, const int8_t *parent, const T6Mat4 *root, int32_t count) {
    for (int32_t bone = 0; bone < count; bone++) bone_world(bones, parent, root, bone);
}

// face and finger bones the long pass adds after bones 0..26, in the game's order
static const int8_t EXTRA_WORLD[] = {72, 57, 81, 86, 95, 104};

void t6_skel_world_a_extra(T6Rig *rig, const T6Skeleton *skeleton) {
    rig->root.world = rig->root.local;  // root world is its local
    t6_skel_world(rig->bones_a, skeleton->parent_a, &rig->root.world, T6_BONES_B);
    for (size_t extra = 0; extra < sizeof EXTRA_WORLD; extra++)  // then the extra bones, each after its parent
        bone_world(rig->bones_a, skeleton->parent_a, &rig->root.world, EXTRA_WORLD[extra]);
}

void t6_skel_world_a(T6Rig *rig, const T6Skeleton *skeleton) {  // body positions of the pose bones of table A
    t6_skel_world(rig->bones_a, skeleton->parent_a, &rig->root.world, T6_POSE_BONES);
}

void t6_skel_world_b(T6Rig *rig, const T6Skeleton *skeleton) {  // body positions of all bones of table B
    t6_skel_world(rig->bones_b, skeleton->parent_b, &rig->root.world, T6_BONES_B);
}

void t6_rig_rotations_to_b(T6Rig *rig) {  // B copies the turn rows of A and keeps its own positions
    for (int32_t bone = 0; bone < T6_BONES_B; bone++)  // the first three rows of each matrix, not the position row
        memcpy(rig->bones_b[bone].local.m, rig->bones_a[bone].local.m, sizeof rig->bones_a[bone].local.m[0] * 3);
}

void t6_rig_bind(T6Rig *rig, const T6Skeleton *skeleton) {  // put the whole rig in its bind (standing) pose
    t6_mat_identity(&rig->root.local);
    t6_mat_identity(&rig->root.world);
    for (int32_t bone = 0; bone < T6_BONES_A; bone++) {
        T6Mat4 *local = &rig->bones_a[bone].local;
        t6_mat_euler_xyz(local, skeleton->euler[bone]);  // bind turn
        for (int axis = 0; axis < 3; axis++) local->m[3][axis] = skeleton->translation[bone][axis];  // bind position
        local->m[3][3] = 1.0f;
    }
    t6_skel_world(rig->bones_a, skeleton->parent_a, &rig->root.world, T6_BONES_A);
    t6_rig_rotations_to_b(rig);
    t6_skel_world_b(rig, skeleton);
}

// --- pose

// body slot of channels 3..22; channel 6 (a position) also writes slot 0, which channel 3 overwrites
static const int8_t CHANNEL_SLOT[T6_CHANNELS] = {-1, -1, -1, 0, 1, 13, -1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 18, 19, 20};

static T6Vec4 point(const T6Mat4 *frame, float x, float y) {  // a point in the bone's own frame, moved into the parent's space
    T6Vec4 out;
    t6_vec_times_mat(&out, &(T6Vec4){{x, y, 0, 1}}, frame);
    return out;
}

static T6Vec4 sum(const T6Vec4 *left, const T6Vec4 *right) { T6Vec4 result; t6_vec_add(&result, left, right); return result; }
static T6Vec4 difference(const T6Vec4 *left, const T6Vec4 *right) {  // left minus right
    T6Vec4 result;
    t6_vec_subtract(&result, left, right);
    return result;
}

// Points of the trunk frames, mm in the frame of their bone.
static const float TRUNK_SIDE = 130.0f, TRUNK_UP = 400.0f;

// The spine and the chest get frames from points of the pelvis and the posed spine, all in hips space; the chest is then
// made relative to the new spine. `trunk_point` is the x of the trunk point channel.
static void spine_and_chest(T6Bone *bones_a, float trunk_point) {
    const T6Mat4 spine_before = bones_a[BONE_SPINE].local, *pelvis = &bones_a[BONE_PELVIS].local;
    T6Vec4 pelvis_1 = point(pelvis, -TRUNK_SIDE, TRUNK_UP);
    T6Vec4 pelvis_2 = point(pelvis, trunk_point, 0);
    T6Vec4 spine_1 = point(&spine_before, TRUNK_SIDE, -TRUNK_UP);  // the same kind of two points on the posed spine
    T6Vec4 spine_2 = point(&spine_before, TRUNK_UP, 0);
    T6Mat4 frame;
    T6Vec4 toward = sum(&spine_1, &pelvis_1);
    t6_mat_frame_xy(&frame, &toward, &spine_2);  // spine frame from two blended points
    toward = sum(&pelvis_2, &spine_2);
    t6_mat_frame_turn_x(&frame, &toward);  // turn the frame so x points along toward
    memcpy(bones_a[BONE_SPINE].local.m, frame.m, 3 * sizeof frame.m[0]);  // the spine takes this new turn

    T6Vec4 base = point(&bones_a[BONE_SPINE].local, TRUNK_SIDE, 0);
    T6Vec4 x = difference(&spine_1, &base);
    T6Vec4 y = difference(&spine_2, &base);
    t6_mat_frame_xy(&frame, &x, &y);
    t6_mat_frame_turn_x(&frame, &y);  // turn the frame so x points along y
    t6_mat_frame_xy(&bones_a[BONE_CHEST].local, (const T6Vec4 *)frame.m[0], (const T6Vec4 *)frame.m[1]);
    t6_mat_relative_rotation(&bones_a[BONE_CHEST].local, &bones_a[BONE_CHEST].local, &bones_a[BONE_SPINE].local);
}

void t6_skel_pose(T6Bone *bones_a, const T6Skeleton *skeleton, const T6Vec4 pose[T6_CHANNELS]) {
    for (int32_t channel = 3; channel < T6_CHANNELS; channel++)  // loop through animated channels, turn each into a bone rotation
        if (CHANNEL_SLOT[channel] >= 0) t6_quat_to_mat(&bones_a[CHANNEL_SLOT[channel]].local, &pose[channel]);
    t6_mat_euler_xyz(&bones_a[BONE_CHEST].local, skeleton->euler[BONE_CHEST]);
    spine_and_chest(bones_a, pose[CHANNEL_TRUNK_POINT].x);  // spine and chest get their frames from the trunk point
    t6_mat_euler_xyz(&bones_a[BONE_R_TOE].local, skeleton->euler[BONE_R_TOE]);  // the toes keep their bind turn
    t6_mat_euler_xyz(&bones_a[BONE_L_TOE].local, skeleton->euler[BONE_L_TOE]);
}
