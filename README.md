# openwavu

A Tekken sandbox. You supply your own copy of Tekken 5 Dark Resurrection (PS3, NPUB30009).
The importer converts its characters, movesets, animations and stages to open formats and a
SQLite database. The game runs on those formats with the fighting simulation from
`../tk5decomp` (C11, linked as a library).

This repo ships no game data. It ships the PS3 SELF keys, as RPCS3 does. The user supplies the
RAP file (the license for their copy).

## Layout

Code for one game goes in a `tk5/` subfolder, so that a `tk6/` can come later.

- `src/importer/`: the `openwavu-import` CLI. `tk5/` finds the game files and runs the pipeline.
- `src/db/`: the database schema (shared tables, and `tk5/` for the movesets). The importer
  writes it and the game reads it.
- `src/ps3/`: SELF decryption, .pkg unpacking, the keys, PARAM.SFO. The same for all PS3 games.
- `src/formats/tk5/`: readers of the game's own bytes (archive, motbin, anims, skeleton, meshes,
  textures, stages). No file I/O policy, only bytes in and structs out. `build.odin` holds the
  values that differ per game build (title ID, file table offset).
- `src/convert/`: glb and DDS writers for all games. `tk5/` turns the readers' structs into
  parts, stages, `.anim` files and database rows.
- `tests/`: checks the importer against the Python reference tools in `../tk5decomp/tools/`.
- `docs/formats.md`: the content pack layout and the open formats.

## Build

```
./download-deps.sh         # vendor/wasmtime (the build runs it when missing)
./build.sh                 # debug build/openwavu-import and build/openwavu (seconds)
./build.sh speed           # optimized, for releases: slow build, ~5x faster import
./build.sh test            # then the tests (combines with speed)
build/openwavu-import <rpcs3 dir | game dir | file.pkg [file.rap]> [-o packs] [-keep]
build/openwavu --package <folder>   # <folder>.tar, pack.toml first
```

The importer finds the RAP next to the `.pkg`, in the game's `USRDIR` or in RPCS3's `dev_hdd0/home/*/exdata/`.
A folder holding a `.pkg` works as an input too.
A full import takes about 45 s and writes a 500 MB tar. It links the system `libsqlite3` and `libz`.

The tests compare against the Python tools and the game files in `../tk5decomp`. Without them,
the tests skip.

Odin (dev-2026-09 or later). The game side will render with SDL3 (vendor:sdl3). The format readers follow `../tk5decomp/docs/data.md` and
`stages.md`; the Python tools there are the reference implementation.
