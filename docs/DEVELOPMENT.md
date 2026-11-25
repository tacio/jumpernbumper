# Developing Jumper 'n Bumper

This guide covers building, testing and releasing the game. For installing and playing, see the [README](../README.md).

## Prerequisites

| Tool | Used for |
| --- | --- |
| [Godot 4.7.2](https://godotengine.org/download/archive/) | Client, headless tests, exports (exports also need the 4.7.2 export templates) |
| [Rust](https://rustup.rs/) + `rustup target add wasm32-unknown-unknown` | Simulation crate and server module |
| [SpacetimeDB CLI 2.16](https://spacetimedb.com/install) | Local server, publishing |
| [just](https://github.com/casey/just) | Command runner (`justfile`) |
| Python 3.12+ with `websockets`; `pillow` and `numpy` for asset generation | E2E tests, `tools/gen_assets.py` |

The `justfile` and scripts find tools through environment variables, whose defaults point to the maintainer's machine. Set them to match yours:

```bash
export GODOT_BIN=/path/to/Godot_v4.7.2-stable_linux.x86_64
export SPACETIME_BIN=$(command -v spacetime)
# optional: STDB_DB_NAME (default jumpernbumper), STDB_LISTEN_ADDR (default 127.0.0.1:3000)
```

## Everyday commands

```bash
just server        # start local SpacetimeDB (data kept in .spacetime-data/) and publish the module
just client        # run one client; `just client2` runs two side by side
just editor        # open the project in the Godot editor
just test          # full test suite (phases 1–4, below)
just lint          # cargo clippy -D warnings (CI fails on any warning)
just assets        # regenerate sprites/tiles/SFX and copy shared/*.json -> client/data/
just clean         # remove Rust/Godot build output and local server data
```

Run `just` with no arguments to list every recipe.

## Tests

`just test` runs `scripts/run_tests.sh`, which runs four phases in order. Each phase can also be run on its own:

| Phase | Command | What it covers |
| --- | --- | --- |
| 1 | `just test-rust` | Rust unit tests for physics, stomps, spawns, bots and victory rules |
| 2 | `just test-phase2` | Clippy, then a throwaway in-memory SpacetimeDB on port 3100: a Godot wire-protocol smoke test and the Python multi-client E2E (`tools/phase2_e2e_test.py`), which covers rooms, privacy, host migration, a live stomp and both win modes |
| 3 | `just test-phase3` | Regenerates assets and runs the headless arena renderer test |
| 4 | `just test-phase4` | GDScript syntax check, a 400×256 UI-bounds smoke test, and a host + guest E2E with two headless Godot processes |

Running a single test:

```bash
cargo test --manifest-path server/Cargo.toml -p sim <test_name>
"$GODOT_BIN" --headless --path client --check-only -s res://scripts/GameWorld.gd
"$GODOT_BIN" --headless --path client -s res://tests/test_phase4_client.gd -- --smoke
```

When you add a GDScript file, add it to `GDSCRIPTS` in `scripts/test_phase4.sh` so it gets syntax-checked.

## How it fits together

```
 Godot client ──WebSocket (v1.json.spacetimedb)──▶ SpacetimeDB module ──calls──▶ sim crate
   sends inputs via reducers                       private tables + views         pure physics
   renders the rows it receives                    30 Hz match_tick               and bot AI
```

- **The server is authoritative.** Clients only call reducers (`create_room`, `send_input`, …) and draw what they receive. A scheduled `match_tick` reducer runs about every 33 ms while any match is in progress and calls `sim::step_room`.
- **`server/sim/`** is deterministic Rust with no SpacetimeDB dependency, so it is easy to unit-test. It reads `shared/physics_constants.json` and `shared/classic_meadow.json` at compile time.
- **`server/spacetimedb/`** defines the tables and reducers. **All tables are private.** Clients subscribe to views that only return the caller's own data (`my_player`, `my_room`, `my_room_member`, `my_match_bunny`, `my_kill_event`) and to `public_room`, a lobby listing without room codes. This keeps private room codes secret and sends match updates only to players in that match. Don't make a table `public`, and don't expose `Room.code` to people outside the room.
- **`client/autoload/SpacetimeWire.gd`** is a hand-written client for SpacetimeDB's JSON WebSocket protocol, since Godot has no official SDK. Updated rows arrive as positional arrays, and it decodes them using the column lists in `table_schemas.json`.
- **`client/autoload/SpacetimeClient.gd`** keeps a local copy of the subscribed views and sends signals when they change. **`client/scripts/Main.gd`** chooses the screen (connect → room browser → lobby → game → podium) from that state.

### Data that must stay in sync

- `shared/` is the source of truth. `client/data/` is a byte-for-byte copy made by `just assets`, so never edit it directly.
- `shared/table_schemas.json` is keyed by **view name**. If you change a row type's fields (order matters), update the Rust struct, the column list in the comment at the top of `server/spacetimedb/src/lib.rs`, and `shared/table_schemas.json`, then run `just assets`.
- A new view also has to be added to `TABLE_NAMES` / `_extract_pk` in `SpacetimeClient.gd`, `VIEW_TO_MIRROR` in `tools/phase2_e2e_test.py`, and `VIEW_NAMES` in `client/tests/phase2_smoke.gd`.
- **Schema migrations:** a column added to an existing table must go at the end and have a `#[default(...)]`, otherwise publishing over existing data fails with "requires manual migration".

### Art and sound

Sprites, tiles, background, particles and sound effects are generated by `tools/gen_assets.py`. Change the generator and run `just assets` rather than editing the PNG/WAV files.

## CI and releases

`.github/workflows/release.yml`:

- **Every push and PR to `main`** runs the Rust tests and clippy.
- **`v*` tags** (or a manual run with `gh workflow run release.yml --ref <branch>`) also export Linux, Windows and macOS builds. A tag additionally publishes a GitHub Release with the three archives.

To make a release:

```bash
git checkout main && git pull
just test
git tag v0.1.2 && git push origin v0.1.2
```

Then update any running servers (see "Updating the server" in the README). Clients and server must be on the same version.

Building locally (requires the Godot 4.7.2 export templates): `just package-all` writes the three archives to `dist/`.
