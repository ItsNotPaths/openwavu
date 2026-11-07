package tests

import "core:log"
import "core:slice"
import "core:testing"
import "core:time"
import "../src/online"
import "../src/sim"

TICK_NS :: 1_000_000_000 / 60

// One way of a fake network, in ticks: each packet arrives `lag` to `lag + jitter` ticks after it is sent, or is lost.
Pipe :: struct {
	packets:        [dynamic]Pipe_Packet,
	tick:           ^int,
	lag, jitter:    int,
	loss_percent:   int,
	random:         u64,  // xorshift state
	cut:            bool,  // nothing gets through
}

Pipe_Packet :: struct {
	arrives: int,
	bytes:   []byte,
}

pipe_random :: proc(pipe: ^Pipe, below: int) -> int {
	pipe.random ~= pipe.random << 13
	pipe.random ~= pipe.random >> 7
	pipe.random ~= pipe.random << 17
	return int(pipe.random % u64(below))
}

// A session's two pipes: it sends into `out` and receives from `back`.
Link :: struct {
	out, back: ^Pipe,
}

link_transport :: proc(link: ^Link) -> online.Transport {
	send :: proc(data: rawptr, packet: []byte) {
		pipe := (^Link)(data).out
		if pipe.cut || pipe_random(pipe, 100) < pipe.loss_percent do return
		append(&pipe.packets, Pipe_Packet{pipe.tick^ + pipe.lag + pipe_random(pipe, pipe.jitter + 1), slice.clone(packet, context.temp_allocator)})
	}
	receive :: proc(data: rawptr, buffer: []byte) -> int {
		pipe := (^Link)(data).back
		for packet, index in pipe.packets do if packet.arrives <= pipe.tick^ {
			size := copy(buffer, packet.bytes)
			ordered_remove(&pipe.packets, index)
			return size
		}
		return 0
	}
	return {link, send, receive}
}

// Two machines, each with its own sim and session, its bot on its own side; the sessions talk through two pipes.
Two_Machines :: struct {
	worlds:   [2]^sim.World,
	sessions: [2]^online.Session,
	pipes:    [2]Pipe,  // pipes[side]: from that side to the other
	links:    [2]Link,
	tick:     int,
	pause:    time.Duration,  // real time per tick, for transports that need it
}

two_machines_create :: proc(t: ^testing.T, stock: ^Stock_Sim, lag, jitter, loss_percent: int) -> (machines: ^Two_Machines, ok: bool) {
	machines = new(Two_Machines)
	for side in 0 ..< 2 {
		machines.pipes[side] = {tick = &machines.tick, lag = lag, jitter = jitter, loss_percent = loss_percent, random = u64(side) + 11}
		if machines.worlds[side], ok = stock_world(t, stock); !ok do return
	}
	for side in 0 ..< 2 {
		machines.links[side] = {&machines.pipes[side], &machines.pipes[1 - side]}
		machines.sessions[side] = online.session_create(machines.worlds[side], link_transport(&machines.links[side]), side, 77, 0)
	}
	return machines, true
}

two_machines_destroy :: proc(machines: ^Two_Machines) {
	for side in 0 ..< 2 {
		if machines.sessions[side] != nil do online.session_destroy(machines.sessions[side])
		if machines.worlds[side] != nil do sim.destroy(machines.worlds[side])
		delete(machines.pipes[side].packets)
	}
	free(machines)
}

// Ticks both machines until both have stepped `frames` frames and hold all of the other's pads for them. false when
// a session ends first or the sim traps.
two_machines_play :: proc(t: ^testing.T, machines: ^Two_Machines, frames: int) -> bool {
	TICKS_MAX :: 100_000
	for ; machines.tick < TICKS_MAX; machines.tick += 1 {
		now := u64(machines.tick) * TICK_NS
		time.sleep(machines.pause)
		for side in 0 ..< 2 {
			session := machines.sessions[side]
			err: string
			if session.frame < frames {
				pad: sim.Input
				if pad, err = sim.bot_pad(machines.worlds[side], side); !testing.expect_value(t, err, "") do return false
				_, err = online.session_tick(session, pad, now)
			} else {
				err = online.session_exchange(session, now)
			}
			if !testing.expect_value(t, err, "") || session.outcome != .Playing do return false
		}
		done := true
		for session in machines.sessions do done &&= session.frame == frames && session.known >= frames
		if done do return true
	}
	return false
}

// Over a bad network (lag, jitter, loss), two machines that each guess the other's pads and roll back end with the
// same state, and their hashes matched along the way.
@(test)
sessions_agree_over_a_bad_network :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	machines, created := two_machines_create(t, stock, lag = 4, jitter = 3, loss_percent = 15)
	defer two_machines_destroy(machines)
	if !created do return

	FRAMES :: 3000
	if !testing.expect(t, two_machines_play(t, machines, FRAMES), "the sessions did not both finish") do return
	testing.expect(t, sim.state_hash(machines.worlds[0]) == sim.state_hash(machines.worlds[1]), "the two machines' states differ")
	for session in machines.sessions {
		testing.expect_value(t, session.outcome, online.Outcome.Playing)
		testing.expectf(t, session.checked_frame >= FRAMES / 2, "hashes matched only up to frame %d", session.checked_frame)
	}
	log.infof("%d frames in %d ticks", FRAMES, machines.tick)
}

// A machine whose state goes wrong once is put right by the retry from the last matched hash.
@(test)
session_retry_repairs_a_bad_state :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	machines, created := two_machines_create(t, stock, lag = 2, jitter = 0, loss_percent = 0)
	defer two_machines_destroy(machines)
	if !created do return

	if !two_machines_play(t, machines, 100) do return
	snapshot := make([]byte, sim.snapshot_size(machines.worlds[1]), context.temp_allocator)
	sim.save(machines.worlds[1], snapshot)
	snapshot[len(snapshot) / 2] ~= 0xff  // one flipped byte of state
	sim.restore(machines.worlds[1], snapshot)
	if !testing.expect(t, two_machines_play(t, machines, 400), "the sessions did not both finish") do return
	testing.expect(t, sim.state_hash(machines.worlds[0]) == sim.state_hash(machines.worlds[1]), "the retry did not repair the state")
	for session in machines.sessions do testing.expect_value(t, session.attempt, u32(1))
}

// Machines that start from different states never agree: the match ends as a desync.
@(test)
session_reports_a_lasting_desync :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	machines := new(Two_Machines)
	defer two_machines_destroy(machines)
	for side in 0 ..< 2 {
		machines.pipes[side] = {tick = &machines.tick, lag = 2, random = u64(side) + 11}
		err: string
		machines.worlds[side], err = sim.create(stock.engine, stock.module, &stock.pack, stage_params(), {loadout_bytes("paul"), loadout_bytes("kazuya")}, u64(side) + 7)  // other seeds
		if !testing.expect_value(t, err, "") do return
	}
	for side in 0 ..< 2 {
		machines.links[side] = {&machines.pipes[side], &machines.pipes[1 - side]}
		machines.sessions[side] = online.session_create(machines.worlds[side], link_transport(&machines.links[side]), side, 77, 0)
	}
	testing.expect(t, !two_machines_play(t, machines, 300), "the sessions finished")
	for _ in 0 ..< 60 {  // the other machine hears the last hashes
		machines.tick += 1
		for session in machines.sessions do if session.outcome == .Playing do testing.expect_value(t, online.session_exchange(session, u64(machines.tick) * TICK_NS), "")
	}
	for session in machines.sessions do testing.expect_value(t, session.outcome, online.Outcome.Desync)
}

// A machine that hears nothing for five seconds ends the match.
@(test)
session_ends_on_silence :: proc(t: ^testing.T) {
	stock, opened := stock_sim_open(t)
	if !opened do return
	defer stock_sim_close(stock)
	machines, created := two_machines_create(t, stock, lag = 2, jitter = 0, loss_percent = 0)
	defer two_machines_destroy(machines)
	if !created do return
	if !two_machines_play(t, machines, 60) do return
	machines.pipes[1].cut = true
	testing.expect(t, !two_machines_play(t, machines, 1000), "the sessions finished")
	testing.expect_value(t, machines.sessions[0].outcome, online.Outcome.Disconnected)
	testing.expectf(t, machines.tick < 60 + 5 * 60 + 10, "ended at tick %d", machines.tick)
}
