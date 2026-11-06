// The scenes of the last RING_TICKS sim ticks (docs/app.md, the scene). Blending reads the newest two, effects read the
// past of fighter bones, a dead pack leaves the newest on screen.
package render

RING_TICKS :: 60

Scene_Ring :: struct {
	scenes: [RING_TICKS]Scene,
	newest: int,  // index into scenes
	count:  int,  // ticks held, up to RING_TICKS; at first one empty scene
}

scene_ring_create :: proc() -> (ring: Scene_Ring) {
	for &scene in ring.scenes do scene = scene_create()
	ring.count = 1
	return
}

scene_ring_destroy :: proc(ring: ^Scene_Ring) {
	for &scene in ring.scenes do scene_destroy(&scene)
}

// Takes a newly sent scene; scene gets back arrays to read the next into. ticked: it is a new sim tick's, so it becomes
// the newest entry; else it replaces the newest. The entry that falls to third newest keeps only its gameplay nodes.
scene_ring_push :: proc(ring: ^Scene_Ring, scene: ^Scene, ticked: bool) {
	if ticked {
		ring.newest = (ring.newest + 1) % RING_TICKS
		ring.count = min(ring.count + 1, RING_TICKS)
		if ring.count > 2 do keep_gameplay(&ring.scenes[(ring.newest + RING_TICKS - 2) % RING_TICKS])
	}
	ring.scenes[ring.newest], scene^ = scene^, ring.scenes[ring.newest]
}

// The scene of ticks_back ticks before the newest; nil past what the ring holds.
scene_ring_back :: proc(ring: ^Scene_Ring, ticks_back: int) -> ^Scene {
	if ticks_back < 0 || ticks_back >= ring.count do return nil
	return &ring.scenes[(ring.newest + RING_TICKS - ticks_back) % RING_TICKS]
}

// Lights, fx and scenery nodes go; bones stay as read, so the kept nodes' slices hold.
@(private = "file")
keep_gameplay :: proc(scene: ^Scene) {
	clear(&scene.lights)
	clear(&scene.fx)
	kept := 0
	for node in scene.nodes {
		if node.class != .Gameplay do continue
		scene.nodes[kept] = node
		kept += 1
	}
	resize(&scene.nodes, kept)
}
