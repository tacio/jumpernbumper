# Jumper 'n Bumper

An online multiplayer arena platformer inspired by **Jump 'n Bump**, built with **Godot 4.7.2** and **SpacetimeDB (Rust)**.

Stomp on rival bunnies' heads to score points, dodge springs and water hazards, toggle classic mutators, or battle server-controlled **robot bunnies**!

## Features

- **Authoritative Multiplayer (SpacetimeDB):** 30 Hz deterministic Rust physics simulation (`server/sim` + `server/spacetimedb`).
- **4 Classic Bunnies:** Dott, Jiffy, Fizz, and Mijji — with public room browsing or 5-character private room codes.
- **Robot Bot Bunnies:** Hosts can add or kick server-controlled robot bunnies in any open lobby slot, featuring custom robot bunny sprites and arcade AI.
- **Customizable Controls & Joypad Support:** Rebind Keyboard and Joypad controls side-by-side from the **Controls** menu on the title screen, with full D-pad/analog stick menu navigation.
- **Match Modes & Mutators:** Kills or Time win conditions, Low Gravity, Pogostick, Jetpack, and Gore toggle.
- **Cross-Platform Builds:** Automated Linux, Windows, and macOS client exports via Godot headless and GitHub Actions.

## Default Controls

| Action | Keyboard | Joypad |
| --- | --- | --- |
| Move Left | `A` / `Left Arrow` | `D-Pad Left` / `Left Stick` |
| Move Right | `D` / `Right Arrow` | `D-Pad Right` / `Left Stick` |
| Jump / Swim | `W` / `Space` | `Button A / Cross` |
| Pause Menu | `Esc` | `Start` |

All bindings can be customized from the **CONTROLS** button on the Connect screen (saved to `user://settings.cfg`).

## Project Structure

- `client/` — Godot 4.7.2 desktop client (GDScript scenes, UI, arena renderer, audio, tests)
- `server/sim/` — Pure deterministic Rust physics & bot AI crate
- `server/spacetimedb/` — SpacetimeDB Rust WASM module (tables, reducers, 30 Hz match tick)
- `shared/` — Canonical arena layout, physics constants, and table schemas
- `tools/` — Procedural pixel-art sprite, tileset, WAV SFX, and JSON sync generator (`gen_assets.py`)
- `scripts/` — Local dev & test scripts

## Local Development

Prerequisites:
- [Godot 4.7.2](https://godotengine.org/)
- [Rust](https://rustup.rs/) + `wasm32-unknown-unknown` target
- [SpacetimeDB CLI](https://spacetimedb.com/)
- [just](https://github.com/casey/just)
- Python 3.12+ with `pillow` and `numpy` (only if regenerating assets)

```bash
# 1. Start local SpacetimeDB and publish the Rust module
just server

# 2. Launch a Godot client (or two clients for local multiplayer)
just client
just client2
```

### Useful Commands

```bash
just test          # Run full test suite (Rust + SpacetimeDB + Godot)
just test-rust     # Run Rust unit tests
just lint          # Run cargo clippy with -D warnings
just assets        # Regenerate sprites/SFX and sync shared/*.json -> client/data/
just package-all   # Export and archive Linux, Windows, and macOS builds into dist/
```

## Automated Releases (GitHub Actions)

The workflow in [`.github/workflows/release.yml`](.github/workflows/release.yml):
- Runs Rust unit tests and `clippy` on every push/PR to `main`.
- Exports and packages Linux (`.tar.gz`), Windows (`.zip`), and macOS (`.zip`) clients on `v*` tag pushes or manual `workflow_dispatch`, and publishes a GitHub Release when a `v*` tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```
