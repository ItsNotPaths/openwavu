# openwavu

A ManiaPlanet-like home for 3D fighting games. Everything that plays is a title pack: a `.tar` with
wasm modules and data.

Tekken 5 Dark Resurrection (PS3, NPUB30009) is the first game with an importer. You supply your own
copy, and the importer turns it into a stock title pack: `tk5.db`, glb parts and stages, `.anim`
files, UI images and the stock wasm modules.

No game data ships here. The PS3 SELF keys do, as in RPCS3. You supply the RAP (your license).

- `src/game/`: `openwavu`, the launcher and host. Runs packs from `packs/*.tar`.
- `src/importer/`: `openwavu-import`. PS3 unpacking in `src/ps3/`, game readers in `src/formats/tk5/`,
  writers in `src/convert/`, the db in `src/db/`.
- `src/imports/`, `src/wasm/`: what the host serves to pack modules (wasmtime).
- `sdk/`: C headers and helpers for pack modules (MIT-0).
- `modules/tk5/`: the stock TK5 modules (MIT-0). `sim/` is the fighting sim, built into
  `gameplay.wasm`; `app/` menus; `gamerender/` match drawing.
- `docs/`: `packs.md` (pack files, bases, db patches), `app.md` (modules), `formats.md`,
  `commands.md`, `launcher.md`.
- `tests/`: `odin test`. Reference checks need `../tk5decomp` and skip without it.

## Build

Odin dev-2026-09 or later. Everything else goes into `vendor/` through `download-deps.sh` (zig,
wasmtime, SQLite, SDL3, Clay, ...). No system packages.

```
./build.sh                 # debug: build/openwavu, build/openwavu-import, build/modules/*.wasm
./build.sh speed           # optimized, ~5x faster import
./build.sh test            # then the tests (combines with speed)
build/openwavu-import <rpcs3 dir | game dir | file.pkg [file.rap]> [-o packs] [-keep]
build/openwavu                      # launcher
build/openwavu --package <folder>   # writes <folder>.tar, pack.toml first
build/openwavu --front <pack> [file] # preview a pack's front page
```

The importer finds the RAP next to the `.pkg`, in `USRDIR`, or in RPCS3's
`dev_hdd0/home/*/exdata/`. A full import takes about 45 s and writes a 500 MB tar.

## License

GPL-3.0 only for the host. `sdk/` and `modules/tk5/` are MIT-0. Pack modules that only use the
`sdk/include` interface are not covered by the GPL. See `LICENSE`.