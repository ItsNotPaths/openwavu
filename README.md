# openwavu

A home for 3D fighting games, in the spirit of ManiaPlanet. Everything that plays is a title pack:
one `.tar` with wasm modules and data. Packs can change frame data, cancels and reactions as database
rows, swap single files, or fork the whole fighting sim.

**Alpha.** Expect crashes, missing parts and breaking changes between versions.

Tekken 5 Dark Resurrection (PS3, NPUB30009) is the first game with an importer. No game data ships
here: you supply your own copy and openwavu builds the stock title pack from it on your machine.

## Play

1. Download `openwavu-linux.tar.gz` or `openwavu-windows.zip` from
   [Releases](https://github.com/ItsNotPaths/openwavu/releases) and unpack it. It is one program.
2. Run `openwavu`. In the left column, pick the empty slot (`+`), then **Game files**.
3. Point it at your Tekken 5 DR: an RPCS3 folder, the game folder, or the `.pkg` (with its `.rap`).
   The import takes about a minute and writes the stock pack.
4. Pick the pack and press Play. **Online** in the TK5 menu finds lobbies on openwavu.org.

openwavu updates itself: when a new version is out, the launcher offers it. A version ending in
`.imp` needs the stock pack imported again.

Your packs, saves and replays live in `~/.local/share/openwavu` (Linux) or `%APPDATA%\openwavu`
(Windows). Settings are in `~/.config/openwavu/settings.conf` (Linux) or the same folder (Windows).

## Online

- Rollback netcode. The sim is deterministic and saves and restores its whole state each frame.
- Matches go through a relay server. No peer to peer, so no one sees your IP.
- Lobbies: 2 players and up to 6 watchers, rematch after each match.
- The launcher's right column is the store of the network's packs.
- openwavu.org is one network. Anyone can run their own with `openwavu-server`
  (`install-server.sh`, see `docs/network.md`) and set `network=` in the settings.

## Build

Odin dev-2026-10 (pinned in `mise.toml`). Everything else goes into `vendor/` through
`download-deps.sh` (zig, wasmtime, SQLite, SDL3, Clay, curl, ENet, ...). No system packages.

```
./download-deps.sh
./build.sh                 # debug: build/openwavu, build/openwavu-import, build/modules/*.wasm
./build.sh speed           # optimized, ~5x faster import
./build.sh test            # then the tests (combines with speed)
./build.sh server speed    # build/openwavu-server
build/openwavu-import <rpcs3 dir | game dir | file.pkg [file.rap]> [-o packs] [-keep]
build/openwavu                       # launcher
build/openwavu --package <folder>    # writes <folder>.tar, pack.toml first
build/openwavu --front <pack> [file] # preview a pack's front page
```

The importer finds the RAP next to the `.pkg`, in `USRDIR`, or in RPCS3's
`dev_hdd0/home/*/exdata/`. The PS3 SELF keys ship here, as in RPCS3; the RAP is your license.

## Layout

- `src/game/`: `openwavu`, the launcher and host.
- `src/importer/`: `openwavu-import`. PS3 unpacking in `src/ps3/`, game readers in `src/formats/tk5/`,
  writers in `src/convert/`, the db in `src/db/`.
- `src/imports/`, `src/wasm/`: what the host serves to pack modules (wasmtime).
- `src/online/`, `src/server/`: rollback session, lobbies, relay, and `openwavu-server`.
- `sdk/`: C headers and helpers for pack modules (MIT-0).
- `modules/tk5/`: the stock TK5 modules (MIT-0). `sim/` is the fighting sim, built into
  `gameplay.wasm`; `app/` menus; `gamerender/` match drawing.
- `docs/`: `packs.md` (pack files, bases, db patches), `app.md` (modules), `network.md` (server),
  `formats.md`, `commands.md`, `launcher.md`.
- `tests/`: `odin test`. Reference checks need `../tk5decomp` and skip without it.

## License

GPL-3.0 only for the host. `sdk/` and `modules/tk5/` are MIT-0, so packs that only use the
`sdk/include` interface are yours to license. See `LICENSE`.
