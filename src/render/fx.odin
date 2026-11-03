// Host fx: draws the fx entries of the scene (effect def, anchor, age, seed). The app builds the entries; the host keeps no fx state.
package render

// (hole fx-spec :tags (render content)) no effect def schema (elements, curves, inputs; ws.md Decisions), drafted from what TK5 EFP uses.
// (hole fx-draw :tags render :needs (render-gpu fx-spec)) fx entries are not drawn: no effect def played at an age and seed, at a node bone or a world point.
draw_fx :: proc(r: ^Renderer) {}
