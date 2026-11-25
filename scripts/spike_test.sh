#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPACETIME_BIN="${SPACETIME_BIN:-/home/tacio/.local/bin/spacetime}"
GODOT_BIN="${GODOT_BIN:-/home/tacio/Apps/Godot_v4.7.2-stable_linux.x86_64}"
LISTEN_ADDR="127.0.0.1:3100"
DB_NAME="jumpernbumper"
WS_URL="ws://$LISTEN_ADDR/v1/database/$DB_NAME/subscribe"

STDB_PID=""
STDB_LOG="$(mktemp)"
STDB_DATA_DIR="$(mktemp -d)"
cleanup() {
  if [ -n "$STDB_PID" ] && kill -0 "$STDB_PID" 2>/dev/null; then
    kill "$STDB_PID" 2>/dev/null || true
    wait "$STDB_PID" 2>/dev/null || true
  fi
  rm -f "$STDB_LOG"
  rm -rf "$STDB_DATA_DIR"
}
trap cleanup EXIT INT TERM

echo "[spike_test] 1. Running Rust sim unit tests..."
cargo test --manifest-path "$ROOT_DIR/server/Cargo.toml"

echo "[spike_test] 2. Starting ephemeral SpacetimeDB (--in-memory) at $LISTEN_ADDR..."
"$SPACETIME_BIN" start \
  --listen-addr "$LISTEN_ADDR" \
  --data-dir "$STDB_DATA_DIR" \
  --in-memory \
  --non-interactive >"$STDB_LOG" 2>&1 &
STDB_PID=$!

READY=0
for _ in $(seq 1 50); do
  if "$SPACETIME_BIN" server ping "http://$LISTEN_ADDR" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.2
done

if [ "$READY" -ne 1 ]; then
  echo "[spike_test] ERROR: SpacetimeDB failed to become ready:" >&2
  cat "$STDB_LOG" >&2
  exit 1
fi

echo "[spike_test] 3. Building & publishing $DB_NAME..."
"$SPACETIME_BIN" publish "$DB_NAME" \
  --server "http://$LISTEN_ADDR" \
  --module-path "$ROOT_DIR/server/spacetimedb" \
  --no-config \
  --anonymous \
  --yes

echo "[spike_test] 4. Checking Godot GDScript syntax..."
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" --check-only -s res://tests/spike_test.gd

echo "[spike_test] 5. Running Godot headless WebSocket spike client..."
"$GODOT_BIN" --headless --path "$ROOT_DIR/client" -s res://tests/spike_test.gd -- --url "$WS_URL"

echo "[spike_test] 6. Running Python websockets peer check..."
python3 "$ROOT_DIR/tools/spike_peer_check.py" "$WS_URL"

echo "[spike_test] PASS: All Phase 0 checks succeeded!"
