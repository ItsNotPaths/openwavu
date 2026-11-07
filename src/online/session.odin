package online

import "core:encoding/endian"
import "../sim"

// The rollback session of one match between two machines (ws.md Workstream Q). Each frame steps with the local pad
// and the remote's pad, guessed (its last known pad) until it arrives; a late pad that differs from the guess rolls the
// sim back to that frame and runs the frames up to now again. Past ROLLBACK_MAX guessed frames, the session stalls.

ROLLBACK_MAX :: 8
HASH_INTERVAL :: 30  // frames between state hashes, on confirmed frames
TIMEOUT_NS :: 5_000_000_000  // no packet for this long ends the match
PACKET_PADS_MAX :: 64
PACKET_HASHES_MAX :: 4
PACKET_MAX :: 4 + 4 + 4 + 2 + 2 * PACKET_PADS_MAX + 1 + 12 * PACKET_HASHES_MAX

Outcome :: enum {
	Playing,
	Desync,        // the hashes still differ after the retry: no contest
	Disconnected,  // nothing heard for TIMEOUT_NS
}

// A state hash of the state before `frame`. attempt is 1 after the desync retry.
Hash_Record :: struct {
	frame, attempt, hash: u32,
}

// A local hash not yet compared, with the snapshot it hashes.
Pending :: struct {
	record:   Hash_Record,
	snapshot: []byte,
}

Session :: struct {
	world:          ^sim.World,
	transport:      Transport,
	token:          u32,  // from the lobby server: packets without it are dropped
	side:           int,  // the local side
	frame:          int,  // the next frame to step
	inputs:         [dynamic][2]sim.Input,  // by frame; the remote's from `known` on are guesses. The confirmed part is the replay
	known:          int,  // the remote's pads are known for the frames before this
	acked:          int,  // the remote has the local pads for the frames before this
	snapshots:      [ROLLBACK_MAX][]byte,  // the state before frame f, at f % ROLLBACK_MAX
	next_hash:      int,  // the frame of the next state hash
	attempt:        u32,
	pending:        [dynamic]Pending,
	remote_records: [dynamic]Hash_Record,  // the remote's hashes not yet compared
	checked_frame:  int,  // the last frame whose hashes matched: the desync retry starts there
	checked:        []byte,
	heard_ns:       u64,  // when the last packet came
	outcome:        Outcome,
}

session_create :: proc(world: ^sim.World, transport: Transport, side: int, token: u32, now_ns: u64) -> ^Session {
	s := new(Session)
	s^ = {world = world, transport = transport, side = side, token = token, heard_ns = now_ns}
	size := sim.snapshot_size(world)
	for &snapshot in s.snapshots do snapshot = make([]byte, size)
	s.checked = make([]byte, size)
	sim.save(world, s.checked)
	hash_confirmed(s)
	return s
}

session_destroy :: proc(s: ^Session) {
	for snapshot in s.snapshots do delete(snapshot)
	for pending in s.pending do delete(pending.snapshot)
	delete(s.checked)
	delete(s.pending)
	delete(s.remote_records)
	delete(s.inputs)
	free(s)
}

// One tick: take the packets in, step a frame with the local pad unless the remote is ROLLBACK_MAX frames behind, send.
// A trap in the sim comes back as err.
session_tick :: proc(s: ^Session, local: sim.Input, now_ns: u64) -> (stepped: bool, err: string) {
	if err = take_packets(s, now_ns); err != "" || s.outcome != .Playing do return
	if s.frame - s.known < ROLLBACK_MAX {
		if err = step_frame(s, local); err != "" do return
		hash_confirmed(s)
		stepped = true
	}
	send_packet(s)
	return
}

// Packets in and out without a step: after the last frame, until the remote's pads confirm it.
session_exchange :: proc(s: ^Session, now_ns: u64) -> (err: string) {
	if err = take_packets(s, now_ns); err != "" || s.outcome != .Playing do return
	send_packet(s)
	return
}

@(private = "file")
remote_side :: proc(s: ^Session) -> int {
	return 1 - s.side
}

@(private = "file")
guess :: proc(s: ^Session) -> sim.Input {
	return s.known > 0 ? s.inputs[s.known - 1][remote_side(s)] : {}
}

@(private = "file")
step_frame :: proc(s: ^Session, local: sim.Input) -> (err: string) {
	if len(s.inputs) == s.frame do append(&s.inputs, [2]sim.Input{})
	s.inputs[s.frame][s.side] = local
	if s.frame >= s.known do s.inputs[s.frame][remote_side(s)] = guess(s)
	sim.save(s.world, s.snapshots[s.frame % ROLLBACK_MAX])
	if err = sim.step(s.world, s.inputs[s.frame]); err != "" do return
	s.frame += 1
	return
}

// Restores `snapshot`, the state before frame `from`, and steps up to the current frame again, hashing the pending
// frames on the way.
@(private = "file")
run_again :: proc(s: ^Session, from: int, snapshot: []byte) -> (err: string) {
	sim.restore(s.world, snapshot)
	for frame in from ..= s.frame {
		for &pending in s.pending do if int(pending.record.frame) == frame {
			sim.save(s.world, pending.snapshot)
			pending.record = {u32(frame), s.attempt, u32(sim.snapshot_hash(pending.snapshot))}
		}
		if frame == s.frame do break
		sim.save(s.world, s.snapshots[frame % ROLLBACK_MAX])
		if err = sim.step(s.world, s.inputs[frame]); err != "" do return
	}
	return
}

// Hashes each HASH_INTERVAL-th frame whose inputs are all confirmed and that the sim has reached.
@(private = "file")
hash_confirmed :: proc(s: ^Session) {
	for s.next_hash <= min(s.known, s.frame) {
		snapshot := make([]byte, sim.snapshot_size(s.world))
		if s.next_hash == s.frame do sim.save(s.world, snapshot)
		else do copy(snapshot, s.snapshots[s.next_hash % ROLLBACK_MAX])
		append(&s.pending, Pending{{u32(s.next_hash), s.attempt, u32(sim.snapshot_hash(snapshot))}, snapshot})
		s.next_hash += HASH_INTERVAL
	}
}

// --- packets: token, ack, first frame, pads from it, hashes. Little endian.

@(private = "file")
send_packet :: proc(s: ^Session) {
	packet: [PACKET_MAX]byte
	at := 0
	put :: proc(packet: []byte, at: ^int, value: u32, size: int) {
		switch size {
		case 1: packet[at^] = u8(value)
		case 2: endian.unchecked_put_u16le(packet[at^:], u16(value))
		case 4: endian.unchecked_put_u32le(packet[at^:], value)
		}
		at^ += size
	}
	first := s.acked
	count := min(s.frame - first, PACKET_PADS_MAX)
	put(packet[:], &at, s.token, 4)
	put(packet[:], &at, u32(s.known), 4)
	put(packet[:], &at, u32(first), 4)
	put(packet[:], &at, u32(count), 2)
	for frame in first ..< first + count do put(packet[:], &at, s.inputs[frame][s.side].pad, 2)
	hashes := s.pending[max(0, len(s.pending) - PACKET_HASHES_MAX):]
	put(packet[:], &at, u32(len(hashes)), 1)
	for pending in hashes {
		put(packet[:], &at, pending.record.frame, 4)
		put(packet[:], &at, pending.record.attempt, 4)
		put(packet[:], &at, pending.record.hash, 4)
	}
	s.transport.send(s.transport.data, packet[:at])
}

@(private = "file")
Reader :: struct {
	bytes: []byte,
	at:    int,
	short: bool,  // the packet ended early
}

@(private = "file")
take :: proc(reader: ^Reader, size: int) -> u32 {
	if reader.at + size > len(reader.bytes) {
		reader.short = true
		return 0
	}
	defer reader.at += size
	switch size {
	case 1: return u32(reader.bytes[reader.at])
	case 2: return u32(endian.unchecked_get_u16le(reader.bytes[reader.at:]))
	}
	return endian.unchecked_get_u32le(reader.bytes[reader.at:])
}

// (hole net-authority-restore :tags net :needs server-authority) no message from an authority server that sets a client back to its snapshot of a frame.
@(private = "file")
take_packets :: proc(s: ^Session, now_ns: u64) -> (err: string) {
	buffer: [PACKET_MAX]byte
	first_wrong := s.frame
	for {
		size := s.transport.receive(s.transport.data, buffer[:])
		if size == 0 do break
		reader := Reader{bytes = buffer[:size]}
		if take(&reader, 4) != s.token do continue
		acked := int(take(&reader, 4))
		first := int(take(&reader, 4))
		count := int(take(&reader, 2))
		pads := make([]sim.Input, count, context.temp_allocator)
		for &pad in pads do pad.pad = take(&reader, 2)
		records := make([]Hash_Record, int(take(&reader, 1)), context.temp_allocator)
		for &record in records do record = {take(&reader, 4), take(&reader, 4), take(&reader, 4)}
		if reader.short do continue
		s.heard_ns = now_ns
		s.acked = max(s.acked, min(acked, s.frame))
		first_wrong = min(first_wrong, take_pads(s, first, pads))
		for record in records do take_record(s, record)
	}
	if now_ns - s.heard_ns > TIMEOUT_NS {
		s.outcome = .Disconnected
		return
	}
	if first_wrong < s.frame do if err = run_again(s, first_wrong, s.snapshots[first_wrong % ROLLBACK_MAX]); err != "" do return
	hash_confirmed(s)
	return compare_hashes(s)
}

// Takes the remote's pads that come next; the first frame that ran on a wrong guess, or the current frame.
@(private = "file")
take_pads :: proc(s: ^Session, first: int, pads: []sim.Input) -> (first_wrong: int) {
	first_wrong = s.frame
	remote := remote_side(s)
	for pad, offset in pads {
		frame := first + offset
		if frame != s.known do continue  // seen before
		if frame >= len(s.inputs) do append(&s.inputs, [2]sim.Input{})
		if frame < s.frame && s.inputs[frame][remote] != pad do first_wrong = min(first_wrong, frame)
		s.inputs[frame][remote] = pad
		s.known += 1
	}
	for frame in s.known ..< s.frame do if s.inputs[frame][remote] != guess(s) {  // guesses from the newer last pad
		first_wrong = min(first_wrong, frame)
		s.inputs[frame][remote] = guess(s)
	}
	return
}

@(private = "file")
take_record :: proc(s: ^Session, record: Hash_Record) {
	for &kept in s.remote_records do if kept.frame == record.frame {
		if record.attempt > kept.attempt do kept = record
		return
	}
	append(&s.remote_records, record)
}

// Each remote hash against the local one of its frame. A match moves the retry start there; a mismatch runs the retry
// once, a second one is a desync.
@(private = "file")
compare_hashes :: proc(s: ^Session) -> (err: string) {
	for index := 0; index < len(s.remote_records); {
		remote := s.remote_records[index]
		if remote.attempt > s.attempt {  // the remote saw a mismatch first
			if err = retry(s); err != "" || s.outcome != .Playing do return
			continue
		}
		mine := -1
		for pending, at in s.pending do if pending.record.frame == remote.frame do mine = at
		if mine < 0 {
			if int(remote.frame) <= s.checked_frame do unordered_remove(&s.remote_records, index)
			else do index += 1  // not hashed here yet
			continue
		}
		unordered_remove(&s.remote_records, index)
		if remote.attempt < s.attempt do continue  // from before the retry
		if s.pending[mine].record.hash == remote.hash {
			check(s, mine)
			continue
		}
		if s.attempt > 0 {
			s.outcome = .Desync
			return
		}
		if err = retry(s); err != "" || s.outcome != .Playing do return
	}
	return
}

// The pending hash at `mine` matched: the retry starts there from now on, and older pending hashes are dropped.
@(private = "file")
check :: proc(s: ^Session, mine: int) {
	s.checked_frame = int(s.pending[mine].record.frame)
	copy(s.checked, s.pending[mine].snapshot)
	for pending in s.pending[:mine + 1] do delete(pending.snapshot)
	remove_range(&s.pending, 0, mine + 1)
}

@(private = "file")
retry :: proc(s: ^Session) -> (err: string) {
	if s.attempt > 0 {
		s.outcome = .Desync
		return
	}
	s.attempt = 1
	return run_again(s, s.checked_frame, s.checked)
}
