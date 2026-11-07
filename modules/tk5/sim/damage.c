#include "sim/damage.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "sim/constants.h"
#include "sim/fighter.h"
#include "sim/guard.h"
#include "sim/requirements.h"
#include "sim/state.h"
#include "sim/units.h"

// The statistics are not sim and are left out; the sparks leave as hit cues.

static int16_t abs16(int16_t value) {
    if (value < 0) return (int16_t)-value;  // negative: flip the sign
    return value;
}

static bool has(uint32_t flags, uint32_t flag) { return (flags & flag) != 0; }

void t5_hit_result(const T5World *w, T5Fighter *defender, const T5HitRecord *record) {
    uint16_t damage = (uint16_t)abs16(record->final_damage);  // damage shown is always positive
    defender->damage_absolute = damage;
    defender->guarded = has(record->flags, T5_HIT_GUARDED);  // remember if the hit was blocked
    defender->clean_hit = has(record->flags, T5_HIT_CLEAN);
    defender->counter_hit = has(record->flags, T5_HIT_COUNTER);
    t5_object(w, record->attacker)->damage_dealt = (int16_t)damage;  // the attacker remembers the damage they dealt
}

// --- self damage

const T5SelfDamage T5_SELF_DAMAGE_ROWS[SELF_DAMAGE_PROPERTIES] = {
    {SELF_DAMAGE_HURT_THROWN, true, 0}, {SELF_DAMAGE_HURT, true, 0}, {SELF_DAMAGE_HEAL, true, 0},
    {SELF_DAMAGE_HURT_THROWN, false, 0}, {SELF_DAMAGE_HURT, false, 0}, {SELF_DAMAGE_HEAL, false, 0},
};

// A self damage of 0 points does the damage of the move.
static int32_t self_damage_points(T5SelfDamage rule, int16_t move_damage) {
    if (rule.points != 0) return rule.points;  // a set amount wins; zero means the move's own damage
    return move_damage;
}

// The self damage of the defender's own move: a hurt costs health (times the damage scale), a heal gives it back.
static int32_t own_self_damage(const T5World *w, const T5Fighter *defender, bool as_hit) {
    T5SelfDamage own = defender->self_damage;
    if (own.as_hit != as_hit) return 0;  // wrong kind (hit or plain): no self damage
    if (own.effect == SELF_DAMAGE_HURT) return t5_ratio_of(self_damage_points(own, defender->damage), w->rules.damage_scale);
    if (own.effect == SELF_DAMAGE_HEAL) return -self_damage_points(own, defender->damage);  // heal: give health back
    return 0;
}

// The self damage the defender takes, as a hit or plain: its own move's, and the opponent's when it is thrown.
static int32_t self_damage(const T5World *w, const T5Fighter *defender, const T5Fighter *opponent, bool as_hit) {
    int32_t points = own_self_damage(w, defender, as_hit);
    T5SelfDamage other = opponent->self_damage;
    if (t5_thrown(defender->throw.chain) && other.as_hit == as_hit && other.effect == SELF_DAMAGE_HURT_THROWN)
        points += t5_ratio_of(self_damage_points(other, opponent->damage), w->rules.damage_scale);
    return points;
}

// --- the kind of a hit

// A move that does no damage and makes no reaction: its hits only touch.
static bool harmless(const T5Fighter *f) { return f->damage == 0 && f->reaction_rule == REACT_HARMLESS; }

static bool in_startup(const T5World *w, const T5Fighter *defender) {  // their attack has not started yet
    return defender->frame < (int32_t)t5_move_at(w, defender->move)->first_active;
}

// Both fighters are on the first active frame of their attacks, and the defender's has not landed.
static bool trade(const T5World *w, const T5Fighter *defender, const T5Fighter *attacker) {
    int32_t own = t5_move_at(w, defender->move)->first_active;
    int32_t theirs = t5_move_at(w, attacker->move)->first_active;
    return defender->frame == own && defender->hit_landed == 0 && theirs != 0 && attacker->frame == theirs;
}

static bool forced_counter(const T5Fighter *defender, const T5Fighter *attacker) {  // either fighter has a counter hit forced
    return defender->force_counter_hit != 0 || attacker->force_counter_hit != 0;
}

static bool counter_hit(const T5World *w, const T5Fighter *defender,  // startup, trade, forced or no health
                        const T5Fighter *attacker) {
    bool defender_attacks = !harmless(defender);  // defender is in a real attack
    bool caught = defender_attacks && (in_startup(w, defender) || trade(w, defender, attacker));
    return caught || forced_counter(defender, attacker) || defender->health == 0;  // or forced, or the defender has no health
}

static uint32_t hit_kind(const T5World *w, const T5Fighter *defender, const T5Fighter *attacker) {
    if (harmless(attacker)) return T5_HIT_NO_REACTION;  // harmless move: the hit only touches
    if (t5_guards_attack(defender, attacker)) {  // defender blocks: right height and attacker in front
        if (w->guard_chips != 0 || attacker->force_counter_hit != 0) return T5_HIT_GUARDED | T5_HIT_CHIP; 
        return T5_HIT_GUARDED;  // plain block: no chip
    }
    uint32_t f = T5_HIT_CLEAN;  // not blocked: a clean hit
    if (counter_hit(w, defender, attacker)) f |= T5_HIT_COUNTER;  // add counter hit
    if (t5_off_ground(defender)) f |= T5_HIT_OFF_GROUND;  // add juggle hit: defender was in the air
    if (attacker->no_spark != 0) f |= T5_HIT_NO_SPARK;  // add: the attacker's move shows no spark
    return f;
}

// Each live record gets its kind. Returns the attacker of the last one, or the opponent when none is live.
static T5Fighter *classify_records(const T5World *w, T5Fighter *defender, T5Fighter *opponent) {
    T5Fighter *last = opponent;
    for (int record_index = 0; record_index < T5_HIT_RECORDS; record_index++) {  // loop through the hit records of this frame
        T5HitRecord *record = &defender->records[record_index];
        if (!has(record->flags, T5_HIT_LIVE)) continue;  // skip empty records
        last = t5_object(w, record->attacker);  // remember who hit; the last live record wins
        record->flags |= hit_kind(w, defender, last);  // add guard, chip, clean, counter etc. to the record's flags
        t5_hit_result(w, defender, record);  // copy damage and guard results to the fighters
    }
    return last;
}

// --- the hit that counts

static const struct { uint32_t flag; int32_t score; } FLAG_SCORES[] = {  // a record's score is its flags' weights added
    {T5_HIT_NO_REACTION, 1}, {T5_HIT_GUARDED, 2}, {T5_HIT_CHIP, 3},  // weakest: no reaction 1, block 2, chip 3
    {T5_HIT_CLEAN, 5},       {T5_HIT_COUNTER, 6}, {T5_HIT_OFF_GROUND, 7},  // clean 5, counter 6, juggle 7
};  // so clean 5 beats a block 2; a chip block 5 ties clean; counter 11, juggle 12, both 18; best score wins

static int32_t record_score(uint32_t flags) {
    int32_t score = 0;
    for (size_t index = 0; index < sizeof FLAG_SCORES / sizeof *FLAG_SCORES; index++)  // loop through the weights
        if (has(flags, FLAG_SCORES[index].flag)) score += FLAG_SCORES[index].score;
    return score;  // higher score = worse hit for the defender
}

// The record that picks the reaction: the higher score, then the higher damage.
static int8_t main_record(const T5Fighter *defender) {
    const T5HitRecord *first = &defender->records[0];
    const T5HitRecord *second = &defender->records[1];
    if (!has(second->flags, T5_HIT_LIVE)) return 0;  // only one hit this frame: the first record counts
    int32_t first_score = record_score(first->flags);  // flag scores of both records
    int32_t second_score = record_score(second->flags);
    return first_score < second_score || (first_score == second_score && second->final_damage > first->final_damage);
}

// The reaction list of the first hit condition of the attacker's move that passes. Without the hook the old list stays.
static void take_reaction_list(T5World *w, T5Fighter *defender, T5Fighter *attacker) {
    const T5HitCondition *condition =  // the first condition of the attacker's move that passes
        t5_hit_condition(w, attacker, defender, t5_set(w, attacker->move.set), t5_move_at(w, attacker->move));
    if (w->reactions.list == NULL) return;  // no reaction table: keep the old reaction
    const T5Reaction *reaction = w->reactions.list(w->reactions.context, attacker->move.set, condition->reaction);
    if (reaction == NULL) return;
    defender->reaction = *reaction;  // defender plays the reaction of that hit condition
    for (int slot = 0; slot < 7; slot++) defender->reaction.pushback[slot].set = (uint8_t)attacker->move.set;  // its pushbacks are in that set
}

// --- damage

static int16_t guarded_damage(uint32_t f, int16_t raw) {
    if (!has(f, T5_HIT_CHIP) || raw < 1) return 0;  // a block without chip, or no damage: nothing goes through
    return (int16_t)(t5_ratio_of(raw, CHIP_SHARE) + CHIP_ADD);  // a share of the damage plus a small flat amount
}

// The bonus of a counter hit: a share of the defender's own attack damage. Unless the counter hit is forced, a share of that,
// by how far the defender's move came toward its first active frame (all of it from that frame on).
static int16_t counter_bonus(const T5World *w, const T5Fighter *defender, const T5Fighter *attacker) {
    int16_t bonus = (int16_t)t5_ratio_of(abs16(defender->damage), COUNTER_BONUS_SHARE);
    if (forced_counter(defender, attacker)) return bonus;  // forced counter hit: the full bonus
    const T5Move *move = t5_move_at(w, defender->move);
    int32_t frame = defender->frame, startup = (int16_t)move->first_active;  // startup is the move's first active frame
    if (move->first_active == 0 || frame > startup) startup = frame;
    if (startup == 0) return 0;  // the frame is 0 too
    return (int16_t)(t5_ratio_of(bonus, COUNTER_BONUS_SHARE) * frame / startup);
}

static bool counters(const T5Fighter *defender, uint32_t f, int16_t damage) {  // a counter hit that does damage
    (void)defender;
    return has(f, T5_HIT_COUNTER) && damage != 0;
}
static bool juggle_first(const T5Fighter *defender, uint32_t f, int16_t damage) {  // the hit that lifts them off the ground
    (void)damage;
    return has(f, T5_HIT_OFF_GROUND) && defender->juggle_count == 0;
}
static bool juggle_follow(const T5Fighter *defender, uint32_t f, int16_t damage) {  // a later hit while they are already juggled
    (void)damage;
    return has(f, T5_HIT_OFF_GROUND) && defender->juggle_count != 0;
}
static bool fallen(const T5Fighter *defender, uint32_t f, int16_t damage) {
    (void)f, (void)damage;
    return t5_class_between(defender->state_class, CLASS_FALLEN_FIRST, CLASS_FALLEN_LAST);  // defender lies on the floor
}

// The scales of a clean hit in stock order: dmg = dmg * scale + bonus for each row that applies, until a last row applies.
typedef struct {
    bool (*when)(const T5Fighter *defender, uint32_t flags, int16_t damage);
    T5Ratio scale;
    int16_t (*bonus)(const T5World *w, const T5Fighter *defender, const T5Fighter *attacker);
    bool last;
} DamageScale;

static const DamageScale DAMAGE_SCALES[] = {
    {counters, COUNTER_HIT_SCALE, counter_bonus, false},  // counter hit: 1.2 times plus a bonus, then go on
    {juggle_first, JUGGLE_FIRST_SCALE, NULL, true},  // first juggle hit: 0.7 times, and stop
    {juggle_follow, JUGGLE_FOLLOW_SCALE, NULL, true},  // later juggle hits: half, and stop
    {fallen, FALLEN_SCALE, NULL, false},  // hit on a fallen fighter: 0.7 times, then go on
};

// Damage of one live record, s16 after every row.
static int16_t hit_damage(const T5World *w, const T5Fighter *defender, const T5Fighter *attacker, uint32_t flags, int16_t raw) {
    if (has(flags, T5_HIT_GUARDED)) return guarded_damage(flags, raw);  // a blocked hit only does chip damage
    int16_t damage = raw;
    for (size_t index = 0; index < sizeof DAMAGE_SCALES / sizeof *DAMAGE_SCALES; index++) {  // loop through the scales in order
        DamageScale row = DAMAGE_SCALES[index];
        if (!row.when(defender, flags, damage)) continue;  // skip scales that do not apply
        int32_t scaled = t5_ratio_of(damage, row.scale);  // scale the damage
        if (row.bonus != NULL) scaled += row.bonus(w, defender, attacker);  // some scales add a bonus
        damage = (int16_t)scaled;
        if (row.last) break;  // a last scale ends the list
    }
    return damage;
}

// The damage of the live records, added to their final damage. Returns the total of the frame.
static int32_t hits_damage(const T5World *w, T5Fighter *defender) {
    int32_t total = 0;
    for (int record_index = 0; record_index < T5_HIT_RECORDS; record_index++) {  // loop through the hit records
        T5HitRecord *record = &defender->records[record_index];
        if (!has(record->flags, T5_HIT_LIVE)) continue;  // skip empty records
        const T5Fighter *attacker = t5_object(w, record->attacker);
        record->base_damage = (uint16_t)attacker->damage;  // remember the move's own damage
        record->final_damage =  // add what this hit does to the damage so far
            (int16_t)(record->final_damage +
                      t5_ratio_of(hit_damage(w, defender, attacker, record->flags, attacker->damage), w->rules.damage_scale));
        t5_hit_result(w, defender, record);  // copy damage and guard results to the fighters
        defender->damage_raw_frame = (int16_t)(defender->damage_raw_frame + record->base_damage);
        total += record->final_damage;  // sum of the final damage taken this frame
        if (total == 0 && attacker->marks_zero_damage != 0) defender->zero_damage_hit = 1;
    }
    return total;
}

// Health and the damage counters of the frame. Health stays once the round is over or with no damage on.
static void take_damage(const T5World *w, T5Fighter *defender, int32_t self_as_hit, int32_t self_total, int32_t hits) {
    int32_t before = defender->health;
    if (!w->round.decided && w->no_damage == 0) defender->health = t5_health_less((T5Health){before}, self_total + hits).raw;
    defender->damage_raw_frame = (int16_t)(defender->damage_raw_frame + (int16_t)self_total);  // counters get the self damage too
    defender->damage_hits_frame = (int16_t)((int16_t)hits + self_as_hit);
    defender->damage_taken_frame = (int16_t)((int16_t)self_total + (int16_t)hits);  // all damage taken this frame
    if (defender->hit_taken != 0) defender->stage_hit_power = (uint16_t)hits;  // stage objects get the hit total as hit power
    defender->damage_dealt = (int16_t)(defender->damage_dealt + (int16_t)self_total);  // self damage counts in the damage dealt
    if (defender->health < before) defender->took_damage = 1;  // health went down: took damage
}

// Health 0 from above 0 is a KO, except in practice. A KO through a chip counts as a clean hit.
static void score_ko(const T5World *w, T5Fighter *defender, T5Fighter *attacker, int32_t before) {
    if (defender->health == 0 && before != 0 && w->mode != T5_MODE_PRACTICE) {  // health hit 0 from above, and not practice: a KO
        attacker->ko_scored = 1;  // the attacker scores the KO
        defender->ko = 1;  // the defender is KO'd
    }
    if (defender->ko != 0 && defender->hit_record >= 0 && has(defender->records[defender->hit_record].flags, T5_HIT_CHIP)) {
        defender->guarded = 0;
        defender->clean_hit = 1;
    }
}

// The sparks of each live hit, as the game picks them once the KO is known.
static void hit_cues(T5World *w, const T5Fighter *defender) {
    for (int record_index = 0; record_index < T5_HIT_RECORDS; record_index++) {
        const T5HitRecord *record = &defender->records[record_index];
        uint32_t flags = record->flags;
        if (!has(flags, T5_HIT_LIVE)) continue;
        T5Spark spark;
        if (has(flags, T5_HIT_GUARDED)) spark = T5_SPARK_GUARD;
        else if ((has(flags, T5_HIT_CLEAN) || defender->ko != 0) && !has(flags, T5_HIT_NO_SPARK)) spark = T5_SPARK_CLEAN;
        else if (has(flags, T5_HIT_NO_REACTION)) spark = T5_SPARK_TOUCH;
        else continue;
        const T5Fighter *attacker = t5_object(w, record->attacker);
        T5CueKey key = {t5_side_of(w, defender), T5_FROM_HIT, attacker->move, record_index};
        t5_cue_add(&w->cues, w->frame, (T5Cue){T5_CUE_HIT, spark, (uint16_t)abs16(record->final_damage),
            t5_side_of(w, attacker), key, record->point, record->direction});
    }
}

// Objects (extras) keep their health.
void t5_damage_resolve(T5World *w, T5Fighter *defender) {
    T5Fighter *opponent = t5_object(w, defender->opponent);  // the opponent: source of throw self damage
    int32_t self_as_hit = self_damage(w, defender, opponent, true);  // self damage that counts as a hit
    int32_t self_total = self_as_hit + self_damage(w, defender, opponent, false);  // all self damage, hit and plain
    defender->zero_damage_hit = 0;  // reset the zero damage mark
    T5Fighter *attacker = classify_records(w, defender, opponent);  // classify hits; the attacker is the last live one
    if (defender->hit_taken != 0) {  // the defender took a hit this frame
        defender->hit_record = main_record(defender);  // pick the main record by score
        t5_incoming_direction(&defender->hit, &attacker->hit);  // hit direction goes to the defender
        take_reaction_list(w, defender, attacker);  // pick the defender's reaction list
    }
    int32_t hits = hits_damage(w, defender);  // damage from the hits
    int32_t before = 0;
    if (defender->kind == T5_KIND_FIGHTER) {  // only fighters lose health
        before = defender->health;
        take_damage(w, defender, self_as_hit, self_total, hits);
    }
    if (defender->health < 0) defender->health = 0;  // health never goes below 0
    if (defender->health > defender->max_health) defender->health = defender->max_health;  // health never goes above the maximum
    score_ko(w, defender, attacker, before);  // check for a KO
    hit_cues(w, defender);
}

static void clear_frame(T5Fighter *f) {
    f->ko_scored = 0;  // the attacker's KO score resets
    f->damage_raw_frame = 0;  // the frame's damage counters reset
    f->damage_taken_frame = 0;
    f->damage_hits_frame = 0;
}

// The extras are resolved but not cleared.
void t5_damage_pass(T5World *w) {
    for (int record_index = 0; record_index < T5_FIGHTER_COUNT; record_index++) clear_frame(w->fighters[record_index]);
    for (int record_index = 0; record_index < T5_FIGHTER_COUNT; record_index++) t5_damage_resolve(w, w->fighters[record_index]);
    for (int32_t record_index = 0; record_index < t5_extra_count(w); record_index++)  // then the extras
        t5_damage_resolve(w, t5_extra_entry(w, record_index));
}
