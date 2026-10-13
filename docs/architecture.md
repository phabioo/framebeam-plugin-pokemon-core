# Architecture

## Layout

- `src/`: Lua modules (`core/*`, `gen6/*`, `main.lua`). The module list is `src/modules.txt`.
- `tools/bundle.lua`: generates `plugin/main.lua`.
- `plugin/`: the installable plugin (`manifest.json`, generated `main.lua`, `i18n/`). `plugin/main.lua` is committed; never edit it by hand.
- `tests/`: `lua5.4 tests/run.lua` runs every `tests/test_*.lua` against a fake `fb` (`tests/support/fb_mock.lua`) with synthetic data only.

## Bundling

The FrameBeam sandbox has no `require`, `load`, `dofile`, `io` or `os` and loads one entry file. The bundler wraps each listed module as `__mod["core.games"] = function(...) ... end`, defines a local `require` (loads each module once, returns `nil` for unknown names) and calls `require("main")`. Output is deterministic. `lua5.4 tools/bundle.lua` writes, `--check` exits 1 when `plugin/main.lua` is stale (CI). A new module must be added to `src/modules.txt`; a listed module whose file is missing is skipped.

## Detection

`core.games` holds `GAMES` (`id, name, gen, system, codes, version, adapter`). `detect(fb.game)` returns `entry, info` or `nil`.

- 3DS: exact, case-insensitive match of the title ID. Title IDs are the same for all languages, so `info.language` is `nil` (the adapter detects it at runtime).
- NDS/GBA: first 3 chars of the 4-char game code select the game; the 4th char is the region: D=de, F=fr, I=it, S=es, E=en, P=en (EU English), J=ja, K=ko, others `nil`.
- `name` is a text identifier only; game names are read from the game at runtime.

## Interface `pokemon.core`

`core.interface.new(entry, detected, adapter)` builds the table for `fb.provide("pokemon.core", tbl)`.

- `info()` returns `{ game_id, name, gen, system, version, language, revision, supported, features = { team, box, location, battle, encounters, badges } }`. `features` says which methods the adapter has; `language` is `adapter:language()` if present, else the detected language.
- `features` also has `icons` (icon archive found) and `map` (map scan finished with at least one candidate). An adapter can override feature flags that depend on runtime state through an optional `features()` method (location is true only with a configured address).
- `icon(species, form)` returns a PNG string of the box icon, or `nil, "not_ready" | "unsupported" | "unknown_species"`. `form` defaults to 0. PNGs are cached in `fb.cache` (`icons/<species>-<form>.png`).
- `location()` returns `{ zone = <u16>, source = "memory" }` (ORAS), `nil, "unsupported"` without a configured address, `nil, "not_ready"` while unreadable.
- `map_candidates()` returns `{ {id, w, h}, ... }` (largest area first, at most 40) or `nil, "not_ready"` during the scan; `map_image(id)` returns the PNG (`nil, "not_ready" | "unknown_map" | "too_large"`, values stay below 1 MiB); `map_selected()` returns the confirmed map id of the game or `nil`.
- `team()`, `box(n)`, `box_count()`, `location()`, `battle()`, `encounters()`, `badges()` delegate to the adapter method of the same name. Without adapter or method they return `nil, "unsupported"`; an adapter may return `nil, "not_ready"`, which is passed through.

Generic Pokémon record (adapters fill what they can, unknown fields are `nil`; all IDs are the game's internal IDs, names come from the game, never from tables):

`{ species, form, nickname, level, exp, personality, shiny, gender, nature, ability, held_item, moves = {ids...}, ot_name, ot_id, ot_sid, language, egg, hp, max_hp, status, slot, box }`

## Adapter contract

An adapter module exports `attach(ctx)` with `ctx = { fb = fb, game = entry, detected = info }`. It registers its memory watches and returns an adapter object with any of `revision() language() team() box(n) box_count() location() battle() encounters() badges() icon(species, form) map_candidates() map_image(id) map_selected() features() tick()`, called with `:` (the adapter is `self`). Adapters read only through `ctx.fb`. `core.adapters` is a static registry keyed by module name; a missing module is skipped, so an entry without a usable adapter runs with `supported = false`.

## Entry and events

`main.lua`: unknown game logs `not_pokemon` and returns. Known game without adapter logs `no_adapter` and still provides the interface (`supported = false`). With an adapter: provide, emit `game.detected` `{ game_id, gen, supported }` once, every tick call the adapter's optional `tick()` (bounded background work such as icon/map discovery), then every 15th tick call `team()` and emit `team.changed` `{ team = list }` when its deterministic serialization (`core.serialize`) changed. All user-visible strings go through `fb.i18n.t` (`plugin/i18n/en.json` source, `de.json`).

## Adding a game

1. Add the entry to `core.games` (`GAMES`) and, for 3DS/NDS, the code to `plugin/manifest.json`.
2. Write the adapter `src/<genN>/<name>.lua` (contract above) plus synthetic-data tests.
3. Register it in `core.adapters` and add its modules to `src/modules.txt`; set `adapter` in the entry.
4. Document offsets and formats in `docs/games/<game>.md`; run `lua5.4 tools/bundle.lua`.

## Background discovery

Icon and map discovery (`gen6.icons`, `gen6.maps`) are state machines advanced by `adapter:tick()` (and by `not_ready` calls). One step is one directory listing, one RomFS file read plus a bounded batch of GARC entries, or one candidate validation, so no entry call comes near the 500 ms / 20M instruction budget. Results are persisted in `fb.cache` (`icons/index.txt`, `map/index.txt`, `map/files.txt`, `map/progress.txt`) and later starts skip the work. Only derived data (paths, sizes, PNGs of the user's own game) is cached; nothing is shipped.

## Open

- Gen 1/2: game identification on GB/GBC is open in FrameBeam; no entries yet.
- 3DS language detection (done by the adapter at runtime, source open).
- Names from game text (species, moves, items, locations) are not implemented yet.
- Format of `fb.game.code` for 3DS (assumed: 16 hex digits title ID) and the system names `3ds`/`nds`/`gba` are not specified in the plugin API doc.
