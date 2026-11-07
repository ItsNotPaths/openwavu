package game

import "core:fmt"
import "core:slice"
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
	connection: imports.Connection,   // Offline -> Online or Failed (go_online); Online -> Failed (hang_up); any -> Offline (go_offline)
	client:     ^online.Lobby_Client,  // only while Online
	failed:     string,                // only while Failed: why
	hashes:     online.Lobby_Hashes,
	played:   u32,                   // the token of the last match started here
	joined:   string,                // the id of the lobby this player is in; "" for none
}

lobbies_close :: proc(l: ^Lobbies) {
	go_offline(l)
	delete(l.joined)
	online.lobby_hashes_destroy(&l.hashes)
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
		if l.connection != .Online do continue
		#partial switch asked in intent {
		case imports.Create_Lobby: online.lobby_create(l.client, titlepack.pack_name(tp.id, tp.version), asked.mode, asked.picks, online.picks_hash(&l.hashes, tp, asked.picks))
		case imports.Join_Lobby:   online.lobby_join(l.client, fmt.tprintf("%08x", asked.id))
		case imports.Leave_Lobby:  online.lobby_leave(l.client)
		case imports.Queue:        online.lobby_queue(l.client, asked.on)
		case imports.Set_Params:   online.lobby_params(l.client, asked.picks, online.picks_hash(&l.hashes, tp, asked.picks))
		case imports.Ready:        online.lobby_ready(l.client, asked.loadout)
		}
	}
}

// Takes in what the server sent.
lobbies_pump :: proc(l: ^Lobbies) {
	if l.connection == .Online && !online.lobby_pump(l.client) do hang_up(l, "the lobby server hung up")
}

// The lobby of a match fact not started yet, or nil. A match already running when this player joined is not watched.
lobbies_new_match :: proc(l: ^Lobbies) -> ^online.Lobby {
	if l.connection != .Online do return nil
	lobby := online.lobby_joined(l.client)
	if lobby == nil {
		delete(l.joined)
		l.joined = ""
		return nil
	}
	match, running := lobby.match.?
	if lobby.id != l.joined {
		delete(l.joined)
		l.joined = fmt.aprint(lobby.id)
		if running do l.played = match.token
	}
	if !running || match.token == l.played do return nil
	l.played = match.token
	return lobby
}

lobbies_view :: proc(l: ^Lobbies, tp: titlepack.Title_Pack, view: ^imports.Host_View) {
	view.connection = l.connection
	view.lobby_count, view.joined, view.seat, view.hosting, view.watching, view.queued, view.watcher_count = 0, false, 0, false, false, false, 0
	imports.view_text(view.refused[:], l.failed)
	if l.connection != .Online do return
	imports.view_text(view.refused[:], l.client.refused)
	joined := online.lobby_joined(l.client)
	for &lobby in l.client.lobbies {
		if view.lobby_count == imports.LOBBIES_MAX do break
		if &lobby == joined || !online.lobby_joinable(&l.hashes, tp, &lobby) do continue
		view_lobby(l, &lobby, &view.lobbies[view.lobby_count])
		view.lobby_count += 1
	}
	if joined == nil do return
	view.joined = true
	view_lobby(l, joined, &view.lobby)
	view.hosting = joined.host == l.client.key
	view.seats = {}
	for player in joined.players do if player.side >= 0 {
		imports.view_text(view.seats[player.side].name[:], player.name)
		view.seats[player.side].ready = b32(player.ready)
	}
	me := online.lobby_player(joined, l.client.key)
	view.seat, view.watching, view.queued = u32(max(me.side, 0)), me.side < 0, me.queued > 0
	watchers := make([dynamic]online.Lobby_Player, context.temp_allocator)
	for player in joined.players do if player.side < 0 do append(&watchers, player)
	slice.stable_sort_by(watchers[:], proc(a, b: online.Lobby_Player) -> bool {
		return a.queued != 0 && (b.queued == 0 || a.queued < b.queued)
	})
	for player in watchers[:min(len(watchers), imports.WATCHERS_MAX)] {
		watcher := &view.watchers[view.watcher_count]
		imports.view_text(watcher.name[:], player.name)
		watcher.queued = player.queued > 0
		view.watcher_count += 1
	}
}

@(private = "file")
go_online :: proc(l: ^Lobbies) {
	if l.connection == .Online do return
	go_offline(l)
	client, err := online.lobby_connect(l.host, l.identity, l.name)
	if err != "" {
		hang_up(l, err)  // lobby_connect freed the client
		return
	}
	l.client, l.connection = client, .Online
}

@(private = "file")
go_offline :: proc(l: ^Lobbies) {
	if l.connection == .Online do online.lobby_disconnect(l.client)
	delete(l.failed)
	l.client, l.failed, l.connection = nil, "", .Offline
}

@(private = "file")
hang_up :: proc(l: ^Lobbies, why: string) {
	go_offline(l)
	l.failed, l.connection = fmt.aprint(why), .Failed
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
