# openwavu

An open home for 3D fighting games. You bring the game, openwavu runs it, and anyone can change it.

Everything that plays is a **title pack**: one `.tar` with wasm modules and data. A pack can be a
small balance patch, a new set of rules, or a whole new game built on the fighting sim. Packs are
shared through the launcher's store and played online with rollback netcode.

Tekken 5 Dark Resurrection (PS3) is the first game. openwavu ships no game data: you give it your
own copy, and it builds the stock pack on your machine.

> **Alpha.** It plays, online too, but expect crashes, missing parts, and changes that break packs
> between versions.

## What works now

- **Tekken 5 DR** from your own copy: characters, costumes, stages, the game's menu art.
- **The fighting sim** is a C port of the game's own code, checked against the original game in an
  emulator. Its moves, frames, cancels and reactions are rows in a database.
- **Modes:** Versus, Versus CPU, CPU vs CPU, and Online.
- **Online:** rollback netcode through a relay server. Lobbies hold 2 players and up to 6
  watchers, with a rematch after each match. The host sets the stage, health, damage, pushback,
  rounds and round time, and can kick, ban, or lock the lobby with a 4-digit code.
- **Launcher:** installed packs on the left, the store on the right, each pack's front page in the
  middle. Favourites, locked versions, button config, and self-updates.

## Play

You need Tekken 5 Dark Resurrection for PS3 (NPUB30009): an RPCS3 install of it, the game folder,
or the `.pkg` with its `.rap` (your license).

1. Download `openwavu-windows.zip` or `openwavu-linux.tar.gz` from
   [Releases](https://github.com/ItsNotPaths/openwavu/releases) and unpack it. It is one program.
2. Run `openwavu`. On the left, pick the empty slot (`+`), then **Game files**, and point it at
   your copy. The import takes about a minute.
3. Pick **Tekken 5: Dark Resurrection** and press Play. **Online** in its menu hosts or joins a
   lobby on openwavu.org.

When a new version is out, the top bar offers it. A version that ends in `.imp` changed the
importer, so the launcher imports your game again; a `.mod` version only swaps the modules.

| | Linux | Windows |
|---|---|---|
| Packs, saves, replays | `~/.local/share/openwavu` | `%APPDATA%\openwavu` |
| Settings | `~/.config/openwavu/settings.conf` | `%APPDATA%\openwavu\settings.conf` |

**Settings → Uninstall openwavu** deletes both folders and the program.

## Make a title pack

The smallest pack is two files. This one builds on the stock game and changes its data:

```
my_pack/
  pack.toml
  tk5.db.patch
```

```toml
id = "my_pack"
name = "My Pack"
version = "0.0.1"
bases = ["tekken5dr"]
```

`tk5.db.patch` is an SQLite database with the stock schema that holds only the rows you change. Open
the stock `tk5.db` in any SQLite editor to see the tables: each one is like a sheet in a
spreadsheet. A row in the patch replaces the row with the same key; a list (a move's cancels, say)
is replaced whole. Then:

```
openwavu --package my_pack       # writes my_pack.tar
```

Put the tar in your packs folder. From there a pack can go further:

- **Replace files.** A file at the same path as one in the base wins: art, models, the front page.
- **Change the rules.** Params in `pack.toml` (health, damage, round time, ...) that lobby hosts can set.
- **Fork the modules.** `modules/tk5/` is the stock sim, menus and match drawing, in C, built to wasm
  with the headers in `sdk/include`. Copy it, change it, ship your own `gameplay.wasm`.

Cancel inputs use one text form, for example `{n,f,n,f+1+2}20@1..255>1` for a throw. See
`docs/commands.md`. The pack format is in `docs/packs.md`, the data in `docs/formats.md`, the
module interface in `docs/app.md`.

## Run your own network

openwavu.org is one network. Anyone can run another with `openwavu-server`: one program for the
pack store and the lobbies. On a Linux box, in a clone of this repo, run `./install-server.sh` as
root: it builds the server and runs it under systemd (UDP 9288 for lobbies, HTTP on localhost for
the store, behind a TLS proxy as `serve.<your domain>`). Players set `network=<your domain>` in the
settings. See `docs/network.md`.

## Build

Odin dev-2026-10 (pinned in `mise.toml`). `download-deps.sh` puts everything else in `vendor/`
(zig, wasmtime, SQLite, SDL3, Clay, curl, ENet, ...). No system packages.

```
./download-deps.sh
./build.sh                 # debug: build/openwavu, build/openwavu-import, build/modules/<game>/*.wasm
./build.sh speed           # optimized, ~5x faster import
./build.sh test            # then the tests (combines with speed)
./build.sh server speed    # build/openwavu-server
build/openwavu-import <rpcs3 dir | game dir | file.pkg [file.rap]> [-o packs] [-keep]
build/openwavu --front <pack> [file]   # preview a pack's front page
```

The importer finds the `.rap` next to the `.pkg`, in `USRDIR`, or in RPCS3's
`dev_hdd0/home/*/exdata/`. The PS3 SELF keys ship here, as in RPCS3.

## Layout

```
src/game/       openwavu: launcher and host
src/importer/   openwavu-import; src/ps3 unpacks, src/formats/tk5 reads, src/convert writes, src/db
src/imports/    what the host gives pack modules; src/wasm runs them (wasmtime)
src/online/     rollback session, lobbies, relay
src/server/     openwavu-server: store and lobbies
src/render/     SDL3 GPU, Vulkan
sdk/            C headers and helpers for pack modules
modules/tk5/    stock modules: gameplay (sim), app (menus), gamerender (match drawing)
docs/           packs, formats, app, commands, network, launcher
tests/          odin test; reference checks need ../tk5decomp and skip without it
```

## License

The host is GPL-3.0 only. `sdk/` and `modules/tk5/` are MIT-0, so a pack that only uses
`sdk/include` is yours to license as you like. See `LICENSE`.
