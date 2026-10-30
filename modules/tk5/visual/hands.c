#include "visual/hands.h"

#include <math.h>
#include <stddef.h>

#include "sim/hand_poses.h"
#include "sim/quat.h"
#include "sim/units.h"

// Pose ids of the library that the automatic poses use (the property poses name their own).
enum { FIST_POSE = 0, IDLE_LEFT_POSE = 1, IDLE_RIGHT_POSE = 2, OPEN_POSE = 3 };  // fist is 0, idle left 1, idle right 2, open 3

static constexpr T5Frames HIT_BLEND = {10};    // a clean hit, or being thrown, opens the hands over this
static constexpr T5Frames IDLE_BLEND = {10};   // a new move without damage, a round start or a seek relaxes the hands over this
static constexpr T5Frames FIST_BLEND = {8};  // a clench blends in over this many frames
static constexpr T5Frames CLENCH_LEAD = {8};   // the wind-up fist is set until this many frames before the first active one
static constexpr T5Frames GESTURE_BLEND = {2};  // a gesture blends in over this many frames

static const float SAME_TIME = 1e-5f;  // times closer than this count as equal
static const float PLAY_RATE = (float)PLAY_SPEED / CLOCK_PER_FRAME;  // clip frames a tick

// A pose property value: pose id * POSE_UNIT + blend frames. A gesture value: the clip, plus GESTURE_BANK_FLAG for the gesture bank.
enum : uint16_t { POSE_UNIT = 256, GESTURE_BANK_FLAG = 16384 };  // the unit of a pose value and the gesture bank flag bit

// Hitbox codes whose moves do not clench the fists: no hitbox (0) and the leg points. Codes from NOT_BONE_CODES up are
// no body point and do not clench either.
static const struct { uint8_t first, last; } UNCLENCHED_CODES[] = {{0, 0}, {13, 21}, {23, 26}, {43, 50}};  // no clench
enum { NOT_BONE_CODES = 107 };

// Left-hand mirror by joint in its finger (root first): roots S_y M S_y, the other joints S_x M S_x, as quaternion signs.
static const float MIRROR[3][4] = {{-1, 1, -1, 1}, {1, -1, -1, 1}, {1, -1, -1, 1}};  // left hand: sign of x, y, z, w

T5Vec4 t5_left_finger_turn(T5Vec4 turn, int32_t joint) {  // a finger joint's turn for the left hand, mirrored
    const float *sign = MIRROR[joint % 3];  // signs for this joint's position in its finger
    return (T5Vec4){{turn.x * sign[0], turn.y * sign[1], turn.z * sign[2], turn.w * sign[3]}};
}

// --- the channel setters

static T5HandChannel pose_channel(int32_t pose, T5Frames blend) { return (T5HandChannel){(float)pose, HAND_POSES, 0, (uint16_t)blend.ticks}; }

static bool clenches(uint8_t hitbox_code) {  // true if this hitbox code clenches the fists
    if (hitbox_code >= NOT_BONE_CODES) return false;  // not a body point: no clench
    for (size_t range = 0; range < sizeof UNCLENCHED_CODES / sizeof *UNCLENCHED_CODES; range++)  // check each code range
        if (hitbox_code >= UNCLENCHED_CODES[range].first && hitbox_code <= UNCLENCHED_CODES[range].last) return false;
    return true;  // any other body point clenches
}

// A new pose property sets the channel: a repeat of the same pose is new by its set frame.
static T5Hand take_property(T5Hand hand, T5PoseProp property, int32_t idle_pose) {  // hand after this property
    bool fresh = property.id != hand.seen.id || property.value != hand.seen.value ||  // new: id, value or set frame changed
                 property.set_frame != hand.seen.set_frame;
    hand.seen = property;
    if (!fresh || property.id < T5_HAND_PROPERTY_FIRST ||  // not new, or not a hand property
        property.id > T5_HAND_PROPERTY_LAST) return hand;  // keep the hand
    T5Frames blend = {property.value % POSE_UNIT};  // the blend is the low part of the value
    switch (T5_HAND_PROPERTIES[property.id - T5_HAND_PROPERTY_FIRST].kind) {
    case T5_HOLD_HANDS: break;  // hold: keep the channel as it is
    case T5_SET_POSE: hand.channel = pose_channel(property.value / POSE_UNIT, blend); break;  // pose: play the pose id
    case T5_SET_IDLE: hand.channel = pose_channel(idle_pose, blend); break;
    case T5_SET_GESTURE: {  // gesture: play a clip from one of the two banks
        uint8_t bank = HAND_POSES;  // the pose bank unless the flag says otherwise
        if ((property.value & GESTURE_BANK_FLAG) != 0) bank = HAND_GESTURES;
        hand.channel = (T5HandChannel){0.0f, bank, (uint16_t)(property.value % GESTURE_BANK_FLAG), (uint16_t)GESTURE_BLEND.ticks};
        break;
    }
    }
    return hand;
}

static T5Hands both_hands(T5Hands hands, int32_t right_pose, int32_t left_pose, T5Frames blend) {  // set both hands' poses
    hands.right.channel = pose_channel(right_pose, blend);
    hands.left.channel = pose_channel(left_pose, blend);
    return hands;
}

// The automatic poses: a clean hit opens the hands; while no property posed them, a new move relaxes them and a punch
// clenches them in its wind-up.
static T5Hands automatic_poses(T5Hands hands, const T5World *w, const T5Fighter *f) {
    if (hands.clean_hit) return both_hands(hands, OPEN_POSE, OPEN_POSE, HIT_BLEND);  // clean hit: open both hands
    if (f->hands_posed) return hands;  // a property posed the hands in this move: keep them
    if (f->anim_changed != 0 && f->damage == 0 && f->streak_clean == 0) {  // new anim, no damage, and no clean-hit streak
        if (t5_thrown(f->throw.chain)) hands = both_hands(hands, OPEN_POSE, OPEN_POSE, HIT_BLEND);  // thrown: open both hands
        else hands = both_hands(hands, IDLE_RIGHT_POSE, IDLE_LEFT_POSE, IDLE_BLEND);  // otherwise relax into the idle poses
    }
    const T5Move *move = t5_move_at(w, f->move);
    if (f->damage != 0 && move != NULL &&  // a move with damage
        t5_frames_past(move->first_active - f->frame, CLENCH_LEAD) &&  // first active is over CLENCH_LEAD away
        clenches(move->hitbox[0]))  // its hitbox clenches
        hands = both_hands(hands, FIST_POSE, FIST_POSE, FIST_BLEND);  // clench both fists for the wind-up
    return hands;
}

// --- clock and sample

static T5HandBank bank_of(T5HandBanks banks, T5HandChannel channel) {
    if (channel.bank == HAND_GESTURES) return banks.gestures;
    return banks.poses;
}

// A clip plays and loops; a pose of the library stays. The blend counts down.
static T5HandChannel clock(T5HandChannel channel, T5HandBanks banks) {
    bool pose_library = channel.bank == HAND_POSES && channel.clip == 0;  // a pose of the library: pose bank, clip 0
    if (!pose_library) channel.time += PLAY_RATE;  // clips move on; library poses stay
    if ((float)t5_hand_clip_frames(bank_of(banks, channel), channel.clip) < channel.time)  // clip ended
        channel.time = 0.0f;  // loop to the start
    if (channel.blend_frames > 0) channel.blend_frames--;
    return channel;
}

static bool same_channel(T5HandChannel first, T5HandChannel second) {  // true if both channels are the same play state
    return fabsf(first.time - second.time) < SAME_TIME && first.bank == second.bank && first.clip == second.clip &&
           first.blend_frames == second.blend_frames;
}

// The channel's pose, a 1 / blend_frames step from the last sample. The game samples only when the channel changed, so a
// setter called again each tick holds the hand one step from where it began until the calls stop.
static T5Hand sample(T5Hand hand, T5HandBanks banks) {
    if (hand.has_sample && same_channel(hand.sampled, hand.channel)) return hand;  // same as last sample: keep pose
    T5FingerPose target = t5_hand_clip_sample(bank_of(banks, hand.channel), hand.channel.clip, hand.channel.time);
    if (hand.channel.blend_frames > 0)  // still blending: move toward the target
        for (int joint = 0; joint < FINGER_JOINTS; joint++)
            t5_quat_blend(&target.joint[joint], 1.0f / hand.channel.blend_frames, &hand.pose.joint[joint], &target.joint[joint]);
    hand.pose = target;
    hand.sampled = hand.channel;
    hand.has_sample = true;
    return hand;
}

T5Hands t5_hands_idle(T5Hands hands, T5HandBanks banks, const T5Fighter *f) {
    hands = both_hands(hands, IDLE_RIGHT_POSE, IDLE_LEFT_POSE, IDLE_BLEND);
    hands.right.seen = f->right_hand_pose;  // mark the right pose property as seen, so it is not new
    hands.left.seen = f->left_hand_pose;
    hands.right.has_sample = false;
    hands.left.has_sample = false;
    hands.clean_hit = false;
    hands.right = sample(hands.right, banks);
    hands.left = sample(hands.left, banks);
    return hands;
}

T5Hands t5_hands_tick(T5Hands hands, T5HandBanks banks, const T5World *w, const T5Fighter *f) {
    hands.right = take_property(hands.right, f->right_hand_pose, IDLE_RIGHT_POSE);
    hands.left = take_property(hands.left, f->left_hand_pose, IDLE_LEFT_POSE);
    hands = automatic_poses(hands, w, f);  // automatic poses, if no property posed the hands
    hands.clean_hit = f->clean_hit != 0;  // save this tick's clean-hit flag for the next tick's poses
    hands.right.channel = clock(hands.right.channel, banks);
    hands.left.channel = clock(hands.left.channel, banks);
    hands.right = sample(hands.right, banks);
    hands.left = sample(hands.left, banks);
    return hands;
}
