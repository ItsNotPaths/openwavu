// Move properties: the property dispatcher, the per-frame list of a move, the conditional start and end properties.
// Only the logic pass changes sim state. Camera, effect, sound and voice props leave as cues (w->cues, cue.h); face and hand
// pose props set the pose fields of the fighter.
#ifndef T6_PROPERTIES_H
#define T6_PROPERTIES_H

#include "sim/world.h"

typedef enum { T6_PASS_LOGIC = 0, T6_PASS_EFFECTS = 1 } T6PropPass;  // the effects pass only sends cues

// Property ids are T6_PROPERTY_BASE and up; a requirement list may hold them (instant properties). Below it they do nothing.
enum : uint16_t { T6_PROPERTY_BASE = 32768 };

// f->target receives the props that act on the target. key names the firing for a cue. value: the TK6 u32; cues keep it
// whole, the sim's handlers read its low 16 bits (every TK6 value they read fits).
void t6_property(T6World *w, uint16_t id, uint32_t value, T6Fighter *f, T6PropPass pass, T6CueKey key);
// The properties in the requirement list of a cancel, from entry `first` of the requirements of `motbin`
void t6_instant_props(T6World *w, T6Fighter *f, const T6Motbin *motbin, int32_t first, T6PropSource source);
void t6_props_tick(T6World *w, T6Fighter *f, T6PropPass pass);                            // the move's property list
// The target takes f's move id; in place: the new anim starts on the target's anchor as it is
void t6_force_move(const T6World *w, T6Fighter *f, T6Fighter *target, uint16_t id, bool in_place);

uint16_t t6_transition_filter(const T6World *w, const T6Fighter *f, uint16_t transition);  // f's pending move is the target
void t6_props_changed(T6World *w, T6Fighter *f);  // runs the move's property list on the logic pass
// The start properties of the move f just entered, conditioned on the target
void t6_start_properties(T6World *w, T6Fighter *f, const T6Fighter *target);
void t6_props_end(T6World *w, T6Fighter *f);                                               // the end property of the move
bool t6_sound_once(T6Fighter *f, uint32_t id);  // a fighter plays each sound id once until the ids clear
void t6_sound_ids_clear(T6Fighter *f);
// Props tick of the fighters (unless fighters_blocked); logic also clears sounds.
void t6_props_pass(T6World *w, bool fighters_blocked, T6PropPass pass);
// The voice clips of both fighters' moves as cues (voice_clip.c).
void t6_voice_clips_pass(T6World *w);

#endif
