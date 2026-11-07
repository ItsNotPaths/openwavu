// The lobbies role's wire (docs/network.md): ENet channel 0 carries kipp lines, one per reliable packet; channel 1
// carries session packets, unsequenced, which the server forwards to the other player of a running match.
package online

import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import enet "vendor:ENet"
import "../kipp"

PORT :: 9288  // "wavu" on a phone keypad
CHANNEL_CONTROL :: 0
CHANNEL_SESSION :: 1
CHANNELS :: 2
PROTOCOL :: "1"
START_DELAY_MS :: 2000  // from the match fact to frame 0
LOBBY_PLAYERS_MAX :: 2
LOADOUT_MAX :: 256  // bytes; sent as hex inside one line
CONNECT_TIMEOUT_MS :: 5000

Lobby :: struct {
	id, pack, mode, params, hash, host: string,  // pack: id@version; params: the host's picks; host: a player key
	players: [dynamic]Lobby_Player,  // join order
	match:   Maybe(Lobby_Match),
}

Lobby_Player :: struct {
	key, name: string,
	ready:     bool,
	loadout:   []byte,
}

Lobby_Match :: struct {
	token:    u32,
	seed:     u64,
	delay_ms: u32,
	sides:    [2]string,  // player keys
	heard:    time.Tick,  // when the fact arrived
}

// A connection to a lobby server and every lobby it shows, kept current by lobby_pump.
Lobby_Client :: struct {
	host:            ^enet.Host,
	server:          ^enet.Peer,
	identity:        Identity,
	key, name:       string,  // key: hex of the public key, the player id
	greeted:         bool,
	lobbies:         [dynamic]Lobby,
	refused:         string,  // the last error line's message
	session_packets: [dynamic][]byte,
}

lobby_connect :: proc(host_name: string, identity: Identity, name: string, port: u16 = PORT) -> (client: ^Lobby_Client, err: string) {
	if enet.initialize() != 0 do return nil, "ENet does not start"
	client = new(Lobby_Client)
	client.identity = identity
	client.key = strings.clone(string(hex.encode(client.identity.public_key[:], context.temp_allocator)))
	client.name = strings.clone(name)
	defer if err != "" do lobby_disconnect(client)
	if client.host = enet.host_create(nil, 1, CHANNELS, 0, 0); client.host == nil do return client, "ENet does not start"
	address := enet.Address{port = port}
	if enet.address_set_host(&address, strings.clone_to_cstring(host_name, context.temp_allocator)) != 0 do return client, fmt.tprintf("%s does not resolve", host_name)
	if client.server = enet.host_connect(client.host, &address, CHANNELS, 0); client.server == nil do return client, "ENet does not start"
	event: enet.Event
	if enet.host_service(client.host, &event, CONNECT_TIMEOUT_MS) <= 0 || event.type != .CONNECT do return client, "the lobby server did not answer"
	enet.host_flush(client.host)  // the server counts the connect when this ack arrives
	for waited := time.tick_now(); !client.greeted; {
		if time.tick_since(waited) > CONNECT_TIMEOUT_MS * time.Millisecond do return client, "the lobby server did not greet"
		if !lobby_pump(client, 100) do return client, client.refused != "" ? client.refused : "the lobby server hung up"
	}
	return client, ""
}

lobby_disconnect :: proc(client: ^Lobby_Client) {
	if client.server != nil {
		enet.peer_disconnect(client.server, 0)
		enet.host_flush(client.host)
	}
	if client.host != nil do enet.host_destroy(client.host)
	enet.deinitialize()
	for &lobby in client.lobbies do lobby_destroy(&lobby)
	delete(client.lobbies)
	for packet in client.session_packets do delete(packet)
	delete(client.session_packets)
	delete(client.key)
	delete(client.name)
	delete(client.refused)
	free(client)
}

// Applies everything that arrived, waiting up to timeout_ms for the first event. false once the server is gone.
lobby_pump :: proc(client: ^Lobby_Client, timeout_ms: u32 = 0) -> (connected: bool) {
	event: enet.Event
	for wait := timeout_ms; enet.host_service(client.host, &event, wait) > 0; wait = 0 {
		#partial switch event.type {
		case .DISCONNECT:
			return false
		case .RECEIVE:
			bytes := event.packet.data[:event.packet.dataLength]
			if event.channelID == CHANNEL_SESSION do append(&client.session_packets, slice.clone(bytes))
			else if line, read := kipp.parse(string(bytes)); read do apply(client, line)
			enet.packet_destroy(event.packet)
		}
	}
	return true
}

// The lobby this player is in, or nil.
lobby_joined :: proc(client: ^Lobby_Client) -> ^Lobby {
	for &lobby in client.lobbies do for player in lobby.players do if player.key == client.key do return &lobby
	return nil
}

find_lobby :: proc(client: ^Lobby_Client, id: string) -> ^Lobby {
	for &lobby in client.lobbies do if lobby.id == id do return &lobby
	return nil
}

// This player's side in match; -1 when it does not play.
match_side :: proc(client: ^Lobby_Client, match: Lobby_Match) -> int {
	for key, side in match.sides do if key == client.key do return side
	return -1
}

// The player with key, or nil.
lobby_player :: proc(lobby: ^Lobby, key: string) -> ^Lobby_Player {
	for &player in lobby.players do if player.key == key do return &player
	return nil
}

lobby_create :: proc(client: ^Lobby_Client, pack, mode, params, hash: string) {
	command(client, "CREATE", {pack}, {"mode", mode}, {"params", params}, {"hash", hash})
}

// The caller checks the lobby hash first (titlepack.lobby_hash_text).
// (hole lobby-fetch :tags net :needs lobby-intents) joining a lobby of a pack that is not installed does not fetch it from the network's files host.
lobby_join :: proc(client: ^Lobby_Client, id: string) {
	command(client, "JOIN", {id})
}

lobby_leave :: proc(client: ^Lobby_Client) {
	command(client, "LEAVE", nil)
}

lobby_ready :: proc(client: ^Lobby_Client, loadout: []byte) {
	command(client, "READY", nil, {"loadout", string(hex.encode(loadout, context.temp_allocator))})
}

// This player's match has ended; once every player says so the lobby can start the next one.
lobby_done :: proc(client: ^Lobby_Client) {
	command(client, "DONE", nil)
}

// What a player's sim and session start from, out of its lobby's match fact.
Match_Start :: struct {
	side:     int,
	seed:     u64,
	token:    u32,
	loadouts: [2][]byte,  // views into the lobby's players
	start_in: time.Duration,  // until frame 0: the server's delay less half the round trip, less the time since
}

match_start :: proc(client: ^Lobby_Client, lobby: ^Lobby) -> (start: Match_Start, ok: bool) {
	match := lobby.match.? or_return
	start = {side = match_side(client, match), seed = match.seed, token = match.token}
	if start.side < 0 do return
	for key, side in match.sides {
		player := lobby_player(lobby, key)
		if player == nil do return
		start.loadouts[side] = player.loadout
	}
	half_trip := time.Duration(client.server.roundTripTime / 2) * time.Millisecond
	start.start_in = time.Duration(match.delay_ms) * time.Millisecond - half_trip - time.tick_since(match.heard)
	return start, true
}

// A session packet's first four bytes are its match's token.
packet_token :: proc(packet: []byte) -> (token: u32, ok: bool) {
	return endian.get_u32(packet, .Little)
}

// Session packets go to the server, which forwards them; received ones wait in session_packets for lobby_pump.
lobby_transport :: proc(client: ^Lobby_Client) -> Transport {
	send :: proc(data: rawptr, packet: []byte) {
		client := (^Lobby_Client)(data)
		enet.peer_send(client.server, CHANNEL_SESSION, enet.packet_create(raw_data(packet), len(packet), {.UNSEQUENCED}))
		enet.host_flush(client.host)
	}
	receive :: proc(data: rawptr, buffer: []byte) -> (size: int) {
		client := (^Lobby_Client)(data)
		lobby_pump(client)
		if len(client.session_packets) == 0 do return 0
		packet := pop_front(&client.session_packets)
		defer delete(packet)
		return copy(buffer, packet)
	}
	return {client, send, receive}
}

@(private = "file")
command :: proc(client: ^Lobby_Client, kind: string, subject: []string, attributes: ..kipp.Attribute) {
	text, ok := kipp.write(kind, subject, ..attributes)
	if !ok do return
	enet.peer_send(client.server, CHANNEL_CONTROL, enet.packet_create(raw_data(text), len(text), {.RELIABLE}))
	enet.host_flush(client.host)
}

@(private = "file")
apply :: proc(client: ^Lobby_Client, line: kipp.Line) {
	subject := line.subject
	switch line.kind {
	case "challenge":
		if len(subject) < 1 do return
		challenge, read := hex.decode(transmute([]byte)subject[0], context.temp_allocator)
		if !read do return
		signature := sign(client.identity, challenge)
		command(client, "HELLO", {client.key}, {"signature", string(hex.encode(signature[:], context.temp_allocator))}, {"name", client.name})
	case "welcome":
		client.greeted = true
	case "lobby":
		if len(subject) < 1 do return
		lobby := find_lobby(client, subject[0])
		if lobby == nil {
			append(&client.lobbies, Lobby{id = strings.clone(subject[0])})
			lobby = &client.lobbies[len(client.lobbies) - 1]
		}
		replace(&lobby.pack, line.attributes["pack"])
		replace(&lobby.mode, line.attributes["mode"])
		replace(&lobby.params, line.attributes["params"])
		replace(&lobby.hash, line.attributes["hash"])
		replace(&lobby.host, line.attributes["host"])
	case "player":
		if len(subject) < 2 do return
		lobby := find_lobby(client, subject[0])
		if lobby == nil do return
		player := lobby_player(lobby, subject[1])
		if player == nil {
			append(&lobby.players, Lobby_Player{key = strings.clone(subject[1])})
			player = &lobby.players[len(lobby.players) - 1]
		}
		replace(&player.name, line.attributes["name"])
		player.ready = line.attributes["ready"] == "1"
		delete(player.loadout)
		player.loadout = hex.decode(transmute([]byte)line.attributes["loadout"]) or_else nil
	case "match":
		if len(subject) < 1 do return
		lobby := find_lobby(client, subject[0])
		if lobby == nil do return
		match := Lobby_Match{heard = time.tick_now()}
		token, token_read := strconv.parse_u64_of_base(line.attributes["token"], 16)
		seed, seed_read := strconv.parse_u64(line.attributes["seed"])
		delay_ms, delay_read := strconv.parse_u64(line.attributes["delay_ms"])
		if !token_read || !seed_read || !delay_read do return
		match.token, match.seed, match.delay_ms = u32(token), seed, u32(delay_ms)
		lobby_match_destroy(lobby)
		match.sides = {strings.clone(line.attributes["side0"]), strings.clone(line.attributes["side1"])}
		lobby.match = match
	case "drop":
		if len(subject) < 2 do return
		lobby := find_lobby(client, subject[1])
		if lobby == nil do return
		switch subject[0] {
		case "lobby":
			for &candidate, index in client.lobbies do if candidate.id == subject[1] {
				lobby_destroy(&candidate)
				ordered_remove(&client.lobbies, index)
				break
			}
		case "player":
			if len(subject) < 3 do return
			for player, index in lobby.players do if player.key == subject[2] {
				lobby_player_destroy(player)
				ordered_remove(&lobby.players, index)
				break
			}
		case "match":
			lobby_match_destroy(lobby)
		}
	case "error":
		replace(&client.refused, line.attributes["msg"])
	}
}

@(private = "file")
replace :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

@(private = "file")
lobby_destroy :: proc(lobby: ^Lobby) {
	for text in ([]string{lobby.id, lobby.pack, lobby.mode, lobby.params, lobby.hash, lobby.host}) do delete(text)
	for player in lobby.players do lobby_player_destroy(player)
	delete(lobby.players)
	lobby_match_destroy(lobby)
}

@(private = "file")
lobby_player_destroy :: proc(player: Lobby_Player) {
	delete(player.key)
	delete(player.name)
	delete(player.loadout)
}

@(private = "file")
lobby_match_destroy :: proc(lobby: ^Lobby) {
	if match, running := lobby.match.?; running do for key in match.sides do delete(key)
	lobby.match = nil
}
