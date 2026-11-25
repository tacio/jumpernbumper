set shell := ["bash", "-euo", "pipefail", "-c"]

godot := env_var_or_default("GODOT_BIN", "/home/tacio/Apps/Godot_v4.7.2-stable_linux.x86_64")
spacetime := env_var_or_default("SPACETIME_BIN", "/home/tacio/.local/bin/spacetime")
db_name := env_var_or_default("STDB_DB_NAME", "jumpernbumper")
listen_addr := env_var_or_default("STDB_LISTEN_ADDR", "127.0.0.1:3000")

# Show available recipes
default:
    @just --list

# Start local SpacetimeDB server and publish the Rust module
server:
    STDB_LISTEN_ADDR="{{listen_addr}}" STDB_DB_NAME="{{db_name}}" SPACETIME_BIN="{{spacetime}}" bash scripts/dev_start.sh

# Launch one Godot desktop client
client:
    "{{godot}}" --path client

# Launch two Godot desktop clients locally for multiplayer testing
client2:
    "{{godot}}" --path client & "{{godot}}" --path client & wait

# Open the project in the Godot editor
editor:
    "{{godot}}" --editor --path client

# Build the SpacetimeDB Rust WASM module
build-server:
    "{{spacetime}}" build --module-path server/spacetimedb

# Regenerate pixel-art sprites, WAV SFX, and sync shared/*.json -> client/data/
assets:
    python3 tools/gen_assets.py

# Import Godot client assets headlessly
import:
    "{{godot}}" --headless --path client --import

# Run the full test suite (Phases 1-4)
test:
    bash scripts/run_tests.sh

# Run Rust simulation and module unit tests
test-rust:
    cargo test --manifest-path server/Cargo.toml

# Run Rust clippy with warnings denied
lint:
    cargo clippy --manifest-path server/Cargo.toml -- -D warnings

# Run Phase 2 SpacetimeDB + Python multi-client E2E tests
test-phase2:
    bash scripts/test_phase2.sh

# Run Phase 3 procedural assets + Godot Arena tests
test-phase3:
    bash scripts/test_phase3.sh

# Run Phase 4 Godot client smoke + 2-instance E2E tests
test-phase4:
    bash scripts/test_phase4.sh

# Export Linux release build (requires Godot 4.7.2 export templates)
export-linux:
    mkdir -p client/build/linux
    "{{godot}}" --headless --path client --export-release "Linux" build/linux/jumpernbumper.x86_64

# Export Windows release build (requires Godot 4.7.2 export templates)
export-windows:
    mkdir -p client/build/windows
    "{{godot}}" --headless --path client --export-release "Windows Desktop" build/windows/jumpernbumper.exe

# Export macOS release build (requires Godot 4.7.2 export templates)
export-macos:
    mkdir -p client/build/macos
    "{{godot}}" --headless --path client --export-release "macOS" build/macos/jumpernbumper.zip

# Package Linux release archive into dist/
package-linux: export-linux
    mkdir -p dist
    tar -C client/build/linux -czf dist/jumpernbumper-linux-x86_64.tar.gz .

# Package Windows release archive into dist/
package-windows: export-windows
    mkdir -p dist
    (cd client/build/windows && zip -r ../../../dist/jumpernbumper-windows-x86_64.zip .)

# Package macOS release archive into dist/
package-macos: export-macos
    mkdir -p dist
    cp client/build/macos/jumpernbumper.zip dist/jumpernbumper-macos-universal.zip

# Export and package release archives for Linux, Windows, and macOS into dist/
package-all: package-linux package-windows package-macos
    @ls -lh dist/

# Clean Rust build artifacts, Godot exports, and local SpacetimeDB data
clean:
    rm -rf server/target client/build dist .spacetime-data
