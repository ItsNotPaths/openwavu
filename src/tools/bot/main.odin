// openwavu-bot <relay host> <pack>: the online test's dummy player. Waits on the relay, takes the match the paired
// player sends, presses random buttons on its side at 60 Hz, then waits for the next player.
package bot

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:time"
import "../../content"
import "../../imports"
import "../../online"
import "../../online/relay"
import "../../sim"
import "../../wasm"

WAIT_MS :: 600_000
SETUP_TIMEOUT_MS :: 5000
TICK :: time.Second / 60
PAD_DIRECTIONS_AND_BUTTONS :: 0xff  // OW_PAD_UP..OW_PAD_BUTTON_4; never START

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: openwavu-bot <relay host> <pack>")
		os.exit(2)
	}
	host, pack_path := os.args[1], os.args[2]
	pack, opened := content.open_pack(pack_path)
	if !opened {
		fmt.eprintfln("openwavu-bot: %s did not open", pack_path)
		os.exit(1)
	}
	defer content.close_pack(&pack)
	engine := wasm.engine_create()
	defer wasm.engine_destroy(engine)
	for {
		if err := play_one(engine, &pack, host); err != "" do fmt.eprintln("openwavu-bot:", err)
		free_all(context.temp_allocator)
		time.sleep(time.Second)
	}
}

play_one :: proc(engine: wasm.Engine, pack: ^content.Pack, host: string) -> (err: string) {
	client, connected := online.relay_connect(host, relay.PORT)
	if !connected do return "the relay did not answer"
	defer online.relay_disconnect(client)
	fmt.eprintln("openwavu-bot: waiting for a player")
	paired, start_in_ns, started := online.relay_wait_start(client, WAIT_MS)
	if !started do return "nobody came"
	waited := time.tick_now()
	message, sent := online.relay_receive_control(client, SETUP_TIMEOUT_MS)
	if !sent do return "the player sent no match"
	setup, read := relay.setup_decode(message)
	if !read do return "the match message does not read"

	code, found := content.pack_file(pack^, setup.sim)
	if !found do return fmt.tprintf("the pack has no %s", setup.sim)
	module: wasm.Module
	if module, err = wasm.compile(engine, code); err != "" do return
	defer wasm.module_destroy(module)
	params, params_read := imports.parse_params(setup.params, context.temp_allocator)
	if !params_read do return "the params do not read"
	world: ^sim.World
	if world, err = sim.create(engine, module, pack, params, setup.loadouts, paired.seed); err != "" do return
	defer sim.destroy(world)
	clock := time.tick_now()
	session := online.session_create(world, online.relay_transport(client), paired.side, paired.token, 0)
	defer online.session_destroy(session)
	if left := time.Duration(start_in_ns) - time.tick_since(waited); left > 0 do time.sleep(left)

	fmt.eprintfln("openwavu-bot: playing side %d", paired.side)
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
