// animconv: .anim <-> glTF clips, for Blender and for mod anims.
package animconv

import "core:fmt"

// (hole anim-gltf-export :tags tools) .anim files can not be written as glTF clips.
export_clips :: proc(anim_path, skeleton_glb, out_glb: string) -> (ok: bool) {
	return false
}

// (hole anim-gltf-import :tags tools :needs glb-reader) glTF clips can not be turned into .anim (bones -> channels; root motion into channels 0 and 2).
import_clip :: proc(in_glb, layout, out_anim: string) -> (ok: bool) {
	return false
}

main :: proc() {
	fmt.eprintln("usage: animconv export <file.anim> <skeleton.glb> <out.glb> | import <clip.glb> <layout> <out.anim>")
}
