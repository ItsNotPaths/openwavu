// Move properties (code-map 6): the property dispatcher, the per-frame list of a move, the conditional start and end properties.
// Only the logic pass changes sim state. Camera, effect, sound and voice props leave as cues (w->cues, cue.h); face and hand
// pose props set the pose fields of the fighter.
#ifndef T5_PROPERTIES_H
#define T5_PROPERTIES_H

#include "sim/world.h"

typedef enum { T5_PASS_LOGIC = 0, T5_PASS_EFFECTS = 1 } T5PropPass;  // the effects pass only sends cues

// Property ids are T5_PROPERTY_BASE and up; a requirement list may hold them (instant properties). Below it they do nothing.
enum : uint16_t { T5_PROPERTY_BASE = 32768 };

// f->target receives the props that act on the target. key names the firing for a cue.
void t5_property(T5World *w, uint16_t id, uint16_t value, T5Fighter *f, T5PropPass pass, T5CueKey key);
// The properties in the requirement list of a cancel, from entry `first` of the requirements of `motbin`
void t5_instant_props(T5World *w, T5Fighter *f, const T5Motbin *motbin, int32_t first, T5PropSource source);
void t5_props_tick(T5World *w, T5Fighter *f, T5PropPass pass);                            // the move's property list
// The target takes f's move id; in place: the new anim starts on the target's anchor as it is
void t5_force_move(const T5World *w, T5Fighter *f, T5Fighter *target, uint16_t id, bool in_place);

uint16_t t5_transition_filter(const T5World *w, const T5Fighter *f, uint16_t transition);  // f's pending move is the target
void t5_props_changed(T5World *w, T5Fighter *f);  // runs the move's property list on the logic pass
// The start properties of the move f just entered, conditioned on the target
void t5_start_properties(T5World *w, T5Fighter *f, const T5Fighter *target);
void t5_props_end(T5World *w, T5Fighter *f);                                               // the end property of the move
bool t5_sound_once(T5Fighter *f, int16_t id);  // a fighter plays each sound id once until the ids clear
void t5_sound_ids_clear(T5Fighter *f);
// Props tick of the fighters (unless fighters_blocked); logic also clears sounds.
void t5_props_pass(T5World *w, bool fighters_blocked, T5PropPass pass);
// The voice clips of both fighters' moves as cues (voice_clip.c).
void t5_voice_clips_pass(T5World *w);

#endif
