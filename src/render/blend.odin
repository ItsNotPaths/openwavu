// Drawing between sim ticks: the display runs at the player's fps, the sim at 60 (docs/app.md, Frame rate).
package render

// The scene alpha of the way from from to to.
// (hole scene-blend :tags render) no blending between the scenes of the last two sim ticks: nodes matched by id, bones, camera, clip times, fx ages; no-blend flag, gameplay class setting; from should be the scene last shown, so a rollback correction slides.
blend_scenes :: proc(from, to: ^Scene, alpha: f32) -> ^Scene {
	return to
}
