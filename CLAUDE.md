# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Online multiplayer arena platformer (stomp rival bunnies' heads). Godot 4.7.2 GDScript client + SpacetimeDB 2.16 Rust server module. Up to 4 players per room (slots 0–3), with optional server-controlled bot bunnies.

## Commands

All workflows go through `just` (see `justfile`). Tool paths come from env vars with machine-specific defaults: `GODOT_BIN`, `SPACETIME_BIN`, `STDB_DB_NAME` (default `jumpernbumper`), `STDB_LISTEN_ADDR` (default `127.0.0.1:3000`).

```bash
just server        # start local SpacetimeDB (data in .spacetime-data/) and publish the module
just client        # run one Godot client; `just client2` runs two for local multiplayer
just test          # full suite: scripts/run_tests.sh (phases 1–4)
just test-rust     # cargo test --manifest-path server/Cargo.toml
just lint          # cargo clippy ... -- -D warnings (CI enforces this)
just test-phase2   # ephemeral in-memory SpacetimeDB on :3100 + Python multi-client E2E (tools/phase2_e2e_test.py)
just test-phase3   # regenerate assets + headless Godot arena test
just test-phase4   # GDScript --check-only, UI smoke test, 2-process host/guest headless E2E
just assets        # python3 tools/gen_assets.py (needs pillow, numpy)
just build-server  # spacetime build of the WASM module
```

Single Rust test: `cargo test --manifest-path server/Cargo.toml -p sim <test_name>` (or `-p jumpernbumper` for the module crate).

Single Godot script check / test:
```bash
"$GODOT_BIN" --headless --path client --check-only -s res://scripts/GameWorld.gd
"$GODOT_BIN" --headless --path client -s res://tests/test_phase4_client.gd -- --smoke
```
Run `"$GODOT_BIN" --headless --path client --import` first if assets changed. When adding a new GDScript file, add it to the `GDSCRIPTS` list in `scripts/test_phase4.sh` so it gets syntax-checked.

CI (`.github/workflows/release.yml`) runs Rust tests + clippy on pushes/PRs to `main`; `v*` tags export Linux/Windows/macOS builds and publish a GitHub Release.

## Architecture

**Server is authoritative; the client only sends inputs and renders replicated state.**

- `server/sim/` — pure, deterministic Rust crate (no SpacetimeDB dependency): physics, tile collision, stomp/kill resolution, spawns, mutators, bot AI. Entry point is `sim::step_room(...)`, which returns `StepEvent`s. It loads `shared/physics_constants.json` and `shared/classic_meadow.json` at compile time via `include_str!`, so editing those JSON files changes server behavior on rebuild. Most unit tests live here.
- `server/spacetimedb/` — WASM module (crate name `jumpernbumper`). Tables `player`, `room`, `room_member`, `match_bunny`, `kill_event`, `match_tick_schedule` are all **private**; clients only see caller-scoped views (`my_player`, `my_room`, `my_room_member`, `my_match_bunny`, `my_kill_event`) and the code-free `public_room` lobby listing. This keeps private room codes secret and limits 30 Hz match traffic to the room's players — don't mark a table `public` or add a view that exposes `Room.code` to non-members. Reducers handle lobby flow (`create_room`, `join_room_by_code`, `join_public_room`, `select_bunny_slot`, `toggle_ready`, `add_bot`/`remove_bot`, `start_match`) and `send_input(input_bits, seq)`. A scheduled `match_tick` reducer (33 ms ≈ 30 Hz) runs only while a match is in progress: it converts `match_bunny` rows to sim state, calls `sim::step_room`, writes rows back, and inserts `kill_event` rows. Enum-like fields are plain integers (status, win_mode, input bits `1=Left 2=Right 4=Jump`, `winner_slot = -1` for none) — documented in the module's header comment.
- `client/autoload/SpacetimeWire.gd` — hand-written WebSocket client speaking SpacetimeDB's `v1.json.spacetimedb` protocol (no official Godot SDK). Its header documents the observed wire formats. Important quirk: `TransactionUpdate` rows arrive as **positional arrays**, decoded using the column order from `table_schemas.json`.
- `client/autoload/SpacetimeClient.gd` — singleton holding a local mirror of the subscribed views (keyed by view name), query helpers, typed reducer wrappers, and signals (`state_updated`, `kill_event_received`, `reducer_error`, `connection_lost`). Other autoloads: `AudioManager`, `InputSettings` (rebindable keyboard/joypad, persisted to `user://settings.cfg`).
- `client/scripts/Main.gd` — screen router: recomputes the target screen (Connect → RoomBrowser → Lobby → GameWorld → VictoryPodium) from SpacetimeClient state on every state change rather than using explicit navigation calls.
- `client/scripts/GameWorld.gd` renders `match_bunny` rows with interpolation (snapping on respawn/teleport); `ArenaRenderer.gd` draws the tile layout from `classic_meadow.json`. Fixed 400×256 viewport scaled with `canvas_items` stretch; `RetroUI.gd` provides shared pixel-style UI helpers.

### Shared data contract (keep in sync)

`shared/*.json` is canonical. `client/data/*.json` is a byte-for-byte mirror produced by `just assets` (`sync_shared_json` in `tools/gen_assets.py`) — never edit `client/data/` directly.

`shared/table_schemas.json` is keyed by **view name** (what arrives as `table_name` on the wire). Changing a table or view row type requires updating **all** of: the Rust struct (field order matters), the column-order doc comment at the top of `server/spacetimedb/src/lib.rs`, `shared/table_schemas.json`, then re-syncing `client/data/`. Adding a view also means adding it to `TABLE_NAMES`/`_extract_pk` in `SpacetimeClient.gd`, `VIEW_TO_MIRROR` in `tools/phase2_e2e_test.py`, and `VIEW_NAMES` in `client/tests/phase2_smoke.gd`. Rows avoid `Option` fields to keep JSON decoding in GDScript simple.

### Assets

Sprites, tileset, background, particles, and WAV SFX are generated procedurally and deterministically by `tools/gen_assets.py`. To change art or sound, edit the generator and rerun `just assets` rather than editing PNG/WAV files by hand.
