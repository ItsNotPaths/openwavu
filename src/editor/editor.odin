// Moveset property editor: edits the pack's moveset rows and saves the changes as an overlay.
package editor

import "../content"

// (hole moveset-editor :tags editor :needs (pack-open overlay-write render-gpu)) no editor UI for moves, cancels, requirements and properties.
run :: proc(p: ^content.Pack) {}
