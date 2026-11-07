package game

import "core:fmt"
import "core:strconv"
import "../imports"
import "../online"
import "../titlepack"

// The network's lobby server during one pack visit: the entry module's online intents go to it, and the host view
// shows it. Connected only between ow_online(1) and ow_online(0).
Lobbies :: struct {
	host:     string,  // the lobby server's name
	identity: online.Identity,
	name:     string,
	client:   ^online.Lobby_Client,  // nil while offline
	failed:   string,                // why the last connection failed or ended
	hashes:   map[string]string,     // a lobby's picks -> their lobby hash for this pack, "" when the pack refuses them
	played:   u32,                   // the token of the last match started here
}

lobbies_close :: proc(l: ^Lobbies) {
	go_offline(l)
	for picks, hash in l.hashes {
		delete(picks)
		delete(hash)
	}
	delete(l.hashes)
	delete(l.failed)
}

// The entry module's intents, in order.
lobbies_apply :: proc(l: ^Lobbies, tp: titlepack.Title_Pack, entry: ^imports.Entry) {
	defer {
		for intent in entry.intents do imports.lobby_intent_destroy(intent, entry.allocator)
		clear(&entry.intents)
	}
	for intent in entry.intents {
		if go, is_go := intent.(imports.Go_Online); is_go {
			if go.on do go_online(l)
			else do go_offline(l)
			continue
		}
		if l.client == nil do continue
		#partial switch asked in intent {
		case imports.Create_Lobby: online.lobby_create(l.client, pack_name(tp), asked.mode, asked.picks, picks_hash(l, tp, asked.picks))
		case imports.Join_Lobby:   online.lobby_join(l.client, fmt.tprintf("%08x", asked.id))
		case imports.Leave_Lobby:  online.lobby_leave(l.client)
		case imports.Ready:        online.lobby_ready(l.client, asked.loadout)
		}
	}
}

// Takes in what the server sent; a server that hung up leaves this player offline.
lobbies_pump :: proc(l: ^Lobbies) {
	if l.client == nil || online.lobby_pump(l.client) do return
	go_offline(l)
	delete(l.failed)
	l.failed = fmt.aprint("the lobby server hung up")
}

// The lobby of a match fact not started yet, or nil.
lobbies_new_match :: proc(l: ^Lobbies) -> ^online.Lobby {
	if l.client == nil do return nil
	lobby := online.lobby_joined(l.client)
	if lobby == nil do return nil
	match, running := lobby.match.?
	if !running || match.token == l.played do return nil
	l.played = match.token
	return lobby
}

lobbies_view :: proc(l: ^Lobbies, tp: titlepack.Title_Pack, view: ^imports.Host_View) {
	view.lobby_count, view.joined = 0, false
	imports.view_text(view.refused[:], l.failed)
	switch {
	case l.client != nil: view.connection = .Online
	case l.failed != "":  view.connection = .Failed
	case:                 view.connection = .Offline
	}
	if l.client == nil do return
	imports.view_text(view.refused[:], l.client.refused)
	joined := online.lobby_joined(l.client)
	for &lobby in l.client.lobbies {
		if view.lobby_count == imports.LOBBIES_MAX do break
		if &lobby == joined || !joinable(l, tp, &lobby) do continue
		view_lobby(l, &lobby, &view.lobbies[view.lobby_count])
		view.lobby_count += 1
	}
	if joined == nil do return
	view.joined = true
	view_lobby(l, joined, &view.lobby)
	for &seat, index in view.seats {
		seat = {}
		if index >= len(joined.players) do continue
		player := joined.players[index]
		imports.view_text(seat.name[:], player.name)
		seat.ready = b32(player.ready)
		if player.key == l.client.key do view.seat = u32(index)
	}
}

@(private = "file")
go_online :: proc(l: ^Lobbies) {
	if l.client != nil do return
	delete(l.failed)
	err: string
	l.client, err = online.lobby_connect(l.host, l.identity, l.name)
	if err != "" do l.client = nil  // lobby_connect freed it
	l.failed = fmt.aprint(err)
}

@(private = "file")
go_offline :: proc(l: ^Lobbies) {
	if l.client != nil do online.lobby_disconnect(l.client)
	l.client = nil
}

// This pack's, a free seat, no match, and the same lobby hash here.
@(private = "file")
joinable :: proc(l: ^Lobbies, tp: titlepack.Title_Pack, lobby: ^online.Lobby) -> bool {
	if lobby.pack != pack_name(tp) || len(lobby.players) >= 2 || lobby.match != nil do return false
	hash := picks_hash(l, tp, lobby.params)
	return hash != "" && hash == lobby.hash
}

// Cached: a stock base's hash is a file read, a tar pack's a full hash of the tar.
@(private = "file")
picks_hash :: proc(l: ^Lobbies, tp: titlepack.Title_Pack, picks: string) -> string {
	if known, has := l.hashes[picks]; has do return known
	hash := ""
	if parsed, read := titlepack.parse_params(picks, context.temp_allocator); read {
		if text, _, err := titlepack.lobby_hash_text(tp, parsed, context.temp_allocator); err == "" do hash = text
	}
	l.hashes[fmt.aprint(picks)] = fmt.aprint(hash)
	return l.hashes[picks]
}

@(private = "file")
view_lobby :: proc(l: ^Lobbies, lobby: ^online.Lobby, into: ^imports.View_Lobby) {
	id, _ := strconv.parse_u64_of_base(lobby.id, 16)
	into.id, into.players = u32(id), u32(len(lobby.players))
	host := online.lobby_player(lobby, lobby.host)
	imports.view_text(into.host[:], host != nil ? host.name : "")
	imports.view_text(into.mode[:], lobby.mode)
	imports.view_text(into.params[:], lobby.params)
}

@(private = "file")
pack_name :: proc(tp: titlepack.Title_Pack) -> string {
	return fmt.tprintf("%s@%s", tp.id, tp.version)
}
