// openwavu-bot <lobby host> <pack folder> [character]: the online test's dummy player. Joins any open lobby of its
// pack whose hash matches its own, readies with the character (TK5 loadout, costume 1), presses random buttons on its
// side at 60 Hz, then readies again for the rematch.
package bot

import "core:encoding/endian"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"
import "../../content"
import "../../online"
import "../../online/wire"
import "../../sim"
import "../../titlepack"
import "../../wasm"

TICK :: time.Second / 60
PAD_DIRECTIONS_AND_BUTTONS :: 0xff  // OW_PAD_UP..OW_PAD_BUTTON_4; never START
T5_NAME_BYTES :: 32  // modules/tk5/loadout.h: character name, then the costume as a u32

main :: proc() {
	if len(os.args) < 3 || len(os.args) > 4 {
		fmt.eprintln("usage: openwavu-bot <lobby host> <pack folder> [character]")
		os.exit(2)
	}
	host, pack_path := os.args[1], os.args[2]
	character := len(os.args) == 4 ? os.args[3] : "kazuya"
	manifest, manifest_read := titlepack.read_manifest(pack_path, context.temp_allocator)
	tp, tp_read := titlepack.read_titlepack(manifest)
	if !manifest_read || !tp_read {
		fmt.eprintfln("openwavu-bot: %s has no pack.toml that reads", pack_path)
		os.exit(1)
	}
	tp.path = strings.trim_right(pack_path, "/")  // its hash file sits beside it
	pack, opened := content.open_pack(pack_path)
	if !opened {
		fmt.eprintfln("openwavu-bot: %s did not open", pack_path)
		os.exit(1)
	}
	defer content.close_pack(&pack)
	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	loadout: [T5_NAME_BYTES + 4]byte
	copy(loadout[:T5_NAME_BYTES - 1], character)
	endian.put_u32(loadout[T5_NAME_BYTES:], .Little, 1)
	for {
		if err := stay(engine, &pack, tp, host, loadout[:]); err != "" do fmt.eprintln("openwavu-bot:", err)
		free_all(context.temp_allocator)
		time.sleep(time.Second)
	}
}

// One connection: join, ready, play, ready again, until the server hangs up or a match fails.
stay :: proc(engine: wasm.Engine, pack: ^content.Pack, tp: titlepack.Title_Pack, host: string, loadout: []byte) -> (err: string) {
	client: ^online.Lobby_Client
	if client, err = online.lobby_connect(host, online.new_identity(), "bot"); err != "" do return
	defer online.lobby_disconnect(client)
	fmt.eprintln("openwavu-bot: waiting for a lobby")
	played: u32  // the last match's token: its fact stays until the other player is done too
	hashes: online.Lobby_Hashes
	defer online.lobby_hashes_destroy(&hashes)
	for online.lobby_pump(client, 100) {
		lobby := online.lobby_joined(client)
		switch {
		case lobby == nil:
			if open := open_lobby(client, tp, &hashes); open != "" do online.lobby_join(client, open)
		case len(lobby.players) == 1:
			online.lobby_leave(client)  // everyone else left: wait for the next lobby
		case online.lobby_player(lobby, client.key).side < 0 || seated(lobby) < wire.SIDES:
			// in line for a seat, or waiting for an opponent to take the other
		case lobby.match != nil:
			if lobby.match.?.token == played do break
			played = lobby.match.?.token
			if err = play(engine, pack, tp, client, lobby); err != "" do return
		case !online.lobby_player(lobby, client.key).ready:
			online.lobby_ready(client, loadout)
		}
		free_all(context.temp_allocator)
	}
	return "the lobby server hung up"
}

seated :: proc(lobby: ^online.Lobby) -> (count: int) {
	for player in lobby.players do if player.side >= 0 do count += 1
	return
}

// A lobby this pack can join; "" when there is none.
open_lobby :: proc(client: ^online.Lobby_Client, tp: titlepack.Title_Pack, hashes: ^online.Lobby_Hashes) -> string {
	for &lobby in client.lobbies do if online.lobby_joinable(hashes, tp, &lobby) do return lobby.id
	return ""
}

play :: proc(engine: wasm.Engine, pack: ^content.Pack, tp: titlepack.Title_Pack, client: ^online.Lobby_Client, lobby: ^online.Lobby) -> (err: string) {
	defer online.lobby_done(client)
	opening, started := online.match_start(client, lobby)
	if !started do return "the match fact does not read"
	mode: titlepack.Mode
	for candidate in tp.modes do if candidate.name == lobby.mode do mode = candidate
	code, found := content.pack_file(pack^, mode.sim)
	if !found do return fmt.tprintf("the pack has no mode %s", lobby.mode)
	module: wasm.Module
	if module, err = wasm.compile(engine, code); err != "" do return
	defer wasm.module_destroy(module)
	picks, _ := titlepack.parse_params(lobby.params, context.temp_allocator)
	_, params, refused := titlepack.lobby_hash_text(tp, picks, context.temp_allocator)
	if refused != "" do return refused
	world: ^sim.World
	if world, err = sim.create(engine, module, pack, params, opening.loadouts, opening.seed); err != "" do return
	defer sim.destroy(world)
	clock := time.tick_now()
	session := online.session_create(world, online.lobby_transport(client), opening.side, opening.token, 0)
	defer online.session_destroy(session)
	if opening.start_in > 0 do time.sleep(opening.start_in)

	fmt.eprintfln("openwavu-bot: playing side %d", opening.side)
	pad: sim.Input
	held := 0  // frames the pad has left
	for next := time.tick_now(); ; next = time.tick_add(next, TICK) {
		if held == 0 do pad, held = {rand.uint32() & PAD_DIRECTIONS_AND_BUTTONS}, rand.int_max(10) + 3
		held -= 1
		if _, err = online.session_tick(session, pad, u64(time.tick_since(clock))); err != "" do return
		if session.outcome != .Playing do return fmt.tprintf("the match ended: %v", session.outcome)
		if winner, ended := online.session_match_end(session); ended {
			fmt.eprintfln("openwavu-bot: the match ended, winner side %d", winner)
			online.session_linger(session, u64(time.tick_since(clock)))
			return
		}
		time.sleep(time.tick_diff(time.tick_now(), next) + TICK)
	}
}
