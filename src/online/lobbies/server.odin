// The lobbies role (docs/network.md): lobbies of two players, their match starts and the session relay. kipp lines on
// the control channel; runs no pack code and checks no params: each joiner compares the lobby hash itself.
package lobbies

import "base:runtime"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:math/rand"
import "core:sync"
import enet "vendor:ENet"
import "../../kipp"
import "../../online"

PEERS_MAX :: 64

Server :: struct {
	host:        ^enet.Host,
	lobbies:     [dynamic]^Lobby,
	lobby_count: u32,  // lobbies ever made, for their ids
	allocator:   runtime.Allocator,  // open's, also on the serving thread
}

// peer.data of every connection.
Player :: struct {
	peer:      ^enet.Peer,
	challenge: [32]u8,
	key, name: string,  // "" until HELLO
	lobby:     ^Lobby,
	seat:      Seat,
	loadout:   string,  // hex
}

// A player's place in its lobby's cycle: unready, ready, then done once its match has ended.
Seat :: enum {
	Unready,
	Ready,
	Done,
}

Lobby :: struct {
	id, pack, mode, params, hash: string,
	host:     ^Player,
	players:  [dynamic]^Player,  // join order: side 0 first
	match:    Maybe(Match),
}

Match :: struct {
	token: u32,  // never 0
	seed:  u64,
}

open :: proc(port: u16) -> (server: Server, ok: bool) {
	if enet.initialize() != 0 do return
	address := enet.Address{host = enet.HOST_ANY, port = port}
	server.host = enet.host_create(&address, PEERS_MAX, online.CHANNELS, 0, 0)
	server.allocator = context.allocator
	return server, server.host != nil
}

close :: proc(server: ^Server) {
	context.allocator = server.allocator
	for &peer in server.host.peers[:server.host.peerCount] do if peer.data != nil do player_free((^Player)(peer.data))
	for lobby in server.lobbies do lobby_free(lobby)
	delete(server.lobbies)
	enet.host_destroy(server.host)
	enet.deinitialize()
}

// Serves until stop is set.
serve :: proc(server: ^Server, stop: ^bool) {
	context.allocator = server.allocator
	event: enet.Event
	for !sync.atomic_load(stop) {
		if enet.host_service(server.host, &event, 100) <= 0 do continue
		#partial switch event.type {
		case .CONNECT:
			arrive(event.peer)
		case .RECEIVE:
			player := (^Player)(event.peer.data)
			bytes := event.packet.data[:event.packet.dataLength]
			if event.channelID == online.CHANNEL_SESSION do forward(player, bytes)
			else if line, read := kipp.parse(string(bytes)); read do obey(server, player, line)
			enet.packet_destroy(event.packet)
		case .DISCONNECT:
			player := (^Player)(event.peer.data)
			leave(server, player)
			player_free(player)
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
arrive :: proc(peer: ^enet.Peer) {
	player := new(Player)
	player.peer = peer
	crypto.rand_bytes(player.challenge[:])
	peer.data = player
	send(player, "version", {online.PROTOCOL, "openwavu-lobby"})
	send(player, "challenge", {string(hex.encode(player.challenge[:], context.temp_allocator))})
	send(player, "sync", {"state"})
}

@(private = "file")
obey :: proc(server: ^Server, player: ^Player, line: kipp.Line) {
	if line.kind != "HELLO" && player.key == "" {
		refuse(player, line.kind, "badarg", "say HELLO first")
		return
	}
	switch line.kind {
	case "HELLO":  hello(server, player, line)
	case "CREATE": create(server, player, line)
	case "JOIN":   join(server, player, line)
	case "LEAVE":  leave(server, player)
	case "READY":  ready(server, player, line)
	case "DONE":   done(server, player)
	case:          refuse(player, line.kind, "badcmd", "unknown command")
	}
}

// HELLO <key> signature= name=: the key signs the challenge. Then every lobby, and welcome.
@(private = "file")
hello :: proc(server: ^Server, player: ^Player, line: kipp.Line) {
	if player.key != "" || len(line.subject) < 1 do return
	key, key_read := hex.decode(transmute([]byte)line.subject[0], context.temp_allocator)
	signature, signature_read := hex.decode(transmute([]byte)line.attributes["signature"], context.temp_allocator)
	public_key: [32]u8
	signed: [64]u8
	if !key_read || !signature_read || len(key) != len(public_key) || len(signature) != len(signed) {
		refuse(player, "HELLO", "badarg", "key or signature does not read")
		return
	}
	copy(public_key[:], key)
	copy(signed[:], signature)
	if !online.signed_by(public_key, player.challenge[:], signed) {
		refuse(player, "HELLO", "badarg", "the signature does not match the key")
		return
	}
	for other in connected(server) do if other.key == line.subject[0] {
		refuse(player, "HELLO", "badarg", "this key is connected already")
		return
	}
	player.key = fmt.aprint(line.subject[0])
	player.name = fmt.aprint(line.attributes["name"])
	for lobby in server.lobbies {
		send_line(player, lobby_line(lobby))
		for member in lobby.players do send_line(player, player_line(lobby, member))
		if match, running := lobby.match.?; running do send_line(player, match_line(lobby, match))
	}
	send(player, "welcome", {player.key})
}

// CREATE <pack id@version> mode= params= hash=: a new lobby with this player as its host.
@(private = "file")
create :: proc(server: ^Server, player: ^Player, line: kipp.Line) {
	if player.lobby != nil || len(line.subject) < 1 {
		refuse(player, "CREATE", "badarg", "leave the lobby first")
		return
	}
	server.lobby_count += 1
	lobby := new(Lobby)
	lobby^ = {
		id     = fmt.aprintf("%08x", server.lobby_count),
		pack   = fmt.aprint(line.subject[0]),
		mode   = fmt.aprint(line.attributes["mode"]),
		params = fmt.aprint(line.attributes["params"]),
		hash   = fmt.aprint(line.attributes["hash"]),
		host   = player,
	}
	append(&server.lobbies, lobby)
	broadcast(server, lobby_line(lobby))
	enter(server, player, lobby)
}

// JOIN <lobby id>
@(private = "file")
join :: proc(server: ^Server, player: ^Player, line: kipp.Line) {
	lobby: ^Lobby
	if len(line.subject) > 0 do for candidate in server.lobbies do if candidate.id == line.subject[0] do lobby = candidate
	switch {
	case player.lobby != nil:                         refuse(player, "JOIN", "badarg", "leave the lobby first")
	case lobby == nil:                                refuse(player, "JOIN", "badarg", "no such lobby")
	case len(lobby.players) >= online.LOBBY_PLAYERS_MAX: refuse(player, "JOIN", "badarg", "the lobby is full")
	case:                                             enter(server, player, lobby)
	}
}

@(private = "file")
enter :: proc(server: ^Server, player: ^Player, lobby: ^Lobby) {
	player.lobby = lobby
	player.seat = .Unready
	append(&lobby.players, player)
	broadcast(server, player_line(lobby, player))
}

// Out of its lobby: a running match ends, an empty lobby closes, and a host's leaving makes the next player host.
@(private = "file")
leave :: proc(server: ^Server, player: ^Player) {
	lobby := player.lobby
	if lobby == nil do return
	if lobby.match != nil do end_match(server, lobby)
	for member, index in lobby.players do if member == player {
		ordered_remove(&lobby.players, index)
		break
	}
	player.lobby = nil
	broadcast(server, write("drop", {"player", lobby.id, player.key}))
	if len(lobby.players) == 0 {
		broadcast(server, write("drop", {"lobby", lobby.id}))
		for candidate, index in server.lobbies do if candidate == lobby {
			ordered_remove(&server.lobbies, index)
			break
		}
		lobby_free(lobby)
	} else if lobby.host == player {
		lobby.host = lobby.players[0]
		broadcast(server, lobby_line(lobby))
	}
}

// READY loadout=<hex>: when every seat is taken and ready, the match starts.
@(private = "file")
ready :: proc(server: ^Server, player: ^Player, line: kipp.Line) {
	lobby := player.lobby
	loadout := line.attributes["loadout"]
	_, loadout_read := hex.decode(transmute([]byte)loadout, context.temp_allocator)
	switch {
	case lobby == nil:                               refuse(player, "READY", "badarg", "join a lobby first")
	case lobby.match != nil:                         refuse(player, "READY", "badarg", "the match is running")
	case !loadout_read || len(loadout) > 2 * online.LOADOUT_MAX: refuse(player, "READY", "badarg", "the loadout does not read")
	case:
		delete(player.loadout)
		player.loadout = fmt.aprint(loadout)
		player.seat = .Ready
		broadcast(server, player_line(lobby, player))
		for member in lobby.players do if member.seat != .Ready do return
		if len(lobby.players) == online.LOBBY_PLAYERS_MAX do start_match(server, lobby)
	}
}

// DONE: this player's match has ended; when every player says so, the lobby is open for a rematch.
@(private = "file")
done :: proc(server: ^Server, player: ^Player) {
	lobby := player.lobby
	if lobby == nil || lobby.match == nil do return
	player.seat = .Done
	for member in lobby.players do if member.seat != .Done do return
	end_match(server, lobby)
}

@(private = "file")
start_match :: proc(server: ^Server, lobby: ^Lobby) {
	match := Match{token = rand.uint32() | 1, seed = rand.uint64()}
	lobby.match = match
	broadcast(server, match_line(lobby, match))
	fmt.eprintfln("lobbies: match %08x in lobby %s", match.token, lobby.id)
}

// Every player is unready again.
@(private = "file")
end_match :: proc(server: ^Server, lobby: ^Lobby) {
	lobby.match = nil
	broadcast(server, write("drop", {"match", lobby.id}))
	for member in lobby.players {
		member.seat = .Unready
		broadcast(server, player_line(lobby, member))
	}
}

// A session packet with the match's token goes to the other player.
@(private = "file")
forward :: proc(player: ^Player, packet: []byte) {
	lobby := player.lobby
	if lobby == nil do return
	match, running := lobby.match.?
	if token, ok := online.packet_token(packet); !running || !ok || token != match.token do return
	for member in lobby.players do if member != player {
		enet.peer_send(member.peer, online.CHANNEL_SESSION, enet.packet_create(raw_data(packet), len(packet), {.UNSEQUENCED}))
	}
}

@(private = "file")
lobby_line :: proc(lobby: ^Lobby) -> string {
	return write("lobby", {lobby.id}, {"pack", lobby.pack}, {"mode", lobby.mode}, {"params", lobby.params}, {"hash", lobby.hash}, {"host", lobby.host.key})
}

@(private = "file")
player_line :: proc(lobby: ^Lobby, player: ^Player) -> string {
	return write("player", {lobby.id, player.key}, {"name", player.name}, {"ready", player.seat == .Unready ? "0" : "1"}, {"loadout", player.loadout})
}

@(private = "file")
match_line :: proc(lobby: ^Lobby, match: Match) -> string {
	return write("match", {lobby.id}, {"token", fmt.tprintf("%08x", match.token)}, {"seed", fmt.tprint(match.seed)},
		{"delay_ms", fmt.tprint(online.START_DELAY_MS)}, {"side0", lobby.players[0].key}, {"side1", lobby.players[1].key})
}

// A line the server wrote; its fields are ids, keys and cleaned values, so it always fits.
@(private = "file")
write :: proc(kind: string, subject: []string, attributes: ..kipp.Attribute) -> string {
	text, _ := kipp.write(kind, subject, ..attributes)
	return text
}

@(private = "file")
send :: proc(player: ^Player, kind: string, subject: []string, attributes: ..kipp.Attribute) {
	send_line(player, write(kind, subject, ..attributes))
}

@(private = "file")
send_line :: proc(player: ^Player, text: string) {
	enet.peer_send(player.peer, online.CHANNEL_CONTROL, enet.packet_create(raw_data(text), len(text), {.RELIABLE}))
}

@(private = "file")
refuse :: proc(player: ^Player, command, code, message: string) {
	send(player, "error", {code}, {"cmd", command}, {"msg", message})
}

// Every player past HELLO gets every fact.
@(private = "file")
broadcast :: proc(server: ^Server, text: string) {
	for player in connected(server) do send_line(player, text)
}

@(private = "file")
connected :: proc(server: ^Server) -> []^Player {
	players := make([dynamic]^Player, context.temp_allocator)
	for &peer in server.host.peers[:server.host.peerCount] {
		player := (^Player)(peer.data)
		if peer.state == .CONNECTED && player != nil && player.key != "" do append(&players, player)
	}
	return players[:]
}

@(private = "file")
lobby_free :: proc(lobby: ^Lobby) {
	for text in ([]string{lobby.id, lobby.pack, lobby.mode, lobby.params, lobby.hash}) do delete(text)
	delete(lobby.players)
	free(lobby)
}

@(private = "file")
player_free :: proc(player: ^Player) {
	player.peer.data = nil
	delete(player.key)
	delete(player.name)
	delete(player.loadout)
	free(player)
}
