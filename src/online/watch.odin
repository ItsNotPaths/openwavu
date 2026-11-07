package online

import "../sim"

WATCH_CATCH_UP :: 2  // frames a tick at most, so a watcher that fell behind catches up without skipping the show

// A watcher's match. The server sends it both players' session packets reliably, so it steps only on pads both sides
// sent: no guesses and no rollback, a few frames behind the players.
Watch :: struct {
	world:    ^sim.World,
	client:   ^Lobby_Client,
	token:    u32,
	pads:     [2][dynamic]sim.Input,  // by frame, as far as each side has sent
	frame:    int,  // the next frame to step
	heard_ns: u64,
	outcome:  Outcome,
}

watch_create :: proc(world: ^sim.World, client: ^Lobby_Client, token: u32, now_ns: u64) -> ^Watch {
	client.watch_token = token
	w := new(Watch)
	w^ = {world = world, client = client, token = token, heard_ns = now_ns}
	return w
}

watch_destroy :: proc(w: ^Watch) {
	w.client.watch_token = 0
	for pads in w.pads do delete(pads)
	free(w)
}

// Takes in the packets that came, then steps the frames both sides have sent. A trap in the sim comes back as err.
watch_tick :: proc(w: ^Watch, now_ns: u64) -> (err: string) {
	lobby_pump(w.client)
	for len(w.client.watch_packets) > 0 {
		packet := pop_front(&w.client.watch_packets)
		defer delete(packet)
		if len(packet) == 0 || packet[0] > 1 do continue
		reader := Reader{bytes = packet[1:]}
		if take(&reader, 4) != w.token do continue
		_ = take(&reader, 4)  // the other player's ack
		first := int(take(&reader, 4))
		count := int(take(&reader, 2))
		pads := &w.pads[packet[0]]
		for frame in first ..< first + count {
			pad := take(&reader, 2)
			if !reader.short && frame == len(pads) do append(pads, sim.Input{pad = pad})
		}
		w.heard_ns = now_ns
	}
	if now_ns - w.heard_ns > TIMEOUT_NS {
		w.outcome = .Disconnected
		return
	}
	for steps := 0; steps < WATCH_CATCH_UP && w.frame < min(len(w.pads[0]), len(w.pads[1])); steps += 1 {
		if err = sim.step(w.world, {w.pads[0][w.frame], w.pads[1][w.frame]}); err != "" do return
		w.frame += 1
	}
	return
}

// Every stepped frame is confirmed, so the sim's match end is final.
watch_match_end :: proc(w: ^Watch) -> (winner: i32, ended: bool) {
	for event in w.world.inputs.events do if event.kind == .Match_End do return event.a, true
	return
}
